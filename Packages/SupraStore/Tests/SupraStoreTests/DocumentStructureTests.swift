import Foundation
import GRDB
@testable import SupraStore
import XCTest

@MainActor
final class DocumentStructureTests: XCTestCase {
    func testTSTR01ReplaceIsAtomicIdempotentAndRejectsMalformedTrees() throws {
        // T-STR-01 expected RED: v062 structure records and StructureRepository
        // do not exist, so no atomic replace-all tree contract can be exercised.
        let store = try SupraStore.inMemory()
        let fixture = try makeFixture(store: store, matterName: "Synthetic structure atomicity")
        let nodes = validNodes(documentID: fixture.document.id, revisionID: fixture.revision.id)
        let edges = [DocumentStructureEdgeRecord(
            id: "edge-reference-alpha",
            matterID: fixture.matter.id,
            fromNodeID: "node-body-alpha",
            toNodeID: "node-root-alpha",
            kind: "references"
        )]

        try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: edges
        )
        try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: edges
        )
        XCTAssertEqual(try store.documentStructure.fetchNodes(documentID: fixture.document.id), nodes)
        XCTAssertEqual(try store.documentStructure.fetchEdges(documentID: fixture.document.id), edges)

        var duplicateKey = nodes
        duplicateKey.append(DocumentStructureNodeRecord(
            id: "node-duplicate-alpha",
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodeKey: "part/0",
            parentNodeID: "node-root-alpha",
            ordinal: 1,
            kind: "paragraph",
            charStart: 6,
            charEnd: 10
        ))
        XCTAssertThrowsError(try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: duplicateKey,
            edges: edges
        ))

        let invalidEdges = edges + [DocumentStructureEdgeRecord(
            id: "edge-missing-endpoint",
            matterID: fixture.matter.id,
            fromNodeID: "node-body-alpha",
            toNodeID: "node-that-does-not-exist",
            kind: "references"
        )]
        XCTAssertThrowsError(try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: invalidEdges
        ))

        XCTAssertEqual(try store.documentStructure.fetchNodes(documentID: fixture.document.id), nodes)
        XCTAssertEqual(try store.documentStructure.fetchEdges(documentID: fixture.document.id), edges)
    }

    func testTSTR03RevisionRangesAndOutOfFlowTextRoundTripExactly() throws {
        // T-STR-03 expected RED: there is no revision-bound structure node text
        // resolver or validator for ranged versus out-of-flow node content.
        let store = try SupraStore.inMemory()
        let fixture = try makeFixture(
            store: store,
            matterName: "Synthetic locator round trip",
            text: "PREFIX repeated MIDDLE repeated SUFFIX"
        )
        let text = fixture.revision.text
        let first = try XCTUnwrap(characterOffsets(of: "repeated", occurrence: 0, in: text))
        let second = try XCTUnwrap(characterOffsets(of: "repeated", occurrence: 1, in: text))
        let nodes = [
            DocumentStructureNodeRecord(
                id: "node-root-roundtrip",
                documentID: fixture.document.id,
                revisionID: fixture.revision.id,
                nodeKey: "document",
                ordinal: 0,
                kind: "document"
            ),
            DocumentStructureNodeRecord(
                id: "node-first-repeat",
                documentID: fixture.document.id,
                revisionID: fixture.revision.id,
                nodeKey: "part/0/repeat/0",
                parentNodeID: "node-root-roundtrip",
                ordinal: 0,
                kind: "paragraph",
                charStart: first.start,
                charEnd: first.end
            ),
            DocumentStructureNodeRecord(
                id: "node-second-repeat",
                documentID: fixture.document.id,
                revisionID: fixture.revision.id,
                nodeKey: "part/0/repeat/1",
                parentNodeID: "node-root-roundtrip",
                ordinal: 1,
                kind: "paragraph",
                charStart: second.start,
                charEnd: second.end
            ),
            DocumentStructureNodeRecord(
                id: "node-out-of-flow",
                documentID: fixture.document.id,
                revisionID: fixture.revision.id,
                nodeKey: "part/0/deletion/0",
                parentNodeID: "node-root-roundtrip",
                ordinal: 2,
                kind: "tracked_deletion",
                textContent: "DELETED-NONDEFAULT"
            ),
        ]
        try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: []
        )

        XCTAssertEqual(try store.documentStructure.resolveText(nodeID: "node-first-repeat"), "repeated")
        XCTAssertEqual(try store.documentStructure.resolveText(nodeID: "node-second-repeat"), "repeated")
        XCTAssertEqual(try store.documentStructure.resolveText(nodeID: "node-out-of-flow"), "DELETED-NONDEFAULT")
        XCTAssertGreaterThan(second.start, first.start, "the second repeated occurrence must retain its exact locator")
        XCTAssertTrue(nodes.dropFirst().allSatisfy { node in
            if let start = node.charStart, let end = node.charEnd {
                return 0 <= start && start < end && end <= text.count
            }
            return node.textContent?.isEmpty == false
        })

        let missingText = nodes + [DocumentStructureNodeRecord(
            id: "node-missing-text",
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodeKey: "part/0/missing",
            parentNodeID: "node-root-roundtrip",
            ordinal: 3,
            kind: "paragraph"
        )]
        XCTAssertThrowsError(try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: missingText,
            edges: []
        ))

        let conflictingText = nodes + [DocumentStructureNodeRecord(
            id: "node-conflicting-text",
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodeKey: "part/0/conflict",
            parentNodeID: "node-root-roundtrip",
            ordinal: 3,
            kind: "paragraph",
            charStart: first.start,
            charEnd: first.end,
            textContent: "NOT-THE-RANGE"
        )]
        XCTAssertThrowsError(try store.documentStructure.replaceStructure(
            documentID: fixture.document.id,
            revisionID: fixture.revision.id,
            nodes: conflictingText,
            edges: []
        ))
        XCTAssertEqual(try store.documentStructure.fetchNodes(documentID: fixture.document.id), nodes)
    }

    func testTMIG04V062CreatesExactStructureSchemaWithoutInventingLegacyTrees() throws {
        // T-MIG-04 expected RED: v062 and both structure tables are absent.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v062_create_document_structure"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v061_bind_document_output_source_revisions")

        let matters = MattersRepository(writer: queue)
        let library = DocumentLibraryRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic pre-structure fixture")
        let blob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "v062-legacy-blob",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/v062-legacy.txt"
        )).blob
        let document = try library.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "pre-structure.txt"
        ))
        _ = try DocumentRevisionRepository(writer: queue).appendRevision(DocumentPartRevisionRecord(
            id: "v062-legacy-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "v062-legacy-key",
            origin: "legacy_import",
            method: "plain-text",
            text: "LEGACY-TEXT-WITH-NO-FABRICATED-TREE",
            charCount: 35
        ))

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("document_structure_nodes"))
            XCTAssertTrue(try db.tableExists("document_structure_edges"))
            XCTAssertEqual(
                Set(try db.columns(in: "document_structure_nodes").map(\.name)),
                Set(["id", "document_id", "revision_id", "node_key", "parent_node_id", "ordinal", "kind", "char_start", "char_end", "text_content", "payload_json", "created_at"])
            )
            XCTAssertEqual(
                Set(try db.columns(in: "document_structure_edges").map(\.name)),
                Set(["id", "matter_id", "from_node_id", "to_node_id", "kind", "created_at"])
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_structure_nodes"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_structure_edges"), 0)

            let nodeForeignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(document_structure_nodes)")
            XCTAssertTrue(nodeForeignKeys.contains { ($0["from"] as String) == "document_id" && ($0["on_delete"] as String) == "CASCADE" })
            XCTAssertTrue(nodeForeignKeys.contains { ($0["from"] as String) == "revision_id" && ($0["on_delete"] as String) == "CASCADE" })
            XCTAssertTrue(nodeForeignKeys.contains { ($0["from"] as String) == "parent_node_id" && ($0["on_delete"] as String) == "CASCADE" })
            let edgeForeignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(document_structure_edges)")
            XCTAssertTrue(edgeForeignKeys.contains { ($0["from"] as String) == "matter_id" && ($0["on_delete"] as String) == "CASCADE" })
            XCTAssertTrue(edgeForeignKeys.contains { ($0["from"] as String) == "from_node_id" && ($0["on_delete"] as String) == "CASCADE" })
            XCTAssertTrue(edgeForeignKeys.contains { ($0["from"] as String) == "to_node_id" && ($0["on_delete"] as String) == "CASCADE" })

            let nodeIndexes = Set(try Row.fetchAll(db, sql: "PRAGMA index_list(document_structure_nodes)").compactMap { $0["name"] as String? })
            let edgeIndexes = Set(try Row.fetchAll(db, sql: "PRAGMA index_list(document_structure_edges)").compactMap { $0["name"] as String? })
            XCTAssertTrue(nodeIndexes.contains("idx_document_structure_nodes_key"))
            XCTAssertTrue(nodeIndexes.contains("idx_document_structure_nodes_parent"))
            XCTAssertTrue(edgeIndexes.contains("idx_document_structure_edges_endpoints"))
        }
    }

    private func validNodes(documentID: String, revisionID: String) -> [DocumentStructureNodeRecord] {
        [
            DocumentStructureNodeRecord(
                id: "node-root-alpha",
                documentID: documentID,
                revisionID: revisionID,
                nodeKey: "document",
                ordinal: 0,
                kind: "document"
            ),
            DocumentStructureNodeRecord(
                id: "node-body-alpha",
                documentID: documentID,
                revisionID: revisionID,
                nodeKey: "part/0",
                parentNodeID: "node-root-alpha",
                ordinal: 0,
                kind: "paragraph",
                charStart: 0,
                charEnd: 5
            ),
        ]
    }

    private func makeFixture(
        store: SupraStore,
        matterName: String,
        text: String = "ALPHA"
    ) throws -> (matter: MatterRecord, document: MatterDocumentRecord, revision: DocumentPartRevisionRecord) {
        let matter = try store.matters.createMatter(name: matterName)
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: UUID().uuidString,
            byteSize: Int64(text.utf8.count),
            originalExtension: "txt",
            managedRelativePath: "blobs/\(UUID().uuidString).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "structure.txt"
        ))
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "structure-revision-\(UUID().uuidString)",
            origin: "parser",
            method: "plain-text",
            text: text,
            charCount: text.count
        ))
        return (matter, document, revision)
    }

    private func characterOffsets(
        of needle: String,
        occurrence: Int,
        in haystack: String
    ) -> (start: Int, end: Int)? {
        var searchStart = haystack.startIndex
        var match: Range<String.Index>?
        for _ in 0...occurrence {
            guard let next = haystack.range(of: needle, range: searchStart..<haystack.endIndex) else {
                return nil
            }
            match = next
            searchStart = next.upperBound
        }
        guard let match else { return nil }
        return (
            haystack.distance(from: haystack.startIndex, to: match.lowerBound),
            haystack.distance(from: haystack.startIndex, to: match.upperBound)
        )
    }
}
