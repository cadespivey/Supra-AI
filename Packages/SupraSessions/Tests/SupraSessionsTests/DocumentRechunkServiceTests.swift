import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentRechunkServiceTests: XCTestCase {
    func testTCHK07RechunksMatterCompletelyAndPreservesOldCitationDisplay() async throws {
        // T-CHK-07 expected RED: no matter-scoped re-chunk service/result exists.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic re-chunk matter")
        let text = "PARENT EVIDENCE. Target amount is 742.19."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "t-chk-07",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/t-chk-07.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "evidence.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "rechunk-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "rechunk-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "rechunk-fixture",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "rechunk-selection",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "rechunk-fixture",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        let root = DocumentStructureNodeRecord(
            id: "rechunk-root",
            documentID: document.id,
            revisionID: revision.id,
            nodeKey: "document",
            ordinal: 0,
            kind: DocumentStructureNodeKind.document.rawValue
        )
        let paragraph = DocumentStructureNodeRecord(
            id: "rechunk-paragraph",
            documentID: document.id,
            revisionID: revision.id,
            nodeKey: "paragraph",
            parentNodeID: root.id,
            ordinal: 0,
            kind: DocumentStructureNodeKind.paragraph.rawValue,
            charStart: 0,
            charEnd: text.count
        )
        try store.documentStructure.replaceStructure(
            documentID: document.id,
            revisionID: revision.id,
            nodes: [root, paragraph],
            edges: []
        )
        let legacyChunk = DocumentChunkRecord(
            id: "legacy-cited-chunk",
            documentID: document.id,
            pagePartID: part.id,
            revisionID: revision.id,
            chunkerVersion: 1,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text,
            displayExcerpt: "Target amount is 742.19."
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [legacyChunk])
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            retrievalQuery: "target amount"
        )
        let locatorJSON = DocumentSourceLocator(
            sourceKind: .text,
            charStart: 0,
            charEnd: text.count
        ).encodedJSON()
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            id: "historical-source",
            sourceSetID: sourceSet.id,
            documentID: document.id,
            chunkID: legacyChunk.id,
            citationLabel: "S1",
            locatorJSON: locatorJSON,
            excerpt: "Target amount is 742.19.",
            rank: 0
        ))

        // D-06 expected RED: the approved default-rollout coordinator does not
        // exist, so the flag cannot be switched together with a complete,
        // reversible all-matter re-chunk.
        let promoted = try await DocumentChunkerRolloutService(store: store).switchAllMatters(
            to: 2,
            actor: "test"
        )
        let result = try XCTUnwrap(promoted.matterResults.first)

        XCTAssertEqual(result.scheduledDocuments, 1)
        XCTAssertEqual(result.reindexedDocuments, 1)
        XCTAssertEqual(result.pendingDocuments, 0)
        XCTAssertEqual(result.textIndexedDocuments, 1)
        let chunks = try store.documentIndex.fetchChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.chunkerVersion == 2 })
        XCTAssertTrue(chunks.allSatisfy { $0.nodeID == paragraph.id })
        let historical = try XCTUnwrap(try store.documentSources.fetchSource(id: "historical-source"))
        XCTAssertNil(historical.chunkID)
        XCTAssertEqual(historical.revisionID, revision.id)
        XCTAssertEqual(historical.locatorJSON, locatorJSON)
        XCTAssertEqual(historical.excerpt, "Target amount is 742.19.")
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 2)

        let rolledBack = try await DocumentChunkerRolloutService(store: store).switchAllMatters(
            to: 1,
            actor: "test"
        )
        XCTAssertEqual(rolledBack.matterResults.first?.scheduledDocuments, 1)
        XCTAssertEqual(rolledBack.pendingDocuments, 0)
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 1)
        XCTAssertTrue(
            try store.documentIndex.fetchChunks(documentID: document.id)
                .allSatisfy { $0.chunkerVersion == 1 }
        )
        let historicalAfterRollback = try XCTUnwrap(
            try store.documentSources.fetchSource(id: "historical-source")
        )
        XCTAssertNil(historicalAfterRollback.chunkID)
        XCTAssertEqual(historicalAfterRollback.revisionID, revision.id)
        XCTAssertEqual(historicalAfterRollback.locatorJSON, locatorJSON)
        XCTAssertEqual(historicalAfterRollback.excerpt, "Target amount is 742.19.")

        let restored = try await DocumentChunkerRolloutService(store: store).switchAllMatters(
            to: 2,
            actor: "test"
        )
        XCTAssertEqual(restored.matterResults.first?.scheduledDocuments, 1)
        XCTAssertEqual(restored.pendingDocuments, 0)
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 2)
    }

    func testD06ApprovedDefaultPromotesOnceAndPreservesExplicitRollback() async throws {
        // D-06 expected RED: fresh settings still default to v1 and there is no
        // one-time approval marker that distinguishes upgrade promotion from an
        // operator's later explicit rollback.
        XCTAssertEqual(DocumentIntelligenceSettingsRecord().chunkerVersion, 2)
        let store = try makeStore()
        try store.documentSettings.updateSettings { $0.chunkerVersion = 1 }
        let rollout = DocumentChunkerRolloutService(store: store)

        let promotion = try await rollout.promoteApprovedDefaultIfNeeded(actor: "test")

        XCTAssertNotNil(promotion)
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 2)
        _ = try await rollout.switchAllMatters(to: 1, actor: "test")
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 1)

        let repeatedPromotion = try await rollout.promoteApprovedDefaultIfNeeded(actor: "test")

        XCTAssertNil(repeatedPromotion)
        XCTAssertEqual(
            try store.documentSettings.loadSettings().chunkerVersion,
            1,
            "the one-time migration must not erase an explicit rollback"
        )
    }

    func testD06TreatsExtractedEmptyDocumentAsTerminalTextIndexed() async throws {
        // D-06 live-rollout expected RED: an extracted document whose selected
        // text is empty produces no chunks, so the coordinator currently reports
        // it pending forever and refuses the otherwise complete default flip.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Empty extracted document")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "d06-empty-extracted-document",
            byteSize: 0,
            originalExtension: "txt",
            managedRelativePath: "blobs/d06-empty-extracted-document.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "empty.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: " \n\t ",
                charCount: 4
            ),
        ])

        let result = try await DocumentChunkerRolloutService(store: store).switchAllMatters(
            to: 2,
            actor: "test"
        )

        XCTAssertEqual(result.scheduledDocuments, 1)
        XCTAssertEqual(result.reindexedDocuments, 1)
        XCTAssertEqual(result.pendingDocuments, 0)
        XCTAssertEqual(result.textIndexedDocuments, 1)
        XCTAssertTrue(try store.documentIndex.fetchChunks(documentID: document.id).isEmpty)
        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: document.id)?.indexStatus,
            DocumentIndexStatus.textIndexed.rawValue
        )
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 2)
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentRechunkService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}
