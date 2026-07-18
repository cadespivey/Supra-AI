import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class ChunkerV2IndexingTests: XCTestCase {
    func testTCHK05V2RerunIsDeterministicAndInvalidatesLegacyEmbeddingOnce() async throws {
        // T-CHK-05 expected RED: settings cannot select v2 and chunk rows have no
        // deterministic structure/revision/version binding.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic deterministic chunks")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "t-chk-05",
            byteSize: 53,
            originalExtension: "txt",
            managedRelativePath: "blobs/t-chk-05.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: "document-fixed",
            matterID: matter.id,
            blobID: blob.id,
            displayName: "fixed.txt",
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.stale.rawValue
        ))
        let text = "Request No. 1: State the total.\nResponse No. 1: 742.19."
        let part = DocumentPagePartRecord(
            id: "part-fixed",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "revision-fixed",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "fixed-revision",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count,
            createdAt: Date(timeIntervalSinceReferenceDate: 5)
        )
        let selection = DocumentPartSelectionRecord(
            id: "selection-fixed",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "fixed-selection",
            selectedBy: "test",
            policyVersion: 1,
            decisionJSON: #"{"rule":"fixed"}"#,
            createdAt: Date(timeIntervalSinceReferenceDate: 6)
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )

        let root = DocumentStructureNodeRecord(
            id: "node-root-fixed",
            documentID: document.id,
            revisionID: revision.id,
            nodeKey: "document",
            ordinal: 0,
            kind: DocumentStructureNodeKind.document.rawValue,
            createdAt: Date(timeIntervalSinceReferenceDate: 7)
        )
        let body = DocumentStructureNodeRecord(
            id: "node-body-fixed",
            documentID: document.id,
            revisionID: revision.id,
            nodeKey: "body",
            parentNodeID: root.id,
            ordinal: 0,
            kind: DocumentStructureNodeKind.paragraph.rawValue,
            charStart: 0,
            charEnd: text.count,
            createdAt: Date(timeIntervalSinceReferenceDate: 7)
        )
        try store.documentStructure.replaceStructure(
            documentID: document.id,
            revisionID: revision.id,
            nodes: [root, body],
            edges: []
        )

        let embedder = CountingChunkerEmbedder()
        try store.documentSettings.upsertEmbeddingModel(DocumentEmbeddingModelRecord(
            id: embedder.modelID,
            repoID: embedder.modelRepoID,
            displayName: embedder.modelDisplayName,
            dimension: embedder.dimension,
            runtimeFamily: "test"
        ))
        let legacy = DocumentChunkRecord(
            id: "legacy-random-chunk",
            documentID: document.id,
            pagePartID: part.id,
            revisionID: revision.id,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [legacy])
        try store.documentIndex.upsertEmbedding(DocumentChunkEmbeddingRecord(
            id: "legacy-embedding",
            chunkID: legacy.id,
            documentID: document.id,
            embeddingModelID: embedder.modelID,
            modelDisplayName: embedder.modelDisplayName,
            dimension: embedder.dimension,
            vector: VectorMath.encode([1, 0])
        ))
        try store.documentSettings.updateSettings { $0.chunkerVersion = 2 }
        try store.documentLibrary.updateIndexStatus(documentID: document.id, indexStatus: .stale)

        let indexer = DocumentIndexingService(store: store, embedder: embedder)
        _ = try await indexer.indexDocument(documentID: document.id)
        let first = try store.documentIndex.fetchChunks(documentID: document.id)
        let firstSnapshot = first.map(snapshot)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.chunkerVersion == 2 })
        XCTAssertTrue(first.allSatisfy { $0.nodeID == body.id })
        XCTAssertTrue(first.allSatisfy { $0.revisionID == revision.id })
        XCTAssertNil(try store.documentIndex.fetchChunk(id: legacy.id), "v2 replacement invalidates the legacy chunk exactly once")
        XCTAssertEqual(embedder.invocationCount, 1)

        _ = try await indexer.indexDocument(documentID: document.id)
        let second = try store.documentIndex.fetchChunks(documentID: document.id)
        XCTAssertEqual(second.map(snapshot), firstSnapshot)
        XCTAssertEqual(Set(second.map(\.id)).count, second.count)
        XCTAssertEqual(embedder.invocationCount, 1, "an identical v2 rerun must reuse complete embeddings")
        XCTAssertEqual(
            try store.documentIndex.fetchEmbeddings(documentID: document.id, embeddingModelID: embedder.modelID).count,
            second.count
        )
    }

    private func snapshot(_ chunk: DocumentChunkRecord) -> [String] {
        [
            chunk.id,
            String(chunk.chunkIndex),
            chunk.normalizedText,
            chunk.nodeID ?? "nil",
            chunk.revisionID ?? "nil",
            chunk.unitKind ?? "nil",
            String(chunk.chunkerVersion),
        ]
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkerV2Indexing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}

private final class CountingChunkerEmbedder: TextEmbedder, @unchecked Sendable {
    let modelID = "chunker-v2-model"
    let modelRepoID = "chunker-v2-model"
    let modelDisplayName = "Chunker v2 test model"
    let modelRevision: String? = "fixed"
    let dimension = 2

    private let lock = NSLock()
    private var calls = 0

    var invocationCount: Int { lock.withLock { calls } }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { calls += 1 }
        return texts.map { _ in [1, 0] }
    }
}
