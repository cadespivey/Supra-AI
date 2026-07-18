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

        let result = try await DocumentRechunkService(store: store).rechunkMatter(
            matterID: matter.id,
            targetVersion: 2
        )

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
        XCTAssertEqual(try store.documentSettings.loadSettings().chunkerVersion, 1, "D-06 must remain owner-gated")
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentRechunkService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}
