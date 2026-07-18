import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class ParentContextRetrievalTests: XCTestCase {
    func testTRET01V2UsesParentContextWhileV1UsesCharacterNeighbors() async throws {
        // T-RET-01 expected RED: retrieval has no node-parent expansion path.
        let parentText = "PARENT-SENTINEL TARGET-WIRE"
        let neighborText = "V1-NEIGHBOR-SENTINEL"
        let text = parentText + "\n" + neighborText
        let fixture = try makeFixture(text: text)
        let targetStart = parentText.count - "TARGET-WIRE".count
        let structure = try installStructure(
            fixture,
            nodes: [
                node("parent", fixture: fixture, parentID: "root", ordinal: 0, kind: .paragraph, range: 0..<parentText.count),
                node("target", fixture: fixture, parentID: "parent", ordinal: 0, kind: .paragraph, range: targetStart..<parentText.count),
            ]
        )
        let targetNodeID = try XCTUnwrap(structure["target"])
        let target = chunk(
            id: "target-v2",
            fixture: fixture,
            nodeID: targetNodeID,
            unitKind: DocumentStructureNodeKind.paragraph.rawValue,
            version: 2,
            index: 0,
            range: targetStart..<parentText.count,
            text: "TARGET-WIRE"
        )
        let neighbor = chunk(
            id: "neighbor-v2",
            fixture: fixture,
            version: 2,
            index: 1,
            range: (parentText.count + 1)..<text.count,
            text: neighborText
        )
        try fixture.store.documentIndex.replaceChunks(documentID: fixture.document.id, chunks: [target, neighbor])
        try fixture.store.documentLibrary.updateIndexStatus(documentID: fixture.document.id, indexStatus: .textIndexed)

        let v2 = try await DocumentRetrievalService(store: fixture.store).retrieve(
            matterID: fixture.matterID,
            query: "TARGET-WIRE",
            scope: .wholeMatter,
            limit: 1
        )
        let v2Source = try XCTUnwrap(v2.sources.first)
        XCTAssertTrue(v2Source.text.contains("PARENT-SENTINEL"))
        XCTAssertFalse(v2Source.text.contains("V1-NEIGHBOR-SENTINEL"))
        XCTAssertEqual(v2Source.unitKind, DocumentStructureNodeKind.paragraph.rawValue)

        let v1Target = chunk(
            id: "target-v1",
            fixture: fixture,
            nodeID: targetNodeID,
            unitKind: nil,
            version: 1,
            index: 0,
            range: targetStart..<parentText.count,
            text: "TARGET-WIRE"
        )
        let v1Neighbor = chunk(
            id: "neighbor-v1",
            fixture: fixture,
            version: 1,
            index: 1,
            range: (parentText.count + 1)..<text.count,
            text: neighborText
        )
        try fixture.store.documentIndex.replaceChunks(documentID: fixture.document.id, chunks: [v1Target, v1Neighbor])
        let v1 = try await DocumentRetrievalService(store: fixture.store).retrieve(
            matterID: fixture.matterID,
            query: "TARGET-WIRE",
            scope: .wholeMatter,
            limit: 1
        )
        let v1Source = try XCTUnwrap(v1.sources.first)
        XCTAssertTrue(v1Source.text.contains("V1-NEIGHBOR-SENTINEL"))
        XCTAssertFalse(v1Source.text.contains("PARENT-SENTINEL"))
        XCTAssertNil(v1Source.unitKind)
    }

    func testTRET02HiddenNodeProvenanceSurvivesRetrievalAndPacking() async throws {
        // T-RET-02 expected RED: RetrievedSource/GroundingSource have no hidden
        // structural provenance and the packed envelope cannot disclose it.
        let privateText = "ROW-SECRET-WIRE"
        let publicText = "PUBLIC-WIRE"
        let text = privateText + "\n" + publicText
        let fixture = try makeFixture(text: text)
        let structure = try installStructure(
            fixture,
            nodes: [
                node(
                    "private-cell",
                    fixture: fixture,
                    parentID: "root",
                    ordinal: 0,
                    kind: .tableCell,
                    range: 0..<privateText.count,
                    payloadJSON: #"{"hidden":true,"hiddenSources":["row"]}"#
                ),
                node(
                    "public-cell",
                    fixture: fixture,
                    parentID: "root",
                    ordinal: 1,
                    kind: .tableCell,
                    range: (privateText.count + 1)..<text.count,
                    payloadJSON: #"{"hidden":false}"#
                ),
            ]
        )
        let hiddenChunk = chunk(
            id: "private-chunk",
            fixture: fixture,
            nodeID: try XCTUnwrap(structure["private-cell"]),
            unitKind: DocumentStructureNodeKind.tableCell.rawValue,
            version: 2,
            index: 0,
            range: 0..<privateText.count,
            text: privateText
        )
        try fixture.store.documentIndex.replaceChunks(documentID: fixture.document.id, chunks: [hiddenChunk])
        try fixture.store.documentLibrary.updateIndexStatus(documentID: fixture.document.id, indexStatus: .textIndexed)

        let hiddenResult = try await DocumentRetrievalService(store: fixture.store).retrieve(
            matterID: fixture.matterID,
            query: "ROW SECRET WIRE",
            scope: .wholeMatter,
            limit: 1
        )
        let hiddenSource = try XCTUnwrap(hiddenResult.sources.first)
        XCTAssertTrue(hiddenSource.hiddenDerived)
        XCTAssertEqual(hiddenSource.unitKind, DocumentStructureNodeKind.tableCell.rawValue)
        let hiddenPacked = DocumentQAPromptBuilder.buildSourceDataBlock(sources: [
            hiddenSource.groundingSource(sourceID: "matter/private", label: "S1", lowConfidence: false)
        ])
        XCTAssertTrue(hiddenPacked.contains(#""hidden":true"#))
        XCTAssertTrue(hiddenPacked.contains(#""hidden_content_disclosure":"Source content originated from a hidden spreadsheet sheet, row, or column.""#))
        XCTAssertTrue(hiddenPacked.contains(#""unit_kind":"table_cell""#))

        let publicChunk = chunk(
            id: "public-chunk",
            fixture: fixture,
            nodeID: try XCTUnwrap(structure["public-cell"]),
            unitKind: DocumentStructureNodeKind.tableCell.rawValue,
            version: 2,
            index: 0,
            range: (privateText.count + 1)..<text.count,
            text: publicText
        )
        try fixture.store.documentIndex.replaceChunks(documentID: fixture.document.id, chunks: [publicChunk])
        let publicResult = try await DocumentRetrievalService(store: fixture.store).retrieve(
            matterID: fixture.matterID,
            query: "PUBLIC WIRE",
            scope: .wholeMatter,
            limit: 1
        )
        let publicSource = try XCTUnwrap(publicResult.sources.first)
        XCTAssertFalse(publicSource.hiddenDerived)
        let publicPacked = DocumentQAPromptBuilder.buildSourceDataBlock(sources: [
            publicSource.groundingSource(sourceID: "matter/public", label: "S1", lowConfidence: false)
        ])
        XCTAssertFalse(publicPacked.contains(#""hidden":true"#))
        XCTAssertFalse(publicPacked.contains("hidden_content_disclosure"))
    }

    private struct Fixture {
        var store: SupraStore
        var matterID: String
        var document: MatterDocumentRecord
        var part: DocumentPagePartRecord
        var revision: DocumentPartRevisionRecord
    }

    private func makeFixture(text: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParentContextRetrieval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Synthetic parent context")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: UUID().uuidString,
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/parent-context.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "context.txt",
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.stale.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "part-\(document.id)",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "revision-\(document.id)",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "fixture",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "selection-\(document.id)",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "fixture",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        return Fixture(store: store, matterID: matter.id, document: document, part: part, revision: revision)
    }

    private func installStructure(
        _ fixture: Fixture,
        nodes: [DocumentStructureNodeRecord]
    ) throws -> [String: String] {
        let root = DocumentStructureNodeRecord(
            id: "root",
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodeKey: "document",
            ordinal: 0,
            kind: DocumentStructureNodeKind.document.rawValue
        )
        try fixture.store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: [root] + nodes,
            edges: []
        )
        return Dictionary(uniqueKeysWithValues: ([root] + nodes).map { ($0.nodeKey, $0.id) })
    }

    private func node(
        _ key: String,
        fixture: Fixture,
        parentID: String,
        ordinal: Int,
        kind: DocumentStructureNodeKind,
        range: Range<Int>,
        payloadJSON: String? = nil
    ) -> DocumentStructureNodeRecord {
        DocumentStructureNodeRecord(
            id: key,
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodeKey: key,
            parentNodeID: parentID,
            ordinal: ordinal,
            kind: kind.rawValue,
            charStart: range.lowerBound,
            charEnd: range.upperBound,
            payloadJSON: payloadJSON
        )
    }

    private func chunk(
        id: String,
        fixture: Fixture,
        nodeID: String? = nil,
        unitKind: String? = nil,
        version: Int,
        index: Int,
        range: Range<Int>,
        text: String
    ) -> DocumentChunkRecord {
        DocumentChunkRecord(
            id: id,
            documentID: fixture.document.id,
            pagePartID: fixture.part.id,
            revisionID: fixture.revision.id,
            nodeID: nodeID,
            unitKind: unitKind,
            chunkerVersion: version,
            chunkIndex: index,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: range.lowerBound,
            charEnd: range.upperBound,
            normalizedText: text,
            displayExcerpt: text,
            tokenCount: text.split(separator: " ").count
        )
    }
}
