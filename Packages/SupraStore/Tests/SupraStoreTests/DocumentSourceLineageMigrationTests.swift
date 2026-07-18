import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentSourceLineageMigrationTests: XCTestCase {
    func testTMIG08V066PreservesUnknownHistoryAndEnforcesMessageMatterLink() throws {
        // T-MIG-08 expected RED: the migration registry ends at v065 and source
        // sets have no packing, lineage, or idempotent message-link columns.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v066_add_document_source_lineage"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v065_create_document_relations")

        let matters = MattersRepository(writer: queue)
        let chats = ChatRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic v066 lineage matter")
        let foreignMatter = try matters.createMatter(name: "Synthetic v066 foreign matter")
        let chat = try chats.createMatterChat(matterID: matter.id, title: "Grounded packet")
        let message = try chats.createAssistantMessageShell(chatID: chat.id)
        let foreignChat = try chats.createMatterChat(matterID: foreignMatter.id, title: "Foreign packet")
        let foreignMessage = try chats.createAssistantMessageShell(chatID: foreignChat.id)
        let legacyID = "legacy-source-set"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO document_source_sets (
                    id, matter_id, status, mode, scope_json, retrieval_query,
                    retrieval_depth, created_at
                ) VALUES (?, ?, 'pending', 'auto_source', '{}', 'legacy query', 'fast', ?)
                """,
                arguments: [legacyID, matter.id, Date(timeIntervalSinceReferenceDate: 66)]
            )
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v069_add_verification_dimensions")
            XCTAssertEqual(Set(try db.columns(in: "document_source_sets").map(\.name)), Set([
                "id", "matter_id", "structured_output_version_id", "status", "mode",
                "scope_json", "retrieval_query", "retrieval_depth", "created_at",
                "packing_report_json", "embedding_model_id", "embedding_model_revision",
                "chunker_version", "retrieval_config_json", "corpus_snapshot_hash", "message_id",
            ]))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT \"unique\" FROM pragma_index_list('document_source_sets') WHERE name = 'idx_document_source_sets_message'"
                ),
                1
            )
            let foreignKey = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pragma_foreign_key_list('document_source_sets') WHERE \"from\" = 'message_id'"
            )
            XCTAssertEqual(foreignKey?["table"] as String?, "messages")
            XCTAssertEqual(foreignKey?["on_delete"] as String?, "SET NULL")
        }

        let sources = DocumentSourceRepository(writer: queue)
        let legacy = try XCTUnwrap(sources.fetchSourceSet(id: legacyID))
        XCTAssertNil(legacy.packingReportJSON)
        XCTAssertNil(legacy.embeddingModelID)
        XCTAssertNil(legacy.embeddingModelRevision)
        XCTAssertNil(legacy.chunkerVersion)
        XCTAssertNil(legacy.retrievalConfigJSON)
        XCTAssertNil(legacy.corpusSnapshotHash)
        XCTAssertNil(legacy.messageID)

        let created = try sources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            scopeJSON: #"{"document_ids":["doc-nondefault"]}"#,
            retrievalQuery: "nondefault query",
            retrievalDepth: "deep",
            packingReportJSON: #"{"schema_version":1}"#,
            embeddingModelID: "embedding-repo-nondefault",
            embeddingModelRevision: "revision-nondefault",
            chunkerVersion: 2,
            retrievalConfigJSON: #"{"rrf_k":61,"semantic_floor":0.37}"#,
            corpusSnapshotHash: "snapshot-nondefault",
            messageID: message.id
        )
        XCTAssertEqual(try sources.fetchSourceSet(messageID: message.id)?.id, created.id)
        XCTAssertEqual(created.messageID, message.id)
        XCTAssertEqual(created.chunkerVersion, 2)

        XCTAssertThrowsError(try sources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            packingReportJSON: #"{"schema_version":1}"#,
            embeddingModelID: "embedding-repo-nondefault",
            embeddingModelRevision: "revision-nondefault",
            chunkerVersion: 2,
            retrievalConfigJSON: #"{"rrf_k":61}"#,
            corpusSnapshotHash: "snapshot-nondefault",
            messageID: foreignMessage.id
        )) { error in
            XCTAssertEqual(
                error as? DocumentSourceRepositoryError,
                .messageMatterMismatch(foreignMessage.id)
            )
        }

        try queue.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [message.id])
        }
        XCTAssertNil(try XCTUnwrap(sources.fetchSourceSet(id: created.id)).messageID)
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }
}
