import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Chunks extracted parts, writes the FTS index, and (when an embedder is
/// available) generates and stores semantic embeddings, advancing each document's
/// index status (plan §7.1–§7.3). Re-runs for documents whose text was edited
/// (index status `stale`).
public final class DocumentIndexingService: @unchecked Sendable {
    private let store: SupraStore
    private let chunker: DocumentChunker
    private let embedder: (any TextEmbedder)?

    public init(
        store: SupraStore,
        chunker: DocumentChunker = DocumentChunker(),
        embedder: (any TextEmbedder)? = nil
    ) {
        self.store = store
        self.chunker = chunker
        self.embedder = embedder
    }

    /// Chunks + FTS-indexes a document, then embeds its chunks if an embedder is
    /// configured. Returns the number of chunks produced.
    @discardableResult
    public func indexDocument(documentID: String) async throws -> Int {
        let parts = try store.documentIndex.fetchParts(documentID: documentID)
        let chunkParts = parts.map { part in
            ChunkPart(
                partID: part.id,
                sourceKind: DocumentSourceKind(rawValue: part.sourceKind) ?? .text,
                text: part.normalizedText,
                pageIndex: part.pageIndex,
                pageLabel: part.pageLabel,
                sheetName: part.sheetName,
                cellRange: part.cellRange,
                emailPartPath: part.emailPartPath,
                ocrConfidence: part.ocrConfidence,
                boundingBoxesJSON: part.boundingBoxesJSON
            )
        }
        let chunks = chunker.chunk(parts: chunkParts)
        let records = chunks.map { chunk in
            DocumentChunkRecord(
                documentID: documentID,
                pagePartID: chunk.partID,
                chunkIndex: chunk.chunkIndex,
                sourceKind: chunk.sourceKind.rawValue,
                pageIndex: chunk.pageIndex,
                pageLabel: chunk.pageLabel,
                sheetName: chunk.sheetName,
                cellRange: chunk.cellRange,
                emailPartPath: chunk.emailPartPath,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                normalizedText: chunk.text,
                displayExcerpt: chunk.displayExcerpt,
                boundingBoxesJSON: chunk.boundingBoxesJSON,
                ocrConfidence: chunk.ocrConfidence,
                tokenCount: chunk.tokenCount
            )
        }
        // Replaces chunks + FTS rows and cascades away stale embeddings.
        try store.documentIndex.replaceChunks(documentID: documentID, chunks: records)
        try store.documentLibrary.updateIndexStatus(documentID: documentID, indexStatus: .textIndexed)

        if let embedder, !records.isEmpty {
            try await embedChunks(records, documentID: documentID, embedder: embedder)
            try store.documentLibrary.updateIndexStatus(documentID: documentID, indexStatus: .ready)
            _ = try? store.auditEvents.recordEvent(
                eventType: "semantic_indexing_completed", actor: "system",
                summary: "Embedded \(records.count) chunks", relatedTable: "matter_documents", relatedID: documentID
            )
        }
        // Without an embedder the document remains text-indexed (searchable);
        // semantic readiness requires embeddings.
        // The document is ready for search/Q&A once indexed.
        try store.documentLibrary.updateStatus(documentID: documentID, status: .ready)
        return records.count
    }

    /// Indexes every document in a matter that is extracted but not yet (fully)
    /// indexed, or whose index is stale. Returns the count indexed.
    @discardableResult
    public func indexMatter(matterID: String) async throws -> Int {
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
        var indexed = 0
        for document in documents where Self.needsIndexing(document, embedderAvailable: embedder != nil) {
            _ = try await indexDocument(documentID: document.id)
            indexed += 1
        }
        if indexed > 0 {
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "text_indexing_completed", actor: "system",
                summary: "Indexed \(indexed) documents"
            )
        }
        return indexed
    }

    private func embedChunks(_ records: [DocumentChunkRecord], documentID: String, embedder: any TextEmbedder) async throws {
        let vectors = try await embedder.embed(records.map(\.normalizedText))
        guard vectors.count == records.count else {
            throw TextEmbedderError.embedFailed("vector/chunk count mismatch")
        }
        for (record, vector) in zip(records, vectors) {
            let normalized = VectorMath.normalize(vector)
            try store.documentIndex.upsertEmbedding(
                DocumentChunkEmbeddingRecord(
                    chunkID: record.id,
                    documentID: documentID,
                    embeddingModelID: embedder.modelID,
                    modelDisplayName: embedder.modelDisplayName,
                    modelRevision: embedder.modelRevision,
                    dimension: normalized.count,
                    normalized: true,
                    vector: VectorMath.encode(normalized)
                )
            )
        }
    }

    private static func needsIndexing(_ document: MatterDocumentRecord, embedderAvailable: Bool) -> Bool {
        // Skip documents still importing/needing OCR or that failed extraction.
        let extractionDone = document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
        guard extractionDone else { return false }
        switch DocumentIndexStatus(rawValue: document.indexStatus) {
        case .ready, .semanticIndexed:
            return false
        case .textIndexed:
            // Already chunked + FTS-indexed; only re-index to add embeddings when
            // an embedder is now available (otherwise it is fully indexed).
            return embedderAvailable
        case .notIndexed, .stale, .failed, .none:
            return true
        }
    }
}
