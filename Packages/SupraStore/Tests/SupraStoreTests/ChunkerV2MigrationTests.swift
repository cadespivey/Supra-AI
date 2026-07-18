import Foundation
import GRDB
@testable import SupraStore
import XCTest

final class ChunkerV2MigrationTests: XCTestCase {
    func testTMIG05V063AddsChunkStructureBindingAndDefaultOffSetting() throws {
        // T-MIG-05 expected RED: v063 and its additive columns do not exist.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v063_add_chunk_structure_binding"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v062_create_document_structure")

        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic v062 chunk fixture")
        let library = DocumentLibraryRepository(writer: queue)
        let blob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "v063-legacy-chunk-blob",
            byteSize: 6,
            originalExtension: "txt",
            managedRelativePath: "blobs/v063-legacy.txt"
        )).blob
        let document = try library.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "legacy.txt"
        ))
        let fixedDate = Date(timeIntervalSinceReferenceDate: 63)
        let part = DocumentPagePartRecord(
            id: "v063-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: "text",
            normalizedText: "LEGACY",
            charCount: 6,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let chunk = DocumentChunkRecord(
            id: "v063-chunk",
            documentID: document.id,
            pagePartID: part.id,
            chunkIndex: 0,
            sourceKind: "text",
            charStart: 0,
            charEnd: 6,
            normalizedText: "LEGACY",
            displayExcerpt: "LEGACY",
            tokenCount: 1,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let index = DocumentIndexRepository(writer: queue)
        try index.replaceParts(documentID: document.id, parts: [part])
        try index.replaceChunks(documentID: document.id, chunks: [chunk])
        try queue.write { db in
            try DocumentIntelligenceSettingsRecord(createdAt: fixedDate, updatedAt: fixedDate).insert(db)
        }

        let before = try legacyChunkBytes(queue, id: chunk.id)
        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v063_add_chunk_structure_binding")
            XCTAssertEqual(
                Set(try db.columns(in: "document_chunks").map(\.name)).intersection(["node_id", "unit_kind", "chunker_version"]),
                Set(["node_id", "unit_kind", "chunker_version"])
            )
            XCTAssertTrue(try db.columns(in: "document_intelligence_settings").contains { $0.name == "chunker_version" })
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT chunker_version FROM document_chunks WHERE id = ?", arguments: [chunk.id]), 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT node_id FROM document_chunks WHERE id = ?", arguments: [chunk.id]))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT unit_kind FROM document_chunks WHERE id = ?", arguments: [chunk.id]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT chunker_version FROM document_intelligence_settings WHERE id = 'default'"), 1)

            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(document_chunks)")
            XCTAssertTrue(foreignKeys.contains {
                ($0["from"] as String) == "node_id"
                    && ($0["table"] as String) == "document_structure_nodes"
                    && ($0["on_delete"] as String) == "SET NULL"
            })
        }
        XCTAssertEqual(try legacyChunkBytes(queue, id: chunk.id), before, "v063 must not rewrite legacy v1 chunk bytes")
    }

    func testFreshV063RowsDefaultToChunkerV1() throws {
        // T-MIG-05 expected RED: fresh rows have no default-off chunker flag.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let fixedDate = Date(timeIntervalSinceReferenceDate: 64)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO document_intelligence_settings (id, created_at, updated_at) VALUES ('default', ?, ?)",
                arguments: [fixedDate, fixedDate]
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT chunker_version FROM document_intelligence_settings WHERE id = 'default'"), 1)
        }
    }

    private func legacyChunkBytes(_ queue: DatabaseQueue, id: String) throws -> [String] {
        try queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                SELECT id, document_id, page_part_id, revision_id, chunk_index,
                       source_kind, char_start, char_end, normalized_text,
                       display_excerpt, token_count, created_at, updated_at
                FROM document_chunks WHERE id = ?
                """,
                arguments: [id]
            ))
            return [
                row["id"] as String,
                row["document_id"] as String,
                row["page_part_id"] as String,
                (row["revision_id"] as String?) ?? "nil",
                String(row["chunk_index"] as Int),
                row["source_kind"] as String,
                String(row["char_start"] as Int),
                String(row["char_end"] as Int),
                row["normalized_text"] as String,
                row["display_excerpt"] as String,
                String(row["token_count"] as Int),
                String((row["created_at"] as Date).timeIntervalSinceReferenceDate),
                String((row["updated_at"] as Date).timeIntervalSinceReferenceDate),
            ]
        }
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }
}
