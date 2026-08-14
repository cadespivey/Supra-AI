import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// T-EMBED-STREAM-01
///
/// Expected RED before WP-3.3: `DocumentIndexingService` lets the runtime split
/// RPCs, but then retains every returned vector until one document-wide semantic
/// commit. A crash therefore preserves no completed prefix and relaunch embeds
/// the whole document again.
final class ArchitectureUXTEmbedStream01Tests: XCTestCase {
    func testBoundedBatchesPersistAndRelaunchResumesWithoutDuplicates() async throws {
        let fixture = try EmbedStreamFixture.make()
        defer { fixture.remove() }

        let interrupted = StreamingProbeEmbedder(failOnCall: 2)
        let firstIndexer = DocumentIndexingService(
            store: fixture.store,
            chunker: DocumentChunker(version: 2),
            embedder: interrupted,
            semanticBatchSize: EmbedStreamFixture.batchSize
        )

        do {
            _ = try await firstIndexer.indexDocument(documentID: EmbedStreamFixture.documentID)
            XCTFail("T-EMBED-STREAM-01 expected the synthetic N+1 interruption")
        } catch {
            XCTAssertEqual(error as? StreamingProbeError, .injectedNPlusOne)
        }

        let interruptedBatchSizes = await interrupted.batchSizes()
        let interruptedMaximumVectors = await interrupted.maximumLiveVectorCount()
        XCTAssertEqual(interruptedBatchSizes, [3, 3])
        XCTAssertEqual(interruptedMaximumVectors, 3)
        XCTAssertEqual(
            try fixture.persistedChunkIDs(),
            Array(EmbedStreamFixture.chunkIDs.prefix(3)),
            "the first completed bounded batch must survive the N+1 interruption"
        )
        XCTAssertEqual(
            try fixture.document()?.indexStatus,
            DocumentIndexStatus.textIndexed.rawValue,
            "a partial vector prefix must never manufacture terminal readiness"
        )
        XCTAssertEqual(
            try fixture.readiness()?.primaryExclusion,
            .semanticIndexIncomplete
        )

        let resumed = StreamingProbeEmbedder(failOnCall: nil)
        let relaunchedIndexer = DocumentIndexingService(
            store: fixture.store,
            chunker: DocumentChunker(version: 2),
            embedder: resumed,
            semanticBatchSize: EmbedStreamFixture.batchSize
        )
        XCTAssertEqual(
            try await relaunchedIndexer.indexDocument(documentID: EmbedStreamFixture.documentID),
            EmbedStreamFixture.chunkIDs.count
        )

        let resumedBatchSizes = await resumed.batchSizes()
        let resumedMaximumVectors = await resumed.maximumLiveVectorCount()
        XCTAssertEqual(
            resumedBatchSizes,
            [3, 1],
            "relaunch must embed only the four uncommitted chunks"
        )
        XCTAssertEqual(resumedMaximumVectors, 3)
        XCTAssertEqual(try fixture.persistedChunkIDs(), EmbedStreamFixture.chunkIDs)
        XCTAssertEqual(Set(try fixture.persistedEmbeddingIDs()).count, 7)
        XCTAssertEqual(try fixture.persistedEmbeddingIDs().count, 7)
        XCTAssertTrue(try XCTUnwrap(fixture.readiness()).isBaseReady)
        XCTAssertEqual(try fixture.document()?.indexStatus, DocumentIndexStatus.ready.rawValue)

        let interruptedTexts = await interrupted.receivedTexts()
        let resumedTexts = await resumed.receivedTexts()
        let exactInput = (interruptedTexts + resumedTexts)
            .joined(separator: "|")
        XCTAssertTrue(exactInput.contains(EmbedStreamFixture.wire))
        XCTAssertTrue(exactInput.contains(EmbedStreamFixture.query))
        XCTAssertFalse(exactInput.contains(EmbedStreamFixture.forbiddenDefault))
        XCTAssertEqual(EmbedStreamFixture.pageSize, 3)
        XCTAssertEqual(EmbedStreamFixture.candidateK, 2)
        XCTAssertEqual(EmbedStreamFixture.dimension, 3)
        XCTAssertEqual(EmbedStreamFixture.cacheCeilingBytes, 17)
        XCTAssertNotEqual(EmbedStreamFixture.candidateK, 60)
    }
}

private enum StreamingProbeError: Error, Equatable {
    case injectedNPlusOne
}

private actor StreamingProbeEmbedder: TextEmbedder {
    nonisolated let modelID = EmbedStreamFixture.modelID
    nonisolated let modelRepoID = EmbedStreamFixture.modelRepoID
    nonisolated let modelDisplayName = EmbedStreamFixture.modelDisplayName
    nonisolated let modelRevision: String? = EmbedStreamFixture.modelRevision
    nonisolated let dimension = EmbedStreamFixture.dimension

    private let failOnCall: Int?
    private var callCount = 0
    private var observedBatchSizes: [Int] = []
    private var observedTexts: [String] = []
    private var maximumVectors = 0

    init(failOnCall: Int?) {
        self.failOnCall = failOnCall
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        callCount += 1
        observedBatchSizes.append(texts.count)
        observedTexts.append(contentsOf: texts)
        maximumVectors = max(maximumVectors, texts.count)
        if callCount == failOnCall {
            throw StreamingProbeError.injectedNPlusOne
        }
        return texts.enumerated().map { offset, _ in
            switch offset % 3 {
            case 0: [1, 0, 0]
            case 1: [0, 1, 0]
            default: [0, 0, 1]
            }
        }
    }

    func batchSizes() -> [Int] { observedBatchSizes }
    func receivedTexts() -> [String] { observedTexts }
    func maximumLiveVectorCount() -> Int { maximumVectors }
}

