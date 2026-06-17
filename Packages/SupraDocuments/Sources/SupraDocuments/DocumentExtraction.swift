import Foundation
import SupraCore

/// One extracted source part (a PDF page, sheet, email part, or whole converted
/// document) with its normalized text and a stable locator (plan §6.3).
public struct ExtractedPart: Sendable, Equatable {
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var text: String
    /// OCR confidence in 0...1 when this part came from OCR (set in WO 36).
    public var ocrConfidence: Double?
    /// Normalized OCR bounding boxes JSON, when available (for highlights).
    public var boundingBoxesJSON: String?

    public init(
        sourceKind: DocumentSourceKind,
        text: String,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        ocrConfidence: Double? = nil,
        boundingBoxesJSON: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.text = text
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.ocrConfidence = ocrConfidence
        self.boundingBoxesJSON = boundingBoxesJSON
    }
}

/// A child file extracted from a container document (e.g. an email attachment),
/// to be imported as a child document instance (plan §3.2).
public struct ExtractedAttachment: Sendable, Equatable {
    public var fileName: String
    public var data: Data
    public var partPath: String

    public init(fileName: String, data: Data, partPath: String) {
        self.fileName = fileName
        self.data = data
        self.partPath = partPath
    }
}

/// The deterministic result of extracting one document (plan §6.1).
public struct ExtractionResult: Sendable, Equatable {
    public var parts: [ExtractedPart]
    public var method: String
    public var warnings: [String]
    /// True when the document has little/no embedded text and should be OCR'd
    /// (scanned PDF, image). OCR itself runs in WO 36.
    public var needsOCR: Bool
    public var attachments: [ExtractedAttachment]
    public var metadataCreatedAt: Date?
    public var metadataModifiedAt: Date?

    public init(
        parts: [ExtractedPart],
        method: String,
        warnings: [String] = [],
        needsOCR: Bool = false,
        attachments: [ExtractedAttachment] = [],
        metadataCreatedAt: Date? = nil,
        metadataModifiedAt: Date? = nil
    ) {
        self.parts = parts
        self.method = method
        self.warnings = warnings
        self.needsOCR = needsOCR
        self.attachments = attachments
        self.metadataCreatedAt = metadataCreatedAt
        self.metadataModifiedAt = metadataModifiedAt
    }

    public var pagePartCount: Int { parts.count }
    public var combinedText: String { parts.map(\.text).joined(separator: "\n\n") }
}

public enum ExtractionError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String)
    case fileUnreadable(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let reason): "Unsupported format: \(reason)"
        case .fileUnreadable(let reason): "File could not be read: \(reason)"
        case .malformed(let reason): "File is malformed: \(reason)"
        }
    }
}

/// A per-format extractor. Implementations must be deterministic and capture
/// failures as thrown `ExtractionError`s (never crash) so the import report can
/// account for them (plan §6.1, WO 34 acceptance).
public protocol DocumentExtractor: Sendable {
    func extract(fileURL: URL) async throws -> ExtractionResult
}

/// Dispatches a file to the right extractor by its supported-type family.
public struct ExtractionService: Sendable {
    private let extractors: [SupportedDocumentTypes.ExtractionFamily: any DocumentExtractor]

    public init(extractors: [SupportedDocumentTypes.ExtractionFamily: any DocumentExtractor] = ExtractionService.defaultExtractors()) {
        self.extractors = extractors
    }

    public static func defaultExtractors() -> [SupportedDocumentTypes.ExtractionFamily: any DocumentExtractor] {
        [
            .plainText: PlainTextExtractor(),
            .markdown: PlainTextExtractor(),
            .xml: XMLTextExtractor(),
            .html: HTMLTextExtractor(),
            .richText: RichTextExtractor(),
            .word: WordExtractor(),
            .spreadsheet: SpreadsheetExtractor(),
            .email: EmailExtractor(),
            .pdf: PDFExtractor(),
            .image: ImageExtractor()
        ]
    }

    /// Extracts a file, choosing the extractor from its extension. Throws
    /// `ExtractionError.unsupportedFormat` for unknown/unhandled types.
    public func extract(fileURL: URL) async throws -> ExtractionResult {
        guard let format = SupportedDocumentTypes.format(for: fileURL) else {
            throw ExtractionError.unsupportedFormat(fileURL.pathExtension)
        }
        guard let extractor = extractors[format.family] else {
            throw ExtractionError.unsupportedFormat(format.family.rawValue)
        }
        return try await extractor.extract(fileURL: fileURL)
    }
}
