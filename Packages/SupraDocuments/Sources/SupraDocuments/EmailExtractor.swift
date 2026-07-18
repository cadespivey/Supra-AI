import Foundation
import SupraCore

/// Extracts `.eml` (RFC 822 / MIME) emails: a normalized header summary + body
/// text part, plus attachments as child documents (plan §3.2). Legacy Outlook
/// `.msg` is reported as unsupported rather than silently skipped.
public struct EmailExtractor: DocumentExtractor {
    private let policy: ImportPolicy

    public init(policy: ImportPolicy = .default) { self.policy = policy }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "eml" else {
            throw ExtractionError.unsupportedFormat("Outlook .\(ext) is not supported; export the email as .eml.")
        }
        let raw = try DocumentTextLoader.readString(at: fileURL, maxBytes: policy.maxInputBytes)
        let message = try MIMEMessage.parse(raw, policy: policy)

        var parts: [ExtractedPart] = []
        var attachments: [ExtractedAttachment] = []

        let headerSummary = Self.headerSummary(message.headers)
        let body = message.bodyText()
        let bodyText = TextNormalization.normalize([headerSummary, body].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        try policy.validateDecodedText(bodyText)
        parts.append(ExtractedPart(sourceKind: .emailBody, text: bodyText, emailPartPath: "body"))

        var expandedBytes = bodyText.utf8.count
        for (index, attachment) in message.attachments().enumerated() {
            let (next, overflow) = expandedBytes.addingReportingOverflow(attachment.data.count)
            if overflow || next > policy.maxArchiveExpandedBytes {
                throw ImportPolicyViolation(
                    .expandedBytesLimit,
                    "Email content exceeds the \(policy.maxArchiveExpandedBytes)-byte decoded limit."
                )
            }
            expandedBytes = next
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
            structure: Self.buildStructure(
                message: message,
                headerSummary: headerSummary,
                body: body,
                flatText: bodyText
            ),
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

    private static func buildStructure(
        message: MIMEMessage,
        headerSummary: String,
        body: String,
        flatText: String
    ) -> ExtractedDocumentStructure {
        let messageKey = "email/message"
        let headerKey = "email/headers"
        let normalizedBody = TextNormalization.normalize(body)
        let references = messageIDs(in: message.headers["references"])
        var messagePayload: [String: Any] = [
            "semanticKind": "email_message",
            "headers": message.headers,
            "references": references,
        ]
        if let value = normalizedMessageID(message.headers["message-id"]) {
            messagePayload["messageID"] = value
        }
        if let value = normalizedMessageID(message.headers["in-reply-to"]) {
            messagePayload["inReplyTo"] = value
        }
        if let value = message.headers["subject"] { messagePayload["subject"] = value }

        var nodes = [
            ExtractedStructureNode(
                nodeKey: "document",
                partIndex: 0,
                ordinal: 0,
                kind: .document
            ),
            ExtractedStructureNode(
                nodeKey: messageKey,
                parentNodeKey: "document",
                partIndex: 0,
                ordinal: 0,
                kind: .emailMessage,
                payloadJSON: payloadJSON(messagePayload)
            ),
            ExtractedStructureNode(
                nodeKey: headerKey,
                parentNodeKey: messageKey,
                partIndex: 0,
                ordinal: 0,
                kind: .header,
                textContent: completeHeaderText(message.headers),
                payloadJSON: payloadJSON([
                    "semanticKind": "email_headers",
                    "headers": message.headers,
                ])
            ),
        ]
        var edges: [ExtractedStructureEdge] = []
        var textNodeRanges: [(key: String, range: Range<Int>)] = []

        if !normalizedBody.isEmpty,
           let bodyRange = flatText.range(of: normalizedBody, options: .backwards) {
            let bodyStart = flatText.distance(from: flatText.startIndex, to: bodyRange.lowerBound)
            let quoteStart = quotedReplyStart(in: normalizedBody)
            let currentEnd = quoteStart.map { trimmedContentEnd(in: normalizedBody, before: $0) }
                ?? normalizedBody.count
            if currentEnd > 0 {
                let range = bodyStart..<(bodyStart + currentEnd)
                nodes.append(ExtractedStructureNode(
                    nodeKey: "email/body/0",
                    parentNodeKey: messageKey,
                    partIndex: 0,
                    ordinal: 1,
                    kind: .emailBody,
                    charStart: range.lowerBound,
                    charEnd: range.upperBound,
                    payloadJSON: payloadJSON(["quoted": false])
                ))
                textNodeRanges.append(("email/body/0", range))
            }
            if let quoteStart {
                let range = (bodyStart + quoteStart)..<(bodyStart + normalizedBody.count)
                nodes.append(ExtractedStructureNode(
                    nodeKey: "email/quote/0",
                    parentNodeKey: messageKey,
                    partIndex: 0,
                    ordinal: 2,
                    kind: .emailQuote,
                    charStart: range.lowerBound,
                    charEnd: range.upperBound,
                    payloadJSON: payloadJSON(["quoted": true, "boundary": "reply"])
                ))
                textNodeRanges.append(("email/quote/0", range))
            }
        }

        for (index, reference) in message.contentIDReferences().enumerated() {
            let key = "email/attachment-ref/\(index)"
            nodes.append(ExtractedStructureNode(
                nodeKey: key,
                parentNodeKey: messageKey,
                partIndex: 0,
                ordinal: 3 + index,
                kind: .attachmentRef,
                textContent: "cid:\(reference.contentID)",
                payloadJSON: payloadJSON([
                    "semanticKind": "cid_attachment_reference",
                    "contentID": reference.contentID,
                    "fileName": reference.fileName ?? "",
                    "contentType": reference.contentType,
                    "disposition": reference.disposition,
                ])
            ))
            let token = "cid:\(reference.contentID)"
            let sourceKey = textNodeRanges.first { entry in
                text(in: entry.range, source: flatText).localizedCaseInsensitiveContains(token)
            }?.key
            if let sourceKey {
                edges.append(ExtractedStructureEdge(
                    fromNodeKey: sourceKey,
                    toNodeKey: key,
                    kind: .references
                ))
            }
        }

        // Keep the calculation explicit: the specialized tree is supplemental;
        // the legacy header summary remains in the flat revision unchanged.
        _ = headerSummary
        return ExtractedDocumentStructure(nodes: nodes, edges: edges)
    }

    private static func completeHeaderText(_ headers: [String: String]) -> String {
        let priority = [
            "from", "to", "cc", "bcc", "date", "subject", "message-id",
            "in-reply-to", "references", "mime-version", "content-type",
        ]
        let ordered = priority.filter { headers[$0] != nil }
            + headers.keys.filter { !priority.contains($0) }.sorted()
        return ordered.compactMap { key in
            headers[key].map { "\(canonicalHeaderName(key)): \($0)" }
        }.joined(separator: "\n")
    }

    private static func canonicalHeaderName(_ key: String) -> String {
        switch key {
        case "message-id": return "Message-ID"
        case "in-reply-to": return "In-Reply-To"
        case "mime-version": return "MIME-Version"
        case "content-type": return "Content-Type"
        default: return key.split(separator: "-").map { $0.capitalized }.joined(separator: "-")
        }
    }

    private static func normalizedMessageID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func messageIDs(in value: String?) -> [String] {
        guard let value else { return [] }
        let expression = try? NSRegularExpression(pattern: #"<[^>]+>"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression?.matches(in: value, range: range) ?? []
        let identifiers = matches.compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
        }
        if !identifiers.isEmpty { return identifiers }
        return value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func quotedReplyStart(in text: String) -> Int? {
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if (lower.contains("original message") && lower.contains("--"))
                || (lower.hasPrefix("on ") && lower.hasSuffix(" wrote:"))
                || lower.hasPrefix(">") {
                return offset
            }
            offset += line.count + 1
        }
        return nil
    }

    private static func trimmedContentEnd(in text: String, before offset: Int) -> Int {
        let boundary = text.index(text.startIndex, offsetBy: offset)
        return text[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private static func text(in range: Range<Int>, source: String) -> String {
        let lower = source.index(source.startIndex, offsetBy: range.lowerBound)
        let upper = source.index(source.startIndex, offsetBy: range.upperBound)
        return String(source[lower..<upper])
    }

    private static func payloadJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
        var contentID: String?
        var contentType: String
        var disposition: String
    }

    struct ContentIDReference {
        var contentID: String
        var fileName: String?
        var contentType: String
        var disposition: String
    }

    static func parse(_ raw: String, policy: ImportPolicy = .default) throws -> MIMEMessage {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headerBlock, body) = splitHeaders(unified)
        let headers = parseHeaders(headerBlock)
        let budget = MIMEParseBudget(policy: policy)
        return try parse(headers: headers, body: body, depth: 0, budget: budget)
    }

    private static func parse(
        headers: [String: String],
        body: String,
        depth: Int,
        budget: MIMEParseBudget
    ) throws -> MIMEMessage {
        try Task.checkCancellation()
        guard depth <= budget.policy.maxMIMEDepth else {
            throw ImportPolicyViolation(
                .mimeDepthLimit,
                "MIME nesting exceeds the \(budget.policy.maxMIMEDepth)-level limit."
            )
        }
        let contentType = headers["content-type"] ?? "text/plain"
        if contentType.lowercased().contains("multipart"), let boundary = boundary(from: contentType) {
            var parts: [MIMEMessage] = []
            for segment in splitParts(body: body, boundary: boundary) {
                let (hb, b) = splitHeaders(segment)
                parts.append(try parse(
                    headers: parseHeaders(hb),
                    body: b,
                    depth: depth + 1,
                    budget: budget
                ))
            }
            return MIMEMessage(headers: headers, body: "", parts: parts)
        }
        let message = MIMEMessage(headers: headers, body: body, parts: [])
        if message.isAttachmentLeaf {
            budget.attachmentCount += 1
            if budget.attachmentCount > budget.policy.maxAttachments {
                throw ImportPolicyViolation(
                    .attachmentCountLimit,
                    "Message exceeds the \(budget.policy.maxAttachments)-attachment limit."
                )
            }
        }
        return message
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

    func contentIDReferences() -> [ContentIDReference] {
        var result: [ContentIDReference] = []
        collectContentIDReferences(into: &result)
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
                    result.append(Attachment(
                        fileName: part.fileName(),
                        data: part.decodedData(),
                        contentID: part.normalizedContentID,
                        contentType: part.normalizedContentType,
                        disposition: part.normalizedDisposition
                    ))
                }
            } else {
                part.collectAttachments(into: &result)
            }
        }
    }