private final class EmbedStreamFixture {
    static let wire = "T_EMBED_STREAM_01_WIRE_731"
    static let query = "QUERY_713"
    static let forbiddenDefault = "DEFAULT-000"
    static let documentID = "t-embed-stream-document-731"
    static let modelID = "t-embed-stream-model-713"
    static let modelRepoID = "synthetic/t-embed-stream-model-713"
    static let modelDisplayName = "Synthetic Embed Stream 713"
    static let modelRevision = "t-embed-stream-revision-7"
    static let dimension = 3
    static let batchSize = 3
    static let pageSize = 3
    static let candidateK = 2
    static let cacheCeilingBytes = 17
    static let verifiedAt = Date(timeIntervalSinceReferenceDate: 731_713)
    static let chunkIDs = (0..<7).map { "t-embed-stream-chunk-\($0)-731" }

    let root: URL
    let store: SupraStore

    static func make() throws -> EmbedStreamFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArchitectureUXTEmbedStream01-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = EmbedStreamFixture(
            root: root,
            store: try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        )
        try fixture.seed()
        return fixture
    }

    init(root: URL, store: SupraStore) {
        self.root = root
        self.store = store
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func document() throws -> MatterDocumentRecord? {
        try store.documentLibrary.fetchDocument(id: Self.documentID)
    }

    func readiness() throws -> DocumentReadinessReceipt? {
        try store.documentReadiness.fetchReceipt(documentID: Self.documentID)
    }

    func persistedChunkIDs() throws -> [String] {
        try store.documentIndex.fetchEmbeddings(
            documentID: Self.documentID,
            embeddingModelID: Self.modelID
        ).map(\.chunkID).sorted()
    }

    func persistedEmbeddingIDs() throws -> [String] {
        try store.documentIndex.fetchEmbeddings(
            documentID: Self.documentID,
            embeddingModelID: Self.modelID
        ).map(\.id).sorted()
    }

    private func seed() throws {
        let matter = try store.matters.createMatter(name: "Synthetic Embed Stream Matter 731")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "t-embed-stream-blob-731",
                sha256: "t-embed-stream-blob-sha-731",
                byteSize: 731,
                originalExtension: "txt",
                managedRelativePath: "blobs/t-embed-stream-731.txt"
            )
        ).blob
        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: Self.documentID,
                matterID: matter.id,
                blobID: blob.id,
                displayName: "Synthetic Embed Stream 731.txt",
                status: MatterDocumentStatus.embedding.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "plain_text@toolchain:synthetic-731",
                extractedTextChecksum: "t-embed-stream-checksum-731",
                pagePartCount: 7
            )
        )

        let parts = (0..<7).map { index in
            let text = "\(Self.wire) \(Self.query) bounded passage \(index)."
            return DocumentPagePartRecord(
                id: "t-embed-stream-part-\(index)-731",
                documentID: Self.documentID,
                partIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            )
        }
        let revisions = parts.map { part in
            DocumentPartRevisionRecord(
                id: "t-embed-stream-revision-\(part.partIndex)-7",
                documentID: Self.documentID,
                partIndex: part.partIndex,
                derivationKey: "t-embed-stream-derivation-\(part.partIndex)-7",
                origin: "synthetic_test",
                method: "plain_text",
                text: part.normalizedText,
                charCount: part.charCount,
                toolchainVersion: "synthetic-7"
            )
        }
        let selections = revisions.map { revision in
            DocumentPartSelectionRecord(
                id: "t-embed-stream-selection-\(revision.partIndex)-7",
                documentID: Self.documentID,
                partIndex: revision.partIndex,
                selectedRevisionID: revision.id,
                selectionKey: "t-embed-stream-selection-key-\(revision.partIndex)-7",
                selectedBy: "synthetic_policy",
                policyVersion: 7,
                decisionJSON: #"{"wire":"T_EMBED_STREAM_01_WIRE_731"}"#
            )
        }
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: Self.documentID,
            parts: parts,
            revisions: revisions,
            selections: selections
        )

        let chunks = zip(parts, revisions).enumerated().map { index, pair in
            DocumentChunkRecord(
                id: Self.chunkIDs[index],
                documentID: Self.documentID,
                pagePartID: pair.0.id,
                revisionID: pair.1.id,
                chunkerVersion: 2,
                chunkIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                charStart: 0,
                charEnd: pair.0.normalizedText.count,
                normalizedText: pair.0.normalizedText,
                displayExcerpt: pair.0.normalizedText,
                tokenCount: 7
            )
        }
        try store.documentIndex.replaceChunks(documentID: Self.documentID, chunks: chunks)

        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Self.modelID,
                repoID: Self.modelRepoID,
                localPath: "/synthetic/t-embed-stream/model-713",
                displayName: Self.modelDisplayName,
                dimension: Self.dimension,
                runtimeFamily: "synthetic-embed-stream-7",
                revision: Self.modelRevision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: Self.verifiedAt,
                lastTestLoadResult: "passed",
                createdAt: Self.verifiedAt,
                updatedAt: Self.verifiedAt
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: Self.modelID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Self.verifiedAt
            $0.chunkerVersion = 2
        }
    }
}
