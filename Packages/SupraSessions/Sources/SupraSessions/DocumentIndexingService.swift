import CryptoKit
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
    private let chunker: DocumentChunker?
    private let embedder: (any TextEmbedder)?
    private let stagedRolloutActiveChunkerVersion: Int?
    private let semanticBatchSize: Int

    public init(
        store: SupraStore,
        chunker: DocumentChunker? = nil,
        embedder: (any TextEmbedder)? = nil,
        stagedRolloutActiveChunkerVersion: Int? = nil,
        semanticBatchSize: Int = 32
    ) {
        self.store = store
        self.chunker = chunker
        self.embedder = embedder
        self.stagedRolloutActiveChunkerVersion = stagedRolloutActiveChunkerVersion
        self.semanticBatchSize = max(1, semanticBatchSize)
    }

    /// Chunks + FTS-indexes a document, then embeds its chunks if an embedder is
    /// configured. Returns the number of chunks produced.
    @discardableResult
    public func indexDocument(documentID: String) async throws -> Int {
        let document = try store.documentLibrary.fetchDocument(id: documentID)
        let selectedChunker = try chunker ?? DocumentChunker(
            version: store.documentSettings.loadSettings().chunkerVersion
        )
        let existingChunks = try store.documentIndex.fetchChunks(documentID: documentID)
        let canReuseTextIndex = !existingChunks.isEmpty
            && existingChunks.allSatisfy { $0.chunkerVersion == selectedChunker.version }
            && (document?.indexStatus == DocumentIndexStatus.ready.rawValue
                || document?.indexStatus == DocumentIndexStatus.textIndexed.rawValue)

        // A model switch changes only semantic lineage. Reuse the current chunks
        // and FTS rows so adding model-B vectors neither repeats text work nor
        // cascades away still-valid model-A vectors.
        if let embedder, canReuseTextIndex {
            let receipt = try store.documentReadiness.fetchReceipt(documentID: documentID)
            if receipt.isBaseReady,
               receipt.activeEmbeddingModelID == embedder.modelID {
                return existingChunks.count
            }

            let context = try verifiedEmbeddingContext(for: embedder)
            let newlyEmbedded = try await commitSemanticIndexStreaming(
                existingChunks,
                documentID: documentID,
                embedder: embedder,
                context: context
            )
            if newlyEmbedded > 0 {
                try recordSemanticCompletion(documentID: documentID, chunkCount: existingChunks.count)
            }
            return existingChunks.count
        }

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
        let revisionIDsByPartID = Dictionary(
            uniqueKeysWithValues: parts.compactMap { part in
                part.currentRevisionID.map { (part.id, $0) }
            }
        )
        let partIDsByRevisionID = Dictionary(
            uniqueKeysWithValues: revisionIDsByPartID.map { ($0.value, $0.key) }
        )
        let structureNodes = try store.documentStructure.fetchNodes(documentID: documentID)
        let chunkNodes = structureNodes.compactMap { node -> ChunkStructureNode? in
            guard let partID = partIDsByRevisionID[node.revisionID],
                  let kind = DocumentStructureNodeKind(rawValue: node.kind) else { return nil }
            return ChunkStructureNode(
                nodeID: node.id,
                parentNodeID: node.parentNodeID,
                partID: partID,
                revisionID: node.revisionID,
                ordinal: node.ordinal,
                kind: kind,
                charStart: node.charStart,
                charEnd: node.charEnd,
                textContent: node.textContent
            )
        }
        let documentNodeIDs = Set(chunkNodes.map(\.nodeID))
        let chunkEdges = try store.documentStructure.fetchEdges(documentID: documentID).compactMap { edge -> ChunkStructureEdge? in
            guard documentNodeIDs.contains(edge.fromNodeID),
                  documentNodeIDs.contains(edge.toNodeID),
                  let kind = DocumentStructureEdgeKind(rawValue: edge.kind) else { return nil }
            return ChunkStructureEdge(fromNodeID: edge.fromNodeID, toNodeID: edge.toNodeID, kind: kind)
        }
        let chunks = selectedChunker.chunk(parts: chunkParts, nodes: chunkNodes, edges: chunkEdges)
        let records = chunks.map { chunk in
            let revisionID = chunk.partID.flatMap { revisionIDsByPartID[$0] }
            return DocumentChunkRecord(
                id: deterministicChunkID(
                    documentID: documentID,
                    revisionID: revisionID,
                    chunk: chunk
                ),
                documentID: documentID,
                pagePartID: chunk.partID,
                revisionID: revisionID,
                nodeID: chunk.nodeID,
                unitKind: chunk.unitKind,
                chunkerVersion: chunk.chunkerVersion,
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
        let partBindings = parts.sorted {
            ($0.partIndex, $0.id) < ($1.partIndex, $1.id)
        }.map {
            DocumentReadinessPartBinding(
                partIndex: $0.partIndex,
                partID: $0.id,
                currentRevisionID: $0.currentRevisionID,
                currentSelectionID: $0.currentSelectionID
            )
        }
        // Replacement chunks, their FTS projection, and the text-index receipt
        // cross one optimistic Store transaction.
        _ = try store.documentIndex.commitTextIndex(
            DocumentTextIndexCommitCommand(
                documentID: documentID,
                expectedPartBindings: partBindings,
                expectedChunkerVersion: selectedChunker.version,
                expectedActiveChunkerVersion: stagedRolloutActiveChunkerVersion,
                semanticIndexExpected: embedder != nil && !records.isEmpty,
                chunks: records
            )
        )

        if let embedder, !records.isEmpty {
            let context = try verifiedEmbeddingContext(for: embedder)
            let newlyEmbedded = try await commitSemanticIndexStreaming(
                records,
                documentID: documentID,
                embedder: embedder,
                context: context
            )
            if newlyEmbedded > 0 {
                try recordSemanticCompletion(documentID: documentID, chunkCount: records.count)
            }
        }
        // The Store commands own every status transition. Without an embedder,
        // the text command makes an in-progress document searchable while
        // leaving semantic readiness explicitly incomplete. A document parked
        // in needs_review/failed retains that status.
        return records.count
    }

    private func deterministicChunkID(
        documentID: String,
        revisionID: String?,
        chunk: DocumentChunk
    ) -> String {
        // v1 keeps its historical row-identity behavior. V2 needs stable ids so
        // retries can prove the exact graph/text projection is unchanged.
        guard chunk.chunkerVersion == 2 else { return UUID().uuidString }
        let identity = [
            "chunk-v2",
            documentID,
            revisionID ?? "",
            chunk.partID ?? "",
            chunk.nodeID ?? "",
            String(chunk.chunkIndex),
            String(chunk.charStart),
            String(chunk.charEnd),
            chunk.text,
        ].joined(separator: "\u{001f}")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "chunk-v2-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Indexes every document in a matter that is extracted but not yet (fully)
    /// indexed, or whose index is stale. Returns the count indexed.
    @discardableResult
    public func indexMatter(matterID: String) async throws -> Int {
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
        var indexed = 0
        for document in documents {
            guard try needsIndexing(document) else { continue }
            // Honor cancellation between documents so stopping a large re-index (or an
            // app quit) doesn't keep churning through the remaining queue.
            try Task.checkCancellation()
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

    private func makeEmbeddings(
        _ records: [DocumentChunkRecord],
        documentID: String,
        embedder: any TextEmbedder
    ) async throws -> [DocumentChunkEmbeddingRecord] {
        let vectors = try await embedder.embed(records.map(\.normalizedText))
        guard vectors.count == records.count else {
            throw TextEmbedderError.embedFailed("vector/chunk count mismatch")
        }
        return zip(records, vectors).map { record, vector in
            let normalized = VectorMath.normalize(vector)
            return DocumentChunkEmbeddingRecord(
                chunkID: record.id,
                documentID: documentID,
                embeddingModelID: embedder.modelID,
                modelDisplayName: embedder.modelDisplayName,
                modelRevision: embedder.modelRevision,
                dimension: normalized.count,
                normalized: true,
                vector: VectorMath.encode(normalized)
            )
        }
    }

    /// Generates, normalizes, encodes, and commits one bounded vector batch at
    /// a time. Persisted, validated current-chunk vectors are skipped on
    /// relaunch. Only the Store's finalization transaction can publish terminal
    /// readiness after the complete vector set exists.
    private func commitSemanticIndexStreaming(
        _ records: [DocumentChunkRecord],
        documentID: String,
        embedder: any TextEmbedder,
        context: (
            identity: DocumentReadinessEmbeddingModelIdentity,
            verifiedAt: Date
        )
    ) async throws -> Int {
        let expectedChunkIDs = records.map(\.id)
        let completedChunkIDs = try store.documentIndex.fetchCompletedSemanticChunkIDs(
            documentID: documentID,
            expectedChunkIDs: expectedChunkIDs,
            expectedActiveModel: context.identity,
            expectedModelVerifiedAt: context.verifiedAt
        )
        let completed = Set(completedChunkIDs)
        let remaining = records.filter { !completed.contains($0.id) }

        // Preserve the existing exact all-in-one transition for a document that
        // fits within one bounded batch. Larger documents and resumed documents
        // use durable batch checkpoints.
        if completed.isEmpty, remaining.count <= semanticBatchSize {
            let embeddings = try await makeEmbeddings(
                remaining,
                documentID: documentID,
                embedder: embedder
            )
            _ = try store.documentIndex.commitSemanticIndex(
                DocumentSemanticIndexCommitCommand(
                    documentID: documentID,
                    expectedChunkIDs: expectedChunkIDs,
                    expectedActiveModel: context.identity,
                    expectedModelVerifiedAt: context.verifiedAt,
                    embeddings: embeddings
                )
            )
            return remaining.count
        }

        var index = 0
        while index < remaining.count {
            try Task.checkCancellation()
            let end = min(index + semanticBatchSize, remaining.count)
            let batch = Array(remaining[index..<end])
            let embeddings = try await makeEmbeddings(
                batch,
                documentID: documentID,
                embedder: embedder
            )
            _ = try store.documentIndex.commitSemanticIndexBatch(
                DocumentSemanticIndexBatchCommitCommand(
                    documentID: documentID,
                    expectedChunkIDs: expectedChunkIDs,
                    expectedActiveModel: context.identity,
                    expectedModelVerifiedAt: context.verifiedAt,
                    embeddings: embeddings
                )
            )
            index = end
        }

        _ = try store.documentIndex.finalizeSemanticIndex(
            DocumentSemanticIndexFinalizationCommand(
                documentID: documentID,
                expectedChunkIDs: expectedChunkIDs,
                expectedActiveModel: context.identity,
                expectedModelVerifiedAt: context.verifiedAt
            )
        )
        return remaining.count
    }

    private func verifiedEmbeddingContext(
        for embedder: any TextEmbedder
    ) throws -> (identity: DocumentReadinessEmbeddingModelIdentity, verifiedAt: Date) {
        let settings = try store.documentSettings.loadSettings()
        guard settings.selectedEmbeddingModelID == embedder.modelID else {
            throw DocumentReadinessTransitionError.modelSelectionInconsistent(embedder.modelID)
        }
        guard let model = try store.documentSettings.fetchEmbeddingModel(id: embedder.modelID) else {
            throw DocumentReadinessTransitionError.modelNotFound(embedder.modelID)
        }
        guard model.repoID == embedder.modelRepoID,
              model.revision == embedder.modelRevision,
              model.displayName == embedder.modelDisplayName,
              model.dimension == embedder.dimension else {
            throw DocumentReadinessTransitionError.modelIdentityChanged(embedder.modelID)
        }
        guard model.lastTestLoadResult == "passed",
              let verifiedAt = model.lastTestLoadAt else {
            throw DocumentReadinessTransitionError.modelNotVerified(embedder.modelID)
        }
        return (
            DocumentReadinessEmbeddingModelIdentity(
                id: model.id,
                repoID: model.repoID,
                revision: model.revision,
                dimension: model.dimension
            ),
            verifiedAt
        )
    }

    private func recordSemanticCompletion(documentID: String, chunkCount: Int) throws {
        _ = try? store.auditEvents.recordEvent(
            eventType: "semantic_indexing_completed",
            actor: "system",
            summary: "Embedded \(chunkCount) chunks",
            relatedTable: "matter_documents",
            relatedID: documentID
        )
    }

    private func needsIndexing(_ document: MatterDocumentRecord) throws -> Bool {
        // Skip documents still importing/needing OCR or that failed extraction.
        let extractionDone = document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
        guard extractionDone else { return false }
        switch DocumentIndexStatus(rawValue: document.indexStatus) {
        case .ready:
            guard let embedder else { return false }
            return try !store.documentIndex.hasCompleteEmbeddings(
                documentID: document.id,
                embeddingModelID: embedder.modelID
            )
        case .textIndexed:
            // Already chunked + FTS-indexed; only re-index to add embeddings when
            // an embedder is now available (otherwise it is fully indexed).
            guard let embedder else { return false }
            return try !store.documentIndex.hasCompleteEmbeddings(
                documentID: document.id,
                embeddingModelID: embedder.modelID
            )
        case .notIndexed, .stale, .failed, .none:
            return true
        }
    }
}