    private func collectContentIDReferences(into result: inout [ContentIDReference]) {
        if parts.isEmpty, let contentID = normalizedContentID {
            result.append(ContentIDReference(
                contentID: contentID,
                fileName: fileName(),
                contentType: normalizedContentType,
                disposition: normalizedDisposition
            ))
        }
        for part in parts {
            part.collectContentIDReferences(into: &result)
        }
    }

    private var normalizedContentID: String? {
        guard var value = headers["content-id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.first == "<" { value.removeFirst() }
        if value.last == ">" { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private var normalizedContentType: String {
        let value = headers["content-type"] ?? "application/octet-stream"
        return value.split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? "application/octet-stream"
    }

    private var normalizedDisposition: String {
        let value = (headers["content-disposition"] ?? "").lowercased()
        return value.contains("inline") ? "inline" : "attachment"
    }

    private var isAttachmentLeaf: Bool {
        guard parts.isEmpty else { return false }
        let disposition = (headers["content-disposition"] ?? "").lowercased()
        let contentType = (headers["content-type"] ?? "").lowercased()
        return disposition.contains("attachment")
            || disposition.contains("filename")
            || (!contentType.contains("text/plain") && !contentType.contains("text/html") && fileName() != nil)
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

private final class MIMEParseBudget {
    let policy: ImportPolicy
    var attachmentCount = 0

    init(policy: ImportPolicy) {
        self.policy = policy
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
