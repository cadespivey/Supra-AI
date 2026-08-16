import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV076(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v076_link_export_publication_intents") { db in
            // Legacy export rows predate identity-owned publication and remain
            // explicitly unlinked. Every new publication supplies this exact
            // Store intent identity, which is unique across export rows.
            try db.alter(table: "document_exports") { table in
                table.add(column: "publication_intent_id", .text)
                    .references("draft_artifact_intents", onDelete: .cascade)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_document_exports_publication_intent
                ON document_exports(publication_intent_id)
                WHERE publication_intent_id IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_document_exports_owned_path
                ON document_exports(managed_relative_path)
                WHERE publication_intent_id IS NOT NULL
                """)

            // Bind the public Saved Work row to the same prepared intent that
            // owns its matter, format, and exact final filename. Deeper source-
            // version lineage is revalidated by the Store repository in this
            // same insertion transaction.
            try db.execute(sql: """
                CREATE TRIGGER document_export_publication_intent_insert_guard
                BEFORE INSERT ON document_exports
                WHEN NEW.publication_intent_id IS NOT NULL
                BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1
                        FROM draft_artifact_intents AS intent
                        WHERE intent.id = NEW.publication_intent_id
                          AND intent.artifact_kind = 'structured_output_export'
                          AND intent.status = 'prepared'
                          AND intent.matter_id = NEW.matter_id
                          AND intent.format = NEW.format
                          AND NEW.managed_relative_path =
                              'exports/' || NEW.matter_id || '/' || intent.file_name
                    ) THEN RAISE(ABORT, 'invalid export publication intent') END;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER document_export_publication_intent_update_guard
                BEFORE UPDATE OF publication_intent_id, structured_output_id,
                    structured_output_version_id, matter_id, format,
                    managed_relative_path
                ON document_exports
                WHEN OLD.publication_intent_id IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, 'identity-owned document exports are append-only');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER export_publication_completion_guard
                BEFORE UPDATE OF status ON draft_artifact_intents
                WHEN OLD.artifact_kind = 'structured_output_export'
                  AND NEW.status = 'completed'
                BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1
                        FROM document_exports AS export
                        WHERE export.publication_intent_id = OLD.id
                    ) THEN RAISE(ABORT, 'export intent completion requires exact link') END;
                END
                """)
        }

    }
}
