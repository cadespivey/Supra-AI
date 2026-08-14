import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV075(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v075_create_grounded_chat_publications") { db in
            // The source-set owner retains assurance-bearing evidence. The
            // idempotency receipt below remains content-free and stores only
            // stable identities and digests.
            try db.alter(table: "document_source_sets") { table in
                table.add(column: "terminal_verification_dimensions_json", .text)
                table.add(column: "terminal_assurance_state", .text)
                table.add(column: "terminal_authorization_evidence_json", .text)
            }
            try db.create(table: "grounded_chat_publications") { table in
                table.column("idempotency_key", .text).primaryKey()
                table.column("aggregate_digest_sha256", .text).notNull()
                table.column("terminal_content_sha256", .text).notNull()
                table.column("verification_dimensions_sha256", .text).notNull()
                table.column("authorization_evidence_sha256", .text).notNull()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("chat_id", .text).notNull()
                    .references("chats", onDelete: .cascade)
                table.column("message_id", .text).notNull().unique()
                    .references("messages", onDelete: .cascade)
                table.column("variant_id", .text).notNull().unique()
                    .references("message_variants", onDelete: .cascade)
                table.column("generation_session_id", .text).notNull().unique()
                    .references("generation_sessions", onDelete: .cascade)
                table.column("source_set_id", .text).notNull().unique()
                    .references("document_source_sets", onDelete: .cascade)
                table.column("assurance_state", .text).notNull()
                table.column("audit_event_id", .text).notNull().unique()
                    .references("audit_events")
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_grounded_chat_publications_matter",
                on: "grounded_chat_publications",
                columns: ["matter_id", "created_at"]
            )
            try db.execute(sql: """
                CREATE TRIGGER grounded_chat_terminal_evidence_update_guard
                BEFORE UPDATE OF terminal_verification_dimensions_json,
                    terminal_assurance_state, terminal_authorization_evidence_json
                ON document_source_sets
                WHEN EXISTS (
                    SELECT 1 FROM grounded_chat_publications
                    WHERE source_set_id = OLD.id
                ) AND (
                    NEW.terminal_verification_dimensions_json
                        IS NOT OLD.terminal_verification_dimensions_json
                    OR NEW.terminal_assurance_state IS NOT OLD.terminal_assurance_state
                    OR NEW.terminal_authorization_evidence_json
                        IS NOT OLD.terminal_authorization_evidence_json
                )
                BEGIN
                    SELECT RAISE(ABORT, 'grounded chat terminal evidence is append-only');
                END
                """)
        }

    }
}
