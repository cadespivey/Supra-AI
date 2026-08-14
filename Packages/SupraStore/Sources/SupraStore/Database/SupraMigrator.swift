import Foundation
import GRDB

public enum SupraMigrator {
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // NOTE: `eraseDatabaseOnSchemaChange` is deliberately NEVER enabled. It once
        // ran under `#if DEBUG`, but a Debug build opening the real store with a
        // mismatched migration registry silently wiped the user's database
        // (2026-07-10). The store must never destroy real data on a schema mismatch.
        // For a deliberate dev reset use `SupraDatabase.resetForDebug()`.

        // T_MIGRATION_01_WIRE_731: immutable registrations remain in exact version order.
        registerMigrationsV001ThroughV021(&migrator)
        registerMigrationsV022ThroughV040(&migrator)
        registerMigrationsV041ThroughV060(&migrator)
        registerMigrationsV061ThroughV071(&migrator)
        registerMigrationV072(&migrator)
        registerMigrationV073(&migrator)
        registerMigrationV074(&migrator)
        registerMigrationV075(&migrator)
        registerMigrationV076(&migrator)
        registerMigrationV077(&migrator)
        registerMigrationV078(&migrator)

        return migrator
    }

    #if DEBUG
    public static func deleteAllTables(_ db: Database) throws {
        // Cross-table integrity triggers may reference a child that must be
        // dropped earlier for foreign-key order. Remove schema triggers first so
        // SQLite never has to recompile one against an already-dropped table.
        let triggerNames = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
        )
        for triggerName in triggerNames {
            try db.execute(literal: "DROP TRIGGER IF EXISTS \(identifier: triggerName)")
        }
        for table in [
            "remediation_recovery_items",
            // v078 governed publication and receipt registration ledgers.
            "structured_work_product_publications",
            "research_packet_egress_consumptions",
            // v077 accepted research packet ledger: exact downstream bindings
            // and append-only children must be removed before their parents.
            "research_packet_work_product_bindings",
            "research_packet_version_dispositions",
            "research_packet_acceptance_receipts",
            "accepted_research_packet_sources",
            "accepted_research_packet_versions",
            "research_packet_candidate_sources",
            "research_packet_candidates",
            "grounded_chat_publications",
            // v074 canonical matter identity: receipt/relationship children first.
            "matter_identity_decision_receipts",
            "matter_identity_conversion_receipts",
            "matter_representations",
            "matter_parties",
            // Case File Review: children before project/matter ownership.
            "case_file_review_evidence_edges",
            "case_file_review_cell_generations",
            "case_file_review_cells",
            "case_file_review_rows",
            "case_file_review_columns",
            "case_file_review_tables",
            "case_file_review_projects",
            // Draft artifact intents are children of matters and must be gone
            // before the parent table is dropped during an explicit dev reset.
            "draft_artifact_intents",
            // Milestone 4 ScratchPad / billing tables: drop children before parents.
            "billing_line_items",
            "billing_drafts",
            "scratch_pad_attachments",
            "scratch_pad_entries",
            "scratch_pad_days",
            "matter_billing_profiles",
            // Milestone 3 document intelligence tables: drop children before parents.
            "document_exports",
            "document_classifications",
            "document_relations",
            "corpus_analysis_partition_slices",
            "corpus_analysis_partitions",
            "corpus_analysis_runs",
            "document_output_sources",
            "document_source_sets",
            "document_structure_edges",
            "document_structure_nodes",
            "document_processing_jobs",
            "document_import_sources",
            "document_import_batches",
            "document_chunk_embeddings",
            "document_embedding_models",
            "document_chunk_fts",
            "document_chunks",
            "document_pages_parts",
            "document_part_selections",
            "document_part_revisions",
            "document_tag_assignments",
            "document_tags",
            "matter_documents",
            "document_folders",
            "document_blobs",
            "document_intelligence_settings",
            "audit_events",
            "structured_output_versions",
            "structured_outputs",
            "authorities",
            "research_results",
            "research_queries",
            "network_requests",
            "research_sessions",
            "exported_reports",
            "model_validation_tests",
            "model_validation_runs",
            "diagnostic_events",
            "message_citations",
            "message_variants",
            "generation_sessions",
            "messages",
            "chats",
            "matters",
            "runtime_profiles",
            "models",
            "app_settings",
            "grdb_migrations"
        ] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
    #endif
}
