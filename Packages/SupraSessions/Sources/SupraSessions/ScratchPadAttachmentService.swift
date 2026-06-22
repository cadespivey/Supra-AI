import Foundation
import SupraCore
import SupraDocuments

/// Locally-extracted evidence signals for a ScratchPad attachment (Milestone 4,
/// Phase 3). Persisted as JSON in `scratch_pad_attachments.evidence_signals_json`
/// and consumed by the billing engine (Phase 4) as corroboration for narrative
/// and time. Everything here is derived on-device — no network, no model.
public struct AttachmentEvidence: Codable, Sendable, Equatable {
    public var kind: String
    public var fileName: String
    public var byteSize: Int
    public var wordCount: Int
    public var partCount: Int
    public var attachmentCount: Int
    public var extractionMethod: String
    public var needsOCR: Bool
    public var subject: String?
    public var metadataCreatedAt: Date?
    public var metadataModifiedAt: Date?
    public var warnings: [String]
    public var textExcerpt: String

    public init(
        kind: String,
        fileName: String,
        byteSize: Int,
        wordCount: Int,
        partCount: Int,
        attachmentCount: Int,
        extractionMethod: String,
        needsOCR: Bool,
        subject: String?,
        metadataCreatedAt: Date?,
        metadataModifiedAt: Date?,
        warnings: [String],
        textExcerpt: String
    ) {
        self.kind = kind
        self.fileName = fileName
        self.byteSize = byteSize
        self.wordCount = wordCount
        self.partCount = partCount
        self.attachmentCount = attachmentCount
        self.extractionMethod = extractionMethod
        self.needsOCR = needsOCR
        self.subject = subject
        self.metadataCreatedAt = metadataCreatedAt
        self.metadataModifiedAt = metadataModifiedAt
        self.warnings = warnings
        self.textExcerpt = textExcerpt
    }

    public var billingKind: BillingEvidenceKind { BillingEvidenceKind(rawValue: kind) ?? .other }

    /// A short human-readable line for the attachment tray.
    public var displaySummary: String {
        var fields: [String] = [billingKind.displayLabel]
        if partCount > 1 { fields.append("\(partCount) pp") }
        if wordCount > 0 { fields.append("\(wordCount.formatted()) words") }
        if attachmentCount > 0 { fields.append("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")") }
        if let metadataCreatedAt { fields.append(Self.dateFormatter.string(from: metadataCreatedAt)) }
        if needsOCR { fields.append("needs OCR") }
        return fields.joined(separator: " · ")
    }

    public static func encode(_ evidence: AttachmentEvidence) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(evidence) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> AttachmentEvidence? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AttachmentEvidence.self, from: data)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

extension BillingEvidenceKind {
    public var displayLabel: String {
        switch self {
        case .email: "email"
        case .workProduct: "work product"
        case .filing: "filing"
        case .other: "file"
        }
    }
}

public enum ScratchPadAttachmentError: Error, Equatable, Sendable {
    case unsupported(String)

    public var message: String {
        switch self {
        case .unsupported(let message): message
        }
    }
}

/// Turns a dropped/picked file into billing evidence using the existing local
/// document-extraction pipeline (Milestone 4, Phase 3). Deterministic and
/// model-free; classifier enrichment can be layered later.
public struct ScratchPadAttachmentService: Sendable {
    private let extractionService: ExtractionService

    public init(extractionService: ExtractionService = ExtractionService()) {
        self.extractionService = extractionService
    }

    /// Extracts a file locally and builds its evidence signals. Throws
    /// `ScratchPadAttachmentError.unsupported` for `.msg` and unreadable/unknown types.
    public func makeEvidence(fileURL: URL, explicitKind: BillingEvidenceKind? = nil) async throws -> AttachmentEvidence {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "msg" {
            throw ScratchPadAttachmentError.unsupported(
                "Outlook .msg files aren't supported — open the message and export it as .eml, then drop that in."
            )
        }
        guard let format = SupportedDocumentTypes.format(for: fileURL) else {
            throw ScratchPadAttachmentError.unsupported("“.\(ext.isEmpty ? "?" : ext)” files aren't supported as evidence.")
        }

        let result: ExtractionResult
        do {
            result = try await extractionService.extract(fileURL: fileURL)
        } catch let error as ExtractionError {
            throw ScratchPadAttachmentError.unsupported(error.errorDescription ?? "That file couldn't be read.")
        }

        let byteSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let text = result.combinedText
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let kind = explicitKind ?? Self.inferKind(family: format.family, text: text)

        return AttachmentEvidence(
            kind: kind.rawValue,
            fileName: fileURL.lastPathComponent,
            byteSize: byteSize,
            wordCount: wordCount,
            partCount: result.pagePartCount,
            attachmentCount: result.attachments.count,
            extractionMethod: result.method,
            needsOCR: result.needsOCR,
            subject: Self.subject(from: result),
            metadataCreatedAt: result.metadataCreatedAt,
            metadataModifiedAt: result.metadataModifiedAt,
            warnings: result.warnings,
            textExcerpt: DocumentChunker.excerpt(text, limit: 600)
        )
    }

    /// Heuristic evidence kind (no model). Emails are emails; PDFs with court-filing
    /// markers are filings, otherwise work product; word/text-like files are work
    /// product; everything else is a generic file. Always attorney-correctable.
    static func inferKind(family: SupportedDocumentTypes.ExtractionFamily, text: String) -> BillingEvidenceKind {
        switch family {
        case .email:
            return .email
        case .pdf:
            let lower = text.lowercased()
            let markers = ["united states district court", "in the circuit court", "case no", "civil action", "docket", " filed "]
            let hits = markers.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            return hits >= 2 ? .filing : .workProduct
        case .word, .richText, .plainText, .markdown:
            return .workProduct
        case .spreadsheet, .html, .xml, .image:
            return .other
        }
    }

    /// Pulls the email subject from the extracted header summary, when present.
    static func subject(from result: ExtractionResult) -> String? {
        guard result.method == "eml", let body = result.parts.first?.text else { return nil }
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("subject:") {
                return String(line.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
