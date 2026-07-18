import Foundation
import SupraCore
import SupraDocuments
import SupraStore

public struct DocumentRechunkResult: Equatable, Sendable {
    public var matterID: String
    public var targetVersion: Int
    public var scheduledDocuments: Int
    public var reindexedDocuments: Int
    public var textIndexedDocuments: Int
    public var readyDocuments: Int
    public var pendingDocuments: Int
}

public enum DocumentRechunkError: Error, Equatable {
    case unsupportedChunkerVersion(Int)
}

/// Performs the one-time, matter-scoped migration after a chunker decision.
/// The caller chooses the target explicitly; this service never changes the
/// shipping default stored in document intelligence settings.
public final class DocumentRechunkService: @unchecked Sendable {
    private let store: SupraStore
    private let embedder: (any TextEmbedder)?

    public init(store: SupraStore, embedder: (any TextEmbedder)? = nil) {
        self.store = store
        self.embedder = embedder
    }

    public func rechunkMatter(matterID: String, targetVersion: Int) async throws -> DocumentRechunkResult {
        guard targetVersion == 1 || targetVersion == 2 else {
            throw DocumentRechunkError.unsupportedChunkerVersion(targetVersion)
        }
        let chunker = DocumentChunker(version: targetVersion)
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
        var scheduledDocumentIDs: [String] = []
        var replacedChunkerVersions = Set<Int>()

        for document in documents where extractionIsComplete(document) {
            let chunks = try store.documentIndex.fetchChunks(documentID: document.id)
            let status = DocumentIndexStatus(rawValue: document.indexStatus)
            let alreadyComplete = try targetProjectionIsComplete(
                documentID: document.id,
                targetVersion: targetVersion,
                chunks: chunks
            )
                && (status == .textIndexed || status == .ready)
            guard !alreadyComplete else { continue }
            replacedChunkerVersions.formUnion(chunks.map(\.chunkerVersion).filter { $0 != targetVersion })
            try Task.checkCancellation()
            try store.documentLibrary.updateIndexStatus(documentID: document.id, indexStatus: .stale)
            scheduledDocumentIDs.append(document.id)
        }

        for priorVersion in replacedChunkerVersions.sorted() {
            _ = try OutputStalenessService(store: store).chunkerVersionChanged(
                matterID: matterID,
                fromVersion: priorVersion,
                toVersion: targetVersion
            )
        }

        let reindexed = try await DocumentIndexingService(
            store: store,
            chunker: chunker,
            embedder: embedder
        ).indexMatter(matterID: matterID)

        var textIndexed = 0
        var ready = 0
        var pending = 0
        for documentID in scheduledDocumentIDs {
            guard let document = try store.documentLibrary.fetchDocument(id: documentID) else {
                pending += 1
                continue
            }
            let chunks = try store.documentIndex.fetchChunks(documentID: documentID)
            let targetProjectionExists = try targetProjectionIsComplete(
                documentID: documentID,
                targetVersion: targetVersion,
                chunks: chunks
            )
            switch (targetProjectionExists, DocumentIndexStatus(rawValue: document.indexStatus)) {
            case (true, .textIndexed): textIndexed += 1
            case (true, .ready): ready += 1
            default: pending += 1
            }
        }

        if !scheduledDocumentIDs.isEmpty {
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID,
                eventType: "document_rechunk_completed",
                actor: "system",
                summary: "Re-chunked \(reindexed) of \(scheduledDocumentIDs.count) documents with chunker v\(targetVersion)"
            )
        }

        return DocumentRechunkResult(
            matterID: matterID,
            targetVersion: targetVersion,
            scheduledDocuments: scheduledDocumentIDs.count,
            reindexedDocuments: reindexed,
            textIndexedDocuments: textIndexed,
            readyDocuments: ready,
            pendingDocuments: pending
        )
    }

    private func extractionIsComplete(_ document: MatterDocumentRecord) -> Bool {
        document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
    }

    /// Empty selected text has no chunker-specific projection to persist. Treat
    /// its empty chunk set as complete only after proving every persisted part is
    /// whitespace-only; a non-empty document that unexpectedly produces zero
    /// chunks remains pending and keeps the default flip fail-closed.
    private func targetProjectionIsComplete(
        documentID: String,
        targetVersion: Int,
        chunks: [DocumentChunkRecord]
    ) throws -> Bool {
        if !chunks.isEmpty {
            return chunks.allSatisfy { $0.chunkerVersion == targetVersion }
        }
        return try store.documentIndex.fetchParts(documentID: documentID).allSatisfy {
            $0.normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
