import Foundation

// Milestone 3: Document Intelligence domain enums.
//
// These describe the lifecycle of an imported matter document instance as it
// flows through copy/hash, extraction, OCR, chunking, full-text indexing, and
// semantic embedding. Raw values are the stable persisted strings used in
// SupraStore and in generated outputs/reports.

/// High-level status of a single matter document instance.
public enum MatterDocumentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case importing
    case extracting
    case needsOCR = "needs_ocr"
    case ocrPending = "ocr_pending"
    case indexing
    case embedding
    case ready
    case needsReview = "needs_review"
    case failed
    case deleted
}

/// Status of text extraction for a document instance.
public enum DocumentExtractionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case extracted
    case needsOCR = "needs_ocr"
    case ocrComplete = "ocr_complete"
    case edited
    case failed
}

/// Status of search/index readiness for a document instance.
public enum DocumentIndexStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case notIndexed = "not_indexed"
    case textIndexed = "text_indexed"
    case semanticIndexed = "semantic_indexed"
    case ready
    case stale
    case failed
}

/// Phase of an active document processing job. Used for progress reporting and
/// for durable pause/resume at safe phase boundaries.
public enum DocumentProcessingPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case discovering
    case copyingHashing = "copying_hashing"
    case expandingAttachments = "expanding_attachments"
    case extractingText = "extracting_text"
    case detectingOCR = "detecting_ocr"
    case ocrProcessing = "ocr_processing"
    case chunking
    case fullTextIndexing = "full_text_indexing"
    case semanticEmbedding = "semantic_embedding"
    case finalizingReport = "finalizing_report"
    case complete
    case failed
    case paused
    case cancelled
}

/// Kind of source a locator/citation points at.
public enum DocumentSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pdfPage = "pdf_page"
    case image
    case text
    case markdown
    case html
    case xml
    case spreadsheetCellRange = "spreadsheet_cell_range"
    case emailBody = "email_body"
    case emailAttachment = "email_attachment"
    case convertedDocument = "converted_document"
}

/// Status of a document processing job in the app-wide FIFO queue.
public enum DocumentProcessingJobStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case active
    case paused
    case complete
    case failed
    case cancelled
}

/// Status of an import batch.
public enum DocumentImportBatchStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case discovering
    case processing
    case complete
    case completeWithFailures = "complete_with_failures"
    case failed
    case cancelled
}

/// Lifecycle of a source set attached to a generated output version.
public enum DocumentSourceSetStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case attached
    case discarded
}

/// How a source set was assembled.
public enum DocumentSourceSetMode: String, Codable, CaseIterable, Hashable, Sendable {
    case autoSource = "auto_source"
    case guided
    case chronology
}

/// Result of a single import-report line item, accounting for every discovered
/// file and attachment.
public enum DocumentImportDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case imported
    case duplicateBlobReused = "duplicate_blob_reused"
    case unsupported
    case extractionFailed = "extraction_failed"
    case ocrNeeded = "ocr_needed"
    case ocrFailed = "ocr_failed"
    case indexed
    case embeddingPending = "embedding_pending"
    case embeddingComplete = "embedding_complete"
    case embeddingFailed = "embedding_failed"
    case skippedByUser = "skipped_by_user"
}
