import Foundation
import SupraCore

/// Extracts `.eml` (RFC 822 / MIME) emails: a normalized header summary + body
/// text part, plus attachments as child documents (plan §3.2). Legacy Outlook
/// `.msg` is reported as unsupported rather than silently skipped.
public struct EmailExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "eml" else {
            throw ExtractionError.unsupportedFormat("Outlook .\(ext) is not supported; export the email as .eml.")
        }
        let raw = try DocumentTextLoader.readString(at: fileURL)
        let message = MIMEMessage.parse(raw)

        var parts: [ExtractedPart] = []
        var attachments: [ExtractedAttachment] = []

        let headerSummary = Self.headerSummary(message.headers)
        let body = message.bodyText()
        let bodyText = TextNormalization.normalize([headerSummary, body].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        parts.append(ExtractedPart(sourceKind: .emailBody, text: bodyText, emailPartPath: "body"))

        for (index, attachment) in message.attachments().enumerated() {
            attachments.append(ExtractedAttachment(
                // The MIME filename is attacker-controlled; reduce it to a bare
                // last-path-component so it can never carry path separators or
                // "../" traversal into the import write path (Zip-Slip).
                fileName: Self.safeAttachmentName(attachment.fileName, index: index),
                data: attachment.data,
                partPath: "attachment[\(index)]"
            ))
        }

        let metaDate = message.headers["date"].flatMap(Self.parseDate)
        return ExtractionResult(
            parts: parts,
            method: "eml",
            attachments: attachments,
            metadataCreatedAt: metaDate
        )
    }

    /// Reduces an attacker-controlled MIME attachment filename to a safe bare name
    /// (no directory separators / traversal), falling back to `attachment-N`.
    static func safeAttachmentName(_ raw: String?, index: Int) -> String {
        let fallback = "attachment-\(index + 1)"
        guard let raw else { return fallback }
        let last = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." || last.contains("/") || last.contains("\\") {
            return fallback
        }
        return last
    }

    private static func headerSummary(_ headers: [String: String]) -> String {
        var lines: [String] = []
        for key in ["from", "to", "cc", "date", "subject"] {
            if let value = headers[key], !value.isEmpty {
                lines.append("\(key.capitalized): \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string.trimmingCharacters(in: .whitespaces)) {
                return date
            }
        }
        return nil
    }
}

/// A minimal MIME message: headers + either a flat body or nested parts.
struct MIMEMessage {
    var headers: [String: String]
    var body: String
    var parts: [MIMEMessage]

    struct Attachment {
        var fileName: String?
        var data: Data
    }

    static func parse(_ raw: String) -> MIMEMessage {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headerBlock, body) = splitHeaders(unified)
        let headers = parseHeaders(headerBlock)
        return parse(headers: headers, body: body)
    }

    private static func parse(headers: [String: String], body: String) -> MIMEMessage {
        let contentType = headers["content-type"] ?? "text/plain"
        if contentType.lowercased().contains("multipart"), let boundary = boundary(from: contentType) {
            let parts = splitParts(body: body, boundary: boundary).map { segment -> MIMEMessage in
                let (hb, b) = splitHeaders(segment)
                return parse(headers: parseHeaders(hb), body: b)
            }
            return MIMEMessage(headers: headers, body: "", parts: parts)
        }
        return MIMEMessage(headers: headers, body: body, parts: [])
    }

    /// Best body text: first text/plain in the tree, else stripped first text/html.
    func bodyText() -> String {
        if let plain = firstPart(matching: "text/plain") {
            return plain.decodedBody()
        }
        if let html = firstPart(matching: "text/html") {
            return HTMLToText.convert(html.decodedBody())
        }
        if parts.isEmpty {
            let type = (headers["content-type"] ?? "text/plain").lowercased()
            return type.contains("html") ? HTMLToText.convert(decodedBody()) : decodedBody()
        }
        return ""
    }

    func attachments() -> [Attachment] {
        var result: [Attachment] = []
        collectAttachments(into: &result)
        return result
    }

    private func collectAttachments(into result: inout [Attachment]) {
        for part in parts {
            if part.parts.isEmpty {
                let disposition = (part.headers["content-disposition"] ?? "").lowercased()
                let contentType = (part.headers["content-type"] ?? "").lowercased()
                let isAttachment = disposition.contains("attachment")
                    || (part.headers["content-disposition"]?.contains("filename") ?? false)
                    || (!contentType.contains("text/plain") && !contentType.contains("text/html") && part.fileName() != nil)
                if isAttachment {
                    result.append(Attachment(fileName: part.fileName(), data: part.decodedData()))
                }
            } else {
                part.collectAttachments(into: &result)
            }
        }
    }

    private func firstPart(matching type: String) -> MIMEMessage? {
        if parts.isEmpty {
            return (headers["content-type"] ?? "text/plain").lowercased().contains(type) ? self : nil
        }
        for part in parts {
            if let match = part.firstPart(matching: type) { return match }
        }
        return nil
    }

    private func fileName() -> String? {
        for header in [headers["content-disposition"], headers["content-type"]] {
            guard let header else { continue }
            if let name = Self.parameter("filename", in: header) ?? Self.parameter("name", in: header) {
                return name
            }
        }
        return nil
    }

    private func decodedBody() -> String {
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        switch encoding {
        case "base64":
            let cleaned = body.replacingOccurrences(of: "\n", with: "")
            if let data = Data(base64Encoded: cleaned) {
                // Fall back to Latin-1 (which can't fail) for non-UTF-8 payloads so a
                // decodable body is never shown as raw base64 text.
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? body
            }
            return body
        case "quoted-printable":
            return QuotedPrintable.decode(body)
        default:
            return body
        }
    }

    private func decodedData() -> Data {
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        if encoding == "base64" {
            let cleaned = body.replacingOccurrences(of: "\n", with: "")
            return Data(base64Encoded: cleaned) ?? Data(body.utf8)
        }
        if encoding == "quoted-printable" {
            return Data(QuotedPrintable.decode(body).utf8)
        }
        return Data(body.utf8)
    }

    // MARK: - Parsing helpers

    private static func splitHeaders(_ text: String) -> (String, String) {
        if let range = text.range(of: "\n\n") {
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        return (text, "")
    }

    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        func commit() {
            if let key = currentKey {
                headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }
        }
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                commit()
                currentKey = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return headers
    }

    private static func boundary(from contentType: String) -> String? {
        parameter("boundary", in: contentType)
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        guard let range = header.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.first == "\"" {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") {
                return String(value[..<end])
            }
        }
        if let end = value.firstIndex(where: { $0 == ";" }) {
            value = String(value[..<end])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func splitParts(body: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        var segments: [String] = []
        var current: [String] = []
        var started = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(delimiter) {
                if started { segments.append(current.joined(separator: "\n")) }
                current = []
                started = true
                if line.hasPrefix("\(delimiter)--") { break } // closing boundary
            } else if started {
                current.append(line)
            }
        }
        return segments
    }
}

enum QuotedPrintable {
    static func decode(_ input: String) -> String {
        var result = Data()
        let bytes = Array(input.utf8)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x3D, i + 2 < bytes.count { // '='
                if bytes[i + 1] == 0x0A { i += 2; continue } // soft line break
                let hex = String(bytes: [bytes[i + 1], bytes[i + 2]], encoding: .ascii) ?? ""
                if let value = UInt8(hex, radix: 16) {
                    result.append(value)
                    i += 3
                    continue
                }
            }
            result.append(byte)
            i += 1
        }
        return String(data: result, encoding: .utf8) ?? input
    }
}
