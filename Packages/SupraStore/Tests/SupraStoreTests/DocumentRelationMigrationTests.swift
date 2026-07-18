import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentRelationMigrationTests: XCTestCase {
    func testTMIG07V065SchemaAndDeterministicBackfill() throws {
        // Expected RED: migration registry ends at v064 and document_relations is absent.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v065_create_document_relations"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v064_create_corpus_analysis_ledger")

        let matters = MattersRepository(writer: queue)
        let library = DocumentLibraryRepository(writer: queue)
        let index = DocumentIndexRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic v065 contract family")
        let foreignMatter = try matters.createMatter(name: "Synthetic v065 foreign family")
        let exactA = try seedDocument(
            library: library, index: index, matterID: matter.id,
            id: "doc-a", blobID: "blob-exact", sha: "sha-exact", text: "Exact duplicate text."
        )
        let exactB = try seedDocument(
            library: library, index: index, matterID: matter.id,
            id: "doc-b", blobID: "blob-exact", sha: "sha-exact", text: "Exact duplicate text."
        )
        let normalizedA = try seedDocument(
            library: library, index: index, matterID: matter.id,
            id: "doc-c", blobID: "blob-render-a", sha: "sha-render-a",
            text: "Normalized section twelve covenant."
        )
        let normalizedB = try seedDocument(
            library: library, index: index, matterID: matter.id,
            id: "doc-d", blobID: "blob-render-b", sha: "sha-render-b",
            text: "Normalized section twelve covenant."
        )
        _ = try seedDocument(
            library: library, index: index, matterID: foreignMatter.id,
            id: "doc-z", blobID: "blob-foreign", sha: "sha-foreign",
            text: "Normalized section twelve covenant."
        )

        try migrator.migrate(queue)
        let firstRows = try relationRows(queue)
        try migrator.migrate(queue)
        let replayRows = try relationRows(queue)

        XCTAssertEqual(firstRows, replayRows)
        XCTAssertEqual(firstRows.count, 2)
        XCTAssertEqual(Set(firstRows.map(\.kind)), Set([
            DocumentRelationKind.exactDuplicate.rawValue,
            DocumentRelationKind.normalizedDuplicate.rawValue,
        ]))
        XCTAssertTrue(firstRows.allSatisfy {
            $0.matterID == matter.id
                && $0.reviewState == DocumentRelationReviewState.proposed.rawValue
                && $0.proposedBy == DocumentRelationProposer.system.rawValue
                && $0.reviewedBy == nil
                && $0.reviewedAt == nil
        })
        XCTAssertTrue(firstRows.contains {
            $0.relationKey == "doc-a|doc-b"
                && Set([$0.fromDocumentID, $0.toDocumentID]) == Set([exactA.id, exactB.id])
        })
        XCTAssertTrue(firstRows.contains {
            $0.relationKey == "doc-c|doc-d"
                && Set([$0.fromDocumentID, $0.toDocumentID]) == Set([normalizedA.id, normalizedB.id])
        })

        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v067_add_output_generation_lineage")
            XCTAssertEqual(Set(try db.columns(in: "document_relations").map(\.name)), Set([
                "id", "matter_id", "relation_key", "from_document_id", "to_document_id",
                "kind", "evidence_json", "confidence", "proposed_by", "review_state",
                "reviewed_by", "reviewed_at", "created_at",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "document_relations"), Set([
                "matter_id->matters:CASCADE",
                "from_document_id->matter_documents:CASCADE",
                "to_document_id->matter_documents:CASCADE",
            ]))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT \"unique\" FROM pragma_index_list('document_relations') WHERE name = 'idx_document_relations_matter_key_kind'"
                ),
                1
            )
        }

        try queue.write { db in
            try db.execute(sql: "DELETE FROM matter_documents WHERE id = ?", arguments: [normalizedA.id])
        }
        XCTAssertEqual(try relationRows(queue).count, 1, "document FK must cascade its relation")
    }

    private func seedDocument(
        library: DocumentLibraryRepository,
        index: DocumentIndexRepository,
        matterID: String,
        id: String,
        blobID: String,
        sha: String,
        text: String
    ) throws -> MatterDocumentRecord {
        let blob = try library.upsertBlob(DocumentBlobRecord(
            id: blobID,
            sha256: sha,
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(sha).txt"
        )).blob
        let document = try library.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: "\(id).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
        try index.replaceChunks(documentID: id, chunks: [
            DocumentChunkRecord(
                id: "chunk-\(id)",
                documentID: id,
                chunkIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text
            ),
        ])
        return document
    }

    private func relationRows(_ queue: DatabaseQueue) throws -> [RelationRow] {
        try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, matter_id, relation_key, from_document_id, to_document_id,
                       kind, evidence_json, confidence, proposed_by, review_state,
                       reviewed_by, reviewed_at
                FROM document_relations
                ORDER BY matter_id, relation_key, kind
                """
            ).map { row in
                RelationRow(
                    id: row["id"],
                    matterID: row["matter_id"],
                    relationKey: row["relation_key"],
                    fromDocumentID: row["from_document_id"],
                    toDocumentID: row["to_document_id"],
                    kind: row["kind"],
                    evidenceJSON: row["evidence_json"],
                    confidence: row["confidence"],
                    proposedBy: row["proposed_by"],
                    reviewState: row["review_state"],
                    reviewedBy: row["reviewed_by"],
                    reviewedAt: row["reviewed_at"]
                )
            }
        }
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    private func foreignKeyContracts(_ db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").map { row in
            "\(row["from"] as String)->\(row["table"] as String):\(row["on_delete"] as String)"
        })
    }
}

private struct RelationRow: Equatable {
    var id: String
    var matterID: String
    var relationKey: String
    var fromDocumentID: String
    var toDocumentID: String
    var kind: String
    var evidenceJSON: String
    var confidence: Double?
    var proposedBy: String?
    var reviewState: String
    var reviewedBy: String?
    var reviewedAt: Date?
}
