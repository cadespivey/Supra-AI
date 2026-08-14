import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore

final class ArchitectureUXRagScanFixture {
    static let query = "QUERY_713"
    static let forbiddenDefault = "DEFAULT-000"
    static let dimension = 3
    static let pageSize = 3
    static let candidateK = 2
    static let cacheCeilingBytes = 17
    static let modelID = "t-rag-scan-model-713"
    static let modelRepoID = "synthetic/t-rag-scan-model-713"
    static let modelRevision = "t-rag-scan-model-revision-7"
    static let modelDisplayName = "Synthetic RAG Scan Model 713"
    static let verifiedAt = Date(timeIntervalSinceReferenceDate: 731_713)

    let root: URL
    let store: SupraStore
    let matterID: String
    let foreignMatterID: String

    var activeModel: DocumentReadinessEmbeddingModelIdentity {
        DocumentReadinessEmbeddingModelIdentity(
            id: Self.modelID,
            repoID: Self.modelRepoID,
            revision: Self.modelRevision,
            dimension: Self.dimension
        )
    }

    static func make(prefix: String) throws -> ArchitectureUXRagScanFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArchitectureUXRagScan-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "T_RAG_SCAN_01_WIRE_731")
        let foreignMatter = try store.matters.createMatter(name: "Foreign RAG matter 739")
        let fixture = ArchitectureUXRagScanFixture(
            root: root,
            store: store,
            matterID: matter.id,
            foreignMatterID: foreignMatter.id
        )
        try fixture.configureActiveModel()
        return fixture
    }

    init(root: URL, store: SupraStore, matterID: String, foreignMatterID: String) {
        self.root = root
        self.store = store
        self.matterID = matterID
        self.foreignMatterID = foreignMatterID
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func addDocument(
        id: String,
        matterID: String? = nil,
        vectors: [(chunkID: String, vector: [Float])],
        deleted: Bool = false,
        advanceSelectionAfterIndex: Bool = false,
        embeddingModelID: String = ArchitectureUXRagScanFixture.modelID,
        malformedVectorData: Data? = nil
    ) throws -> String {
        let ownerMatterID = matterID ?? self.matterID
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "blob-\(id)",
                sha256: "sha-\(id)",
                byteSize: 731,
                originalExtension: "txt",
                managedRelativePath: "blobs/\(id).txt"
            )
        ).blob
        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: id,
                matterID: ownerMatterID,
                blobID: blob.id,
                displayName: "\(id).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "plain_text@toolchain:synthetic-7",
                extractedTextChecksum: "checksum-\(id)-731",
                pagePartCount: 1
            )
        )
        let text = "T_RAG_SCAN_01_WIRE_731 \(Self.query) \(id)"
        let part = DocumentPagePartRecord(
            id: "part-\(id)-7",
            documentID: id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "revision-\(id)-7",
            documentID: id,
            partIndex: 0,
            derivationKey: "derivation-\(id)-7",
            origin: "synthetic_test",
            method: "plain_text",
            text: text,
            charCount: text.count,
            toolchainVersion: "synthetic-7"
        )
        let selection = DocumentPartSelectionRecord(
            id: "selection-\(id)-7",
            documentID: id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "selection-key-\(id)-7",
            selectedBy: "synthetic_policy",
            policyVersion: 7,
            decisionJSON: #"{"wire":"T_RAG_SCAN_01_WIRE_731"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        let chunks = vectors.enumerated().map { index, item in
            DocumentChunkRecord(
                id: item.chunkID,
                documentID: id,
                pagePartID: part.id,
                revisionID: revision.id,
                chunkerVersion: 2,
                chunkIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                charStart: 0,
                charEnd: text.count,
                normalizedText: "\(text) candidate \(index)",
                displayExcerpt: "\(text) candidate \(index)",
                tokenCount: 7
            )
        }
        try store.documentIndex.replaceChunks(documentID: id, chunks: chunks)
        for (index, item) in vectors.enumerated() {
            try store.documentIndex.upsertEmbedding(
                DocumentChunkEmbeddingRecord(
                    id: "embedding-\(item.chunkID)-7",
                    chunkID: item.chunkID,
                    documentID: id,
                    embeddingModelID: embeddingModelID,
                    modelDisplayName: Self.modelDisplayName,
                    modelRevision: Self.modelRevision,
                    dimension: Self.dimension,
                    normalized: true,
                    vector: malformedVectorData ?? VectorMath.encode(item.vector),
                    createdAt: Self.verifiedAt.addingTimeInterval(Double(index))
                )
            )
        }
        if advanceSelectionAfterIndex {
            let nextText = "T_RAG_SCAN_01_WIRE_731 stale revision 8 \(Self.query)"
            let nextRevision = try store.documentRevisions.appendRevision(
                DocumentPartRevisionRecord(
                    id: "revision-\(id)-8",
                    documentID: id,
                    partIndex: 0,
                    derivationKey: "derivation-\(id)-8",
                    origin: "synthetic_test",
                    method: "plain_text",
                    text: nextText,
                    charCount: nextText.count,
                    toolchainVersion: "synthetic-8",
                    supersedesRevisionID: revision.id
                )
            )
            _ = try store.documentRevisions.appendSelection(
                DocumentPartSelectionRecord(
                    id: "selection-\(id)-8",
                    documentID: id,
                    partIndex: 0,
                    selectedRevisionID: nextRevision.id,
                    selectionKey: "selection-key-\(id)-8",
                    selectedBy: "synthetic_policy",
                    policyVersion: 8,
                    decisionJSON: #"{"wire":"T_RAG_SCAN_01_WIRE_731_N_PLUS_1_8"}"#,
                    supersedesSelectionID: selection.id
                )
            )
        }
        if deleted {
            try store.documentLibrary.softDeleteDocument(id: id)
        }
        return id
    }

    private func configureActiveModel() throws {
        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Self.modelID,
                repoID: Self.modelRepoID,
                localPath: "/synthetic/rag-scan/model-713",
                displayName: Self.modelDisplayName,
                dimension: Self.dimension,
                runtimeFamily: "synthetic-rag-scan-7",
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

