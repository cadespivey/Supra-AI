import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationsV041ThroughV060(_ migrator: inout DatabaseMigrator) {
        // Milestone 4: ScratchPad daily notes -> billing. See Docs/ScratchPad-SPEC.md §2.
        migrator.registerMigration("v041_create_scratch_pad_days") { db in
            try db.create(table: "scratch_pad_days", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("day", .text).notNull()
                table.column("locked_at", .datetime)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_scratch_pad_days_day", on: "scratch_pad_days", columns: ["day"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v042_create_scratch_pad_entries") { db in
            try db.create(table: "scratch_pad_entries", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("day_id", .text).notNull().references("scratch_pad_days", onDelete: .cascade)
                table.column("seq", .integer).notNull()
                table.column("text", .text).notNull()
                table.column("mentions_json", .text)
                table.column("tags_json", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_scratch_pad_entries_day", on: "scratch_pad_entries", columns: ["day_id", "seq"], ifNotExists: true)
        }

        migrator.registerMigration("v043_create_scratch_pad_attachments") { db in
            try db.create(table: "scratch_pad_attachments", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("day_id", .text).notNull().references("scratch_pad_days", onDelete: .cascade)
                table.column("entry_id", .text).references("scratch_pad_entries", onDelete: .cascade)
                table.column("matter_document_id", .text).references("matter_documents", onDelete: .setNull)
                table.column("matter_id", .text).references("matters", onDelete: .setNull)
                table.column("evidence_kind", .text).notNull()
                table.column("evidence_signals_json", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_scratch_pad_attachments_day", on: "scratch_pad_attachments", columns: ["day_id"], ifNotExists: true)
        }

        migrator.registerMigration("v044_create_billing_drafts") { db in
            try db.create(table: "billing_drafts", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("day_id", .text).notNull().references("scratch_pad_days", onDelete: .cascade)
                table.column("version", .integer).notNull()
                table.column("model_id", .text)
                table.column("sensitivity", .double).notNull().defaults(to: 0.5)
                table.column("status", .text).notNull()
                table.column("reconciliation_json", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_billing_drafts_day", on: "billing_drafts", columns: ["day_id", "version"], ifNotExists: true)
        }

        migrator.registerMigration("v045_create_billing_line_items") { db in
            try db.create(table: "billing_line_items", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("draft_id", .text).notNull().references("billing_drafts", onDelete: .cascade)
                table.column("seq", .integer).notNull()
                table.column("client_id", .text)
                table.column("matter_id", .text)
                table.column("narrative", .text).notNull()
                table.column("hours", .double).notNull()
                table.column("work_date", .text).notNull()
                table.column("utbms_task_code", .text)
                table.column("utbms_activity_code", .text)
                table.column("timekeeper_id", .text)
                table.column("rate", .double)
                table.column("confidence", .text).notNull()
                table.column("evidence_json", .text)
                table.column("code_note", .text)
                table.column("user_edited", .boolean).notNull().defaults(to: false)
                table.column("source_entry_ids_json", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_billing_line_items_draft", on: "billing_line_items", columns: ["draft_id", "seq"], ifNotExists: true)
        }

        migrator.registerMigration("v046_create_matter_billing_profiles") { db in
            try db.create(table: "matter_billing_profiles", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull().references("matters", onDelete: .cascade)
                table.column("override_instructions", .text)
                table.column("billing_code_set", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_matter_billing_profiles_matter", on: "matter_billing_profiles", columns: ["matter_id"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v047_add_matter_ledes_fields") { db in
            try db.alter(table: "matters") { table in
                table.add(column: "client_id", .text)
                table.add(column: "client_matter_id", .text)
            }
        }

        // Per-matter narrative terminal-punctuation override (nil = inherit the
        // firm-wide setting). Drives deterministic export punctuation.
        migrator.registerMigration("v048_add_billing_narrative_terminal") { db in
            try db.alter(table: "matter_billing_profiles") { table in
                table.add(column: "narrative_terminal", .text)
            }
        }

        // One row per inline citation in an assistant message: legal-research
        // authorities ([A#], carrying a CourtListener URL) and matter-document
        // sources ([S#], carrying a documentID + locator) so the chat UI can resolve
        // a tapped marker to its destination (web page or in-app page preview).
        migrator.registerMigration("v049_create_message_citations") { db in
            try db.create(table: "message_citations", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text)
                    .notNull()
                    .references("messages", onDelete: .cascade)
                table.column("label", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("url", .text)
                table.column("document_id", .text)
                table.column("locator_json", .text)
                table.column("display_name", .text)
                table.column("match_text", .text)
                table.column("rank", .integer).notNull().defaults(to: 0)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_message_citations_message", on: "message_citations", columns: ["message_id", "rank"], ifNotExists: true)
        }

        migrator.registerMigration("v050_add_source_set_retrieval_depth") { db in
            // Which retrieval tier produced this source set ("fast" preliminary vs
            // "deep" full pass) — nil for pre-tier rows (all were deep-equivalent).
            try db.alter(table: "document_source_sets") { table in
                table.add(column: "retrieval_depth", .text)
            }
        }

        migrator.registerMigration("v051_add_authority_opinion_text") { db in
            // Hydrated opinion text persisted for user-SAVED authorities only (spec
            // §4.3/§8.3): grounds local-first research and the offline [A#] reader.
            try db.alter(table: "authorities") { table in
                table.add(column: "opinion_text", .text)
            }
        }

        migrator.registerMigration("v052_add_authority_case_summary") { db in
            // A model-generated ≤100-word summary of the opinion, persisted so the
            // Authorities list reads at a glance without regenerating.
            try db.alter(table: "authorities") { table in
                table.add(column: "case_summary", .text)
            }
        }

        migrator.registerMigration("v053_add_matter_sort_order") { db in
            // Position for the sidebar's manual sort mode. Nil = never manually
            // placed (such matters list after positioned ones).
            try db.alter(table: "matters") { table in
                table.add(column: "sort_order", .integer)
            }
        }

        migrator.registerMigration("v054_add_matter_pinned_at") { db in
            // When the matter was pinned to the top of the sidebar; nil = not
            // pinned. A timestamp (not a flag) so `updated_at` stays untouched
            // and the date-modified sort is never perturbed by pinning.
            try db.alter(table: "matters") { table in
                table.add(column: "pinned_at", .datetime)
            }
        }

        migrator.registerMigration("v055_add_output_verification_provenance") { db in
            try db.alter(table: "structured_output_versions") { table in
                table.add(column: "verification_status", .text)
                    .notNull()
                    .defaults(to: "legacy_unverified")
                table.add(column: "verification_version", .text)
                table.add(column: "verification_json", .text)
                table.add(column: "verified_at", .datetime)
            }

            // Existing generated content predates proposition-level verification.
            // Preserve every byte and source attachment, but never grandfather a
            // formerly complete output into the new clean state.
            try db.execute(
                sql: """
                UPDATE structured_outputs
                SET status = ?
                WHERE status = ?
                """,
                arguments: [
                    StructuredOutputStatus.needsReview.rawValue,
                    StructuredOutputStatus.complete.rawValue,
                ]
            )
        }

        migrator.registerMigration("v056_add_document_blob_integrity") { db in
            try db.alter(table: "document_blobs") { table in
                table.add(column: "integrity_status", .text)
                    .notNull()
                    .defaults(to: DocumentBlobIntegrityStatus.unverified.rawValue)
                table.add(column: "verified_at", .datetime)
                table.add(column: "integrity_error", .text)
            }
        }

        migrator.registerMigration("v057_add_remediation_recovery_queue") { db in
            try db.create(table: "remediation_recovery_items", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("matter_id", .text).references("matters", onDelete: .setNull)
                table.column("related_table", .text).notNull()
                table.column("related_id", .text).notNull()
                table.column("status", .text).notNull().defaults(to: RemediationRecoveryStatus.pending.rawValue)
                table.column("resolution", .text)
                table.column("created_at", .datetime).notNull()
                table.column("resolved_at", .datetime)
            }
            try db.create(
                index: "idx_remediation_recovery_identity",
                on: "remediation_recovery_items",
                columns: ["kind", "related_table", "related_id"],
                unique: true,
                ifNotExists: true
            )
            try db.create(
                index: "idx_remediation_recovery_status",
                on: "remediation_recovery_items",
                columns: ["status", "created_at"],
                ifNotExists: true
            )

            // Existing active output versions predate proposition verification.
            // The v055 status remains the enforcement boundary; this queue makes
            // every affected object discoverable and recoverable in product UI.
            try db.execute(sql: """
                INSERT OR IGNORE INTO remediation_recovery_items
                    (id, kind, matter_id, related_table, related_id, status, created_at)
                SELECT lower(hex(randomblob(16))), ?, o.matter_id, 'structured_outputs', o.id, ?, ?
                FROM structured_outputs o
                JOIN structured_output_versions v ON v.id = o.active_version_id
                WHERE o.deleted_at IS NULL AND v.verification_status = ?
                """, arguments: [
                    RemediationRecoveryKind.legacyStructuredOutput.rawValue,
                    RemediationRecoveryStatus.pending.rawValue,
                    Date(),
                    OutputVerificationStatus.legacyUnverified.rawValue,
                ])

            // Draft artifacts were file-only on the supported legacy lines. The
            // immutable audit event is the only durable, non-content identifier.
            try db.execute(sql: """
                INSERT OR IGNORE INTO remediation_recovery_items
                    (id, kind, matter_id, related_table, related_id, status, created_at)
                SELECT lower(hex(randomblob(16))), ?, matter_id, 'audit_events', id, ?, ?
                FROM audit_events
                WHERE event_type = 'draft_generated'
                """, arguments: [
                    RemediationRecoveryKind.legacyDraftArtifact.rawValue,
                    RemediationRecoveryStatus.pending.rawValue,
                    Date(),
                ])

            // Only a draft whose own line graph spans multiple matters is flagged;
            // unrelated matters in the database cannot create a recovery item.
            try db.execute(sql: """
                INSERT OR IGNORE INTO remediation_recovery_items
                    (id, kind, matter_id, related_table, related_id, status, created_at)
                SELECT lower(hex(randomblob(16))), ?, NULL, 'billing_drafts', bd.id, ?, ?
                FROM billing_drafts bd
                JOIN billing_line_items li ON li.draft_id = bd.id
                GROUP BY bd.id
                HAVING COUNT(DISTINCT li.matter_id) > 1
                """, arguments: [
                    RemediationRecoveryKind.multiMatterBillingDraft.rawValue,
                    RemediationRecoveryStatus.pending.rawValue,
                    Date(),
                ])
        }

        migrator.registerMigration("v058_add_document_job_kind") { db in
            try db.alter(table: "document_processing_jobs") { table in
                table.add(column: "kind", .text)
                    .notNull()
                    .defaults(to: DocumentProcessingJobKind.process.rawValue)
                table.add(column: "payload_json", .text)
            }
        }

        migrator.registerMigration("v059_create_document_import_sources") { db in
            try db.alter(table: "document_import_batches") { table in
                table.add(column: "target_folder_id", .text)
                table.add(column: "target_folder_requested", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
            try db.create(table: "document_import_sources") { table in
                table.column("id", .text).primaryKey()
                table.column("import_batch_id", .text)
                    .notNull()
                    .references("document_import_batches", onDelete: .cascade)
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("source_key", .text).notNull()
                table.column("source_display_path", .text).notNull()
                table.column("source_bookmark", .blob)
                table.column("parent_source_id", .text)
                    .references("document_import_sources", onDelete: .setNull)
                table.column("state", .text).notNull()
                table.column("rejection_code", .text)
                table.column("reason", .text)
                table.column("document_id", .text)
                    .references("matter_documents", onDelete: .setNull)
                table.column("blob_sha256", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_import_sources_batch_key",
                on: "document_import_sources",
                columns: ["import_batch_id", "source_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_import_sources_matter_state",
                on: "document_import_sources",
                columns: ["matter_id", "state"]
            )
        }

        migrator.registerMigration("v060_create_document_part_lineage") { db in
            try db.create(table: "document_part_revisions") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("part_index", .integer).notNull()
                table.column("derivation_key", .text).notNull()
                table.column("origin", .text).notNull()
                table.column("method", .text).notNull()
                table.column("text", .text).notNull()
                table.column("char_count", .integer).notNull()
                table.column("ocr_confidence", .double)
                table.column("bounding_boxes_json", .text)
                table.column("toolchain_version", .text)
                table.column("author", .text)
                table.column("reason", .text)
                table.column("supersedes_revision_id", .text)
                    .references("document_part_revisions", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_part_revisions_derivation",
                on: "document_part_revisions",
                columns: ["document_id", "part_index", "derivation_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_part_revisions_part",
                on: "document_part_revisions",
                columns: ["document_id", "part_index", "created_at"]
            )

            try db.create(table: "document_part_selections") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("part_index", .integer).notNull()
                table.column("selected_revision_id", .text)
                    .notNull()
                    .references("document_part_revisions", onDelete: .restrict)
                table.column("selection_key", .text).notNull()
                table.column("selected_by", .text).notNull()
                table.column("policy_version", .integer)
                table.column("decision_json", .text).notNull()
                table.column("supersedes_selection_id", .text)
                    .references("document_part_selections", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_part_selections_key",
                on: "document_part_selections",
                columns: ["document_id", "part_index", "selection_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_part_selections_part",
                on: "document_part_selections",
                columns: ["document_id", "part_index", "created_at"]
            )

            try db.alter(table: "document_pages_parts") { table in
                table.add(column: "current_revision_id", .text)
                    .references("document_part_revisions", onDelete: .setNull)
                table.add(column: "current_selection_id", .text)
                    .references("document_part_selections", onDelete: .setNull)
            }
            try db.alter(table: "document_chunks") { table in
                table.add(column: "revision_id", .text)
                    .references("document_part_revisions", onDelete: .setNull)
            }

            // Preserve every byte already selected in the compatible parts table.
            // A document-level edited flag is the only historical proof available,
            // so all of that document's parts receive user_edit origin together.
            try db.execute(sql: """
                INSERT INTO document_part_revisions (
                    id, document_id, part_index, derivation_key, origin, method,
                    text, char_count, ocr_confidence, bounding_boxes_json,
                    toolchain_version, author, reason, supersedes_revision_id, created_at
                )
                SELECT
                    'v060-revision:' || p.id,
                    p.document_id,
                    p.part_index,
                    'migration:v060:' || p.id,
                    CASE WHEN d.has_user_edited_text = 1 THEN 'user_edit' ELSE 'legacy_import' END,
                    COALESCE(d.extraction_method, 'legacy_import'),
                    p.normalized_text,
                    p.char_count,
                    p.ocr_confidence,
                    p.bounding_boxes_json,
                    NULL,
                    NULL,
                    'v060 compatible-text backfill',
                    NULL,
                    p.created_at
                FROM document_pages_parts p
                JOIN matter_documents d ON d.id = p.document_id
                """)
            try db.execute(sql: """
                INSERT INTO document_part_selections (
                    id, document_id, part_index, selected_revision_id,
                    selection_key, selected_by, policy_version, decision_json,
                    supersedes_selection_id, created_at
                )
                SELECT
                    'v060-selection:' || p.id,
                    p.document_id,
                    p.part_index,
                    'v060-revision:' || p.id,
                    'migration:v060:' || p.id,
                    'migration',
                    NULL,
                    '{"rule":"v060_compatible_text_backfill"}',
                    NULL,
                    p.created_at
                FROM document_pages_parts p
                """)
            try db.execute(sql: """
                UPDATE document_pages_parts
                SET current_revision_id = 'v060-revision:' || id,
                    current_selection_id = 'v060-selection:' || id
                """)
            try db.execute(sql: """
                UPDATE document_chunks
                SET revision_id = (
                    SELECT p.current_revision_id
                    FROM document_pages_parts p
                    WHERE p.id = document_chunks.page_part_id
                )
                WHERE page_part_id IS NOT NULL
                """)

            // Direct mutation is forbidden while the owning document exists.
            // Matter/document deletion still cascades the complete lineage graph.
            try db.execute(sql: """
                CREATE TRIGGER document_part_revisions_immutable_update
                BEFORE UPDATE ON document_part_revisions
                WHEN EXISTS (SELECT 1 FROM matter_documents WHERE id = OLD.document_id)
                BEGIN
                    SELECT RAISE(ABORT, 'document_part_revisions are immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER document_part_revisions_immutable_delete
                BEFORE DELETE ON document_part_revisions
                WHEN EXISTS (SELECT 1 FROM matter_documents WHERE id = OLD.document_id)
                BEGIN
                    SELECT RAISE(ABORT, 'document_part_revisions are immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER document_part_selections_immutable_update
                BEFORE UPDATE ON document_part_selections
                WHEN EXISTS (SELECT 1 FROM matter_documents WHERE id = OLD.document_id)
                BEGIN
                    SELECT RAISE(ABORT, 'document_part_selections are append-only');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER document_part_selections_immutable_delete
                BEFORE DELETE ON document_part_selections
                WHEN EXISTS (SELECT 1 FROM matter_documents WHERE id = OLD.document_id)
                BEGIN
                    SELECT RAISE(ABORT, 'document_part_selections are append-only');
                END
                """)
        }

    }
}
