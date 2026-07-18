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
    public var structure: ExtractedDocumentStructure
    public var method: String
    public var warnings: [String]
    /// True when the document has little/no embedded text and should be OCR'd
    /// (scanned PDF, image). OCR itself runs in WO 36.
    public var needsOCR: Bool
    /// Page indices needing OCR; empty when none.
    public var ocrPageIndices: [Int]
    public var attachments: [ExtractedAttachment]
    public var metadataCreatedAt: Date?
    public var metadataModifiedAt: Date?

    public init(
        parts: [ExtractedPart],
        structure: ExtractedDocumentStructure? = nil,
        method: String,
        warnings: [String] = [],
        needsOCR: Bool = false,
        ocrPageIndices: [Int] = [],
        attachments: [ExtractedAttachment] = [],
        metadataCreatedAt: Date? = nil,
        metadataModifiedAt: Date? = nil
    ) {
        self.parts = parts
        self.structure = structure ?? .wrapper(for: parts)
        self.method = method
        self.warnings = warnings
        self.needsOCR = needsOCR
        self.ocrPageIndices = ocrPageIndices
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
    case policyViolation(ImportPolicyViolation)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let reason): "Unsupported format: \(reason)"
        case .fileUnreadable(let reason): "File could not be read: \(reason)"
        case .malformed(let reason): "File is malformed: \(reason)"
        case .policyViolation(let violation): "Import rejected: \(violation.localizedDescription)"
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
    public let policy: ImportPolicy

    public init(
        policy: ImportPolicy = .default,
        extractors: [SupportedDocumentTypes.ExtractionFamily: any DocumentExtractor]? = nil
    ) {
        self.policy = policy
        self.extractors = extractors ?? ExtractionService.defaultExtractors(policy: policy)
    }

    public static func defaultExtractors(
        policy: ImportPolicy = .default
    ) -> [SupportedDocumentTypes.ExtractionFamily: any DocumentExtractor] {
        [
            .plainText: PlainTextExtractor(policy: policy),
            .markdown: PlainTextExtractor(policy: policy),
            .xml: XMLTextExtractor(policy: policy),
            .html: HTMLTextExtractor(policy: policy),
            .richText: RichTextExtractor(policy: policy),
            .word: WordExtractor(policy: policy),
            .spreadsheet: SpreadsheetExtractor(policy: policy),
            .email: EmailExtractor(policy: policy),
            .pdf: PDFExtractor(policy: policy),
            .image: ImageExtractor(policy: policy)
        ]
    }

    /// Extracts a file, choosing the extractor from its extension. Throws
    /// `ExtractionError.unsupportedFormat` for unknown/unhandled types.
    public func extract(fileURL: URL) async throws -> ExtractionResult {
        do {
            try policy.validateSource(at: fileURL)
        } catch let violation as ImportPolicyViolation {
            throw ExtractionError.policyViolation(violation)
        }
        guard let format = SupportedDocumentTypes.format(for: fileURL) else {
            throw ExtractionError.unsupportedFormat(fileURL.pathExtension)
        }
        guard let extractor = extractors[format.family] else {
            throw ExtractionError.unsupportedFormat(format.family.rawValue)
        }
        do {
            _ = try DocumentTypeDetector.validate(fileURL: fileURL, expected: format, policy: policy)
            let extracted = try await extract(
                extractor: extractor,
                fileURL: fileURL,
                timeoutSeconds: policy.maxParserDurationSeconds
            )
            try Task.checkCancellation()
            let result = LegalStructureRecognizer.enrich(extracted)
            try policy.validateExtractionResult(result)
            return result
        } catch let violation as ImportPolicyViolation {
            throw ExtractionError.policyViolation(violation)
        }
    }

    /// Races the parser against a real deadline. A synchronous framework parser
    /// may finish its already-bounded input after cancellation, but the import
    /// pipeline returns at the deadline and never waits indefinitely.
    private func extract(
        extractor: any DocumentExtractor,
        fileURL: URL,
        timeoutSeconds: Double
    ) async throws -> ExtractionResult {
        let resolution = ExtractionDeadlineResolution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.install(continuation)

                let work = Task.detached {
                    do {
                        resolution.resolve(.success(try await extractor.extract(fileURL: fileURL)))
                    } catch {
                        resolution.resolve(.failure(error))
                    }
                }
                resolution.setWork(work)

                let timer = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        resolution.resolve(.failure(ImportPolicyViolation(
                            .parserTimeLimit,
                            "Parser exceeded the \(timeoutSeconds)-second limit."
                        )))
                    } catch {
                        // The winning parser or caller cancellation stops the timer.
                    }
                }
                resolution.setTimer(timer)
            }
        } onCancel: {
            resolution.resolve(.failure(CancellationError()))
        }
    }
}

private final class ExtractionDeadlineResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExtractionResult, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pendingResult: Result<ExtractionResult, any Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<ExtractionResult, any Error>) {
        let pending = lock.withLock { () -> Result<ExtractionResult, any Error>? in
            if finished {
                let result = pendingResult
                pendingResult = nil
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func setWork(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if finished { return true }
            work = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func setTimer(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if finished { return true }
            timer = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func resolve(_ result: Result<ExtractionResult, any Error>) {
        let captured = lock.withLock { () -> (
            CheckedContinuation<ExtractionResult, any Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        ) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            if continuation == nil { pendingResult = result }
            let values = (continuation, work, timer)
            continuation = nil
            work = nil
            timer = nil
            return values
        }
        guard let continuation = captured.0 else { return }
        captured.1?.cancel()
        captured.2?.cancel()
        continuation.resume(with: result)
    }
}
