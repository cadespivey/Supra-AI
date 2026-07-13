import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

/// Signature/UTType result used to make extension dispatch fail closed when the
/// bytes clearly belong to a different supported family.
public struct DetectedDocumentType: Sendable, Equatable {
    public let family: SupportedDocumentTypes.ExtractionFamily
    public let evidence: String

    public init(family: SupportedDocumentTypes.ExtractionFamily, evidence: String) {
        self.family = family
        self.evidence = evidence
    }
}

public enum DocumentTypeDetector {
    /// Validates a known extension against byte signatures and OOXML package
    /// structure. A file with no authoritative signature may still use its UTType;
    /// a contradictory signature is always rejected.
    public static func validate(
        fileURL: URL,
        expected: SupportedDocumentTypes.Format,
        policy: ImportPolicy
    ) throws -> DetectedDocumentType? {
        try policy.validateSource(at: fileURL)
        let detected = try detect(fileURL: fileURL, policy: policy)
        guard let detected else { return nil }

        let compatible: Bool
        switch (expected.family, detected.family) {
        case (.plainText, .plainText), (.markdown, .plainText), (.plainText, .markdown), (.markdown, .markdown):
            compatible = true
        default:
            compatible = expected.family == detected.family
        }
        guard compatible else {
            throw ImportPolicyViolation(
                .typeMismatch,
                "The .\(fileURL.pathExtension.lowercased()) extension conflicts with \(detected.evidence)."
            )
        }
        return detected
    }

    public static func detect(fileURL: URL, policy: ImportPolicy) throws -> DetectedDocumentType? {
        try Task.checkCancellation()
        let prefix = try boundedPrefix(of: fileURL, count: min(policy.maxInputBytes, 65_536))

        if prefix.starts(with: Data("%PDF-".utf8)) {
            return DetectedDocumentType(family: .pdf, evidence: "a PDF signature")
        }
        if prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            || prefix.starts(with: Data([0xFF, 0xD8, 0xFF]))
            || prefix.starts(with: Data([0x49, 0x49, 0x2A, 0x00]))
            || prefix.starts(with: Data([0x4D, 0x4D, 0x00, 0x2A])) {
            return DetectedDocumentType(family: .image, evidence: "an image signature")
        }
        if prefix.count >= 12,
           String(data: prefix.subdata(in: 4..<8), encoding: .ascii) == "ftyp" {
            return DetectedDocumentType(family: .image, evidence: "an ISO image container signature")
        }
        if prefix.starts(with: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
            let ext = fileURL.pathExtension.lowercased()
            let family: SupportedDocumentTypes.ExtractionFamily = ext == "xls" ? .spreadsheet : (ext == "msg" ? .email : .word)
            return DetectedDocumentType(family: family, evidence: "an OLE compound-document signature")
        }
        if prefix.starts(with: Data([0x50, 0x4B, 0x03, 0x04]))
            || prefix.starts(with: Data([0x50, 0x4B, 0x05, 0x06])) {
            return try detectOfficeArchive(fileURL: fileURL, policy: policy)
        }

        let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = text.lowercased()
        if lower.hasPrefix("{\\rtf") {
            return DetectedDocumentType(family: .richText, evidence: "an RTF signature")
        }
        let htmlPrefixes = [
            "<!doctype html", "<html", "<head", "<body", "<main", "<section",
            "<article", "<div", "<p", "<h1", "<table", "<ul", "<ol", "<span"
        ]
        if htmlPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return DetectedDocumentType(family: .html, evidence: "HTML markup")
        }
        if lower.hasPrefix("<?xml") || (lower.hasPrefix("<") && !lower.hasPrefix("<!doctype html")) {
            return DetectedDocumentType(family: .xml, evidence: "XML markup")
        }
        if looksLikeEmail(lower) {
            return DetectedDocumentType(family: .email, evidence: "RFC 822 headers")
        }

        // UTType is intentionally secondary: it is often extension-derived, but
        // still provides a useful check when Launch Services has inspected the file.
        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let family = family(for: contentType),
           !isGenericText(contentType) {
            return DetectedDocumentType(family: family, evidence: "UTType \(contentType.identifier)")
        }
        return nil
    }

    private static func detectOfficeArchive(fileURL: URL, policy: ImportPolicy) throws -> DetectedDocumentType? {
        let archive = try ZipArchiveReader.validatedArchive(at: fileURL, policy: policy)
        let paths = Set(archive.map(\.path))
        let pathFamily: SupportedDocumentTypes.ExtractionFamily? = {
            if paths.contains("word/document.xml") { return .word }
            if paths.contains("xl/workbook.xml") || paths.contains(where: { $0.hasPrefix("xl/worksheets/") }) {
                return .spreadsheet
            }
            return nil
        }()

        var contentTypeFamily: SupportedDocumentTypes.ExtractionFamily?
        if let contentTypes = try ZipArchiveReader.entryData(
            in: archive,
            path: "[Content_Types].xml",
            policy: policy
        ) {
            try policy.validateXMLData(contentTypes)
            let lower = String(data: contentTypes, encoding: .utf8)?.lowercased() ?? ""
            let declaresWord = lower.contains("wordprocessingml")
            let declaresSpreadsheet = lower.contains("spreadsheetml")
            if declaresWord && declaresSpreadsheet {
                throw ImportPolicyViolation(.typeMismatch, "OOXML content types declare conflicting document families.")
            }
            if declaresWord { contentTypeFamily = .word }
            if declaresSpreadsheet { contentTypeFamily = .spreadsheet }
        }

        if let pathFamily, let contentTypeFamily, pathFamily != contentTypeFamily {
            throw ImportPolicyViolation(.typeMismatch, "OOXML content types conflict with package structure.")
        }
        switch contentTypeFamily ?? pathFamily {
        case .word:
            return DetectedDocumentType(family: .word, evidence: "an OOXML Word package")
        case .spreadsheet:
            return DetectedDocumentType(family: .spreadsheet, evidence: "an OOXML spreadsheet package")
        default:
            return nil
        }
    }

    private static func boundedPrefix(of url: URL, count: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: max(1, count)) ?? Data()
        } catch {
            throw ExtractionError.fileUnreadable(error.localizedDescription)
        }
    }

    private static func looksLikeEmail(_ lower: String) -> Bool {
        let header = lower.prefix(8_192)
        let hasAddressHeader = header.hasPrefix("from:") || header.contains("\nfrom:")
        return hasAddressHeader && (header.contains("\nsubject:") || header.contains("\ncontent-type:") || header.contains("\nto:"))
    }

    private static func family(for type: UTType) -> SupportedDocumentTypes.ExtractionFamily? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .rtf) { return .richText }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .xml) { return .xml }
        return nil
    }

    private static func isGenericText(_ type: UTType) -> Bool {
        type == .plainText || type == .text || type == .utf8PlainText
    }
}
