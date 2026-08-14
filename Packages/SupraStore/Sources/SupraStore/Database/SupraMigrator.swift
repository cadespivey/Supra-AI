import CryptoKit
import Foundation
import GRDB
import SupraCore

public enum SupraMigrator {
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // NOTE: `eraseDatabaseOnSchemaChange` is deliberately NEVER enabled. It once
        // ran under `#if DEBUG`, but a Debug build opening the real store with a
        // mismatched migration registry silently wiped the user's database
        // (2026-07-10). The store must never destroy real data on a schema mismatch.
        // For a deliberate dev reset use `SupraDatabase.resetForDebug()`.

        migrator.registerMigration("v001_create_app_settings") { db in
            try db.create(table: "app_settings", ifNotExists: true) { table in
                table.column("key", .text).primaryKey()
                table.column("value_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v002_create_models") { db in
            try db.create(table: "models", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("display_name", .text).notNull()
                table.column("path", .text).notNull()
                table.column("bookmark_data", .blob)
                table.column("is_active", .boolean).notNull().defaults(to: false)
                table.column("validation_status", .text)
                table.column("last_validated_at", .datetime)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_models_is_active", on: "models", columns: ["is_active"], ifNotExists: true)
        }

        migrator.registerMigration("v003_create_runtime_profiles") { db in
            try db.create(table: "runtime_profiles", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("model_id", .text)
                    .notNull()
                    .references("models", onDelete: .cascade)
                table.column("runtime_state", .text).notNull()
                table.column("load_time_ms", .integer)
                table.column("first_token_latency_ms", .integer)
                table.column("tokens_per_second", .double)
                table.column("cancellation_latency_ms", .integer)
                table.column("peak_memory_mb", .integer)
                table.column("generated_token_count", .integer)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_runtime_profiles_model_id", on: "runtime_profiles", columns: ["model_id"], ifNotExists: true)
        }

        migrator.registerMigration("v004_create_chats") { db in
            try db.create(table: "chats", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("scope", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_chats_scope", on: "chats", columns: ["scope"], ifNotExists: true)
        }

        migrator.registerMigration("v005_create_messages") { db in
            try db.create(table: "messages", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("chat_id", .text)
                    .notNull()
                    .references("chats", onDelete: .cascade)
                table.column("role", .text).notNull()
                table.column("content", .text).notNull().defaults(to: "")
                table.column("status", .text).notNull()
                table.column("active_variant_id", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_messages_chat_id", on: "messages", columns: ["chat_id", "created_at"], ifNotExists: true)
        }

        migrator.registerMigration("v006_create_generation_sessions") { db in
            try db.create(table: "generation_sessions", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("chat_id", .text)
                    .notNull()
                    .references("chats", onDelete: .cascade)
                table.column("message_id", .text)
                    .notNull()
                    .references("messages", onDelete: .cascade)
                table.column("variant_id", .text)
                table.column("model_id", .text)
                table.column("prompt", .text).notNull()
                table.column("system_prompt", .text)
                table.column("options_json", .text).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("first_token_at", .datetime)
                table.column("completed_at", .datetime)
                table.column("load_time_ms", .integer)
                table.column("first_token_latency_ms", .integer)
                table.column("tokens_per_second", .double)
                table.column("cancellation_latency_ms", .integer)
                table.column("peak_memory_mb", .integer)
                table.column("generated_token_count", .integer)
                table.column("error_summary", .text)
                table.column("interruption_reason", .text)
                table.column("diagnostic_event_id", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_generation_sessions_chat_id", on: "generation_sessions", columns: ["chat_id", "started_at"], ifNotExists: true)
            try db.create(index: "idx_generation_sessions_message_id", on: "generation_sessions", columns: ["message_id"], ifNotExists: true)
        }

        migrator.registerMigration("v007_create_message_variants") { db in
            try db.create(table: "message_variants", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text)
                    .notNull()
                    .references("messages", onDelete: .cascade)
                table.column("generation_session_id", .text)
                    .references("generation_sessions", onDelete: .setNull)
                table.column("content", .text).notNull().defaults(to: "")
                table.column("status", .text).notNull()
                table.column("interruption_reason", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_message_variants_message_id", on: "message_variants", columns: ["message_id", "created_at"], ifNotExists: true)
        }

        migrator.registerMigration("v008_create_diagnostic_events") { db in
            try db.create(table: "diagnostic_events", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("timestamp", .datetime).notNull()
                table.column("severity", .text).notNull()
                table.column("category", .text)
                table.column("message", .text).notNull()
                table.column("technical_details", .text)
                table.column("generation_id", .text)
                table.column("model_id", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_diagnostic_events_timestamp", on: "diagnostic_events", columns: ["timestamp"], ifNotExists: true)
        }

        migrator.registerMigration("v009_create_model_validation_runs") { db in
            try db.create(table: "model_validation_runs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("model_id", .text)
                    .notNull()
                    .references("models", onDelete: .cascade)
                table.column("suite_id", .text).notNull()
                table.column("suite_version", .integer).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("completed_at", .datetime)
                table.column("summary", .text)
                table.column("warnings_json", .text).notNull()
                table.column("errors_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_model_validation_runs_model_id", on: "model_validation_runs", columns: ["model_id", "started_at"], ifNotExists: true)
        }

        migrator.registerMigration("v010_create_model_validation_tests") { db in
            try db.create(table: "model_validation_tests", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("run_id", .text)
                    .notNull()
                    .references("model_validation_runs", onDelete: .cascade)
                table.column("test_id", .text).notNull()
                table.column("name", .text).notNull()
                table.column("status", .text).notNull()
                table.column("output_excerpt", .text).notNull().defaults(to: "")
                table.column("warnings_json", .text).notNull()
                table.column("errors_json", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("completed_at", .datetime)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_model_validation_tests_run_id", on: "model_validation_tests", columns: ["run_id", "started_at"], ifNotExists: true)
        }

        migrator.registerMigration("v011_create_exported_reports") { db in
            try db.create(table: "exported_reports", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("validation_run_id", .text)
                    .references("model_validation_runs", onDelete: .setNull)
                table.column("format", .text).notNull()
                table.column("file_url", .text).notNull()
                table.column("redacted", .boolean).notNull().defaults(to: true)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_exported_reports_validation_run_id", on: "exported_reports", columns: ["validation_run_id"], ifNotExists: true)
        }

        migrator.registerMigration("v012_create_matters") { db in
            try db.create(table: "matters", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.alter(table: "chats") { table in
                table.add(column: "matter_id", .text)
                    .references("matters", onDelete: .cascade)
            }
            try db.create(index: "idx_chats_matter_id", on: "chats", columns: ["matter_id"], ifNotExists: true)
        }

        migrator.registerMigration("v013_enrich_matters") { db in
            try db.alter(table: "matters") { table in
                table.add(column: "jurisdiction", .text).notNull().defaults(to: "Unspecified")
                table.add(column: "party_perspective", .text).notNull().defaults(to: "neutral")
                table.add(column: "court", .text)
                table.add(column: "judge", .text)
                table.add(column: "docket_number", .text)
                table.add(column: "practice_area", .text)
                table.add(column: "notes", .text)
            }
        }

        migrator.registerMigration("v014_create_research_sessions") { db in
            try db.create(table: "research_sessions", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("title", .text).notNull()
                table.column("issue_text", .text).notNull()
                table.column("jurisdiction", .text).notNull()
                table.column("preferred_courts_json", .text).notNull()
                table.column("excluded_courts_json", .text).notNull()
                table.column("date_range_start", .datetime)
                table.column("date_range_end", .datetime)
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("completed_at", .datetime)
            }
            try db.create(index: "idx_research_sessions_matter_id", on: "research_sessions", columns: ["matter_id", "created_at"], ifNotExists: true)
            try db.create(index: "idx_research_sessions_status", on: "research_sessions", columns: ["status"], ifNotExists: true)
        }

        migrator.registerMigration("v015_create_network_requests") { db in
            try db.create(table: "network_requests", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("timestamp", .datetime).notNull()
                table.column("domain", .text).notNull()
                table.column("method", .text).notNull()
                table.column("endpoint", .text).notNull()
                table.column("approved", .boolean).notNull()
                table.column("status_code", .integer)
                table.column("related_research_session_id", .text)
                    .references("research_sessions", onDelete: .setNull)
                table.column("blocked_reason", .text)
                table.column("error_message", .text)
                table.column("request_metadata_json", .text)
                table.column("response_metadata_json", .text)
            }
            try db.create(index: "idx_network_requests_timestamp", on: "network_requests", columns: ["timestamp"], ifNotExists: true)
            try db.create(index: "idx_network_requests_related_session", on: "network_requests", columns: ["related_research_session_id"], ifNotExists: true)
        }

        migrator.registerMigration("v016_create_research_queries") { db in
            try db.create(table: "research_queries", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("research_session_id", .text)
                    .notNull()
                    .references("research_sessions", onDelete: .cascade)
                table.column("query_text", .text).notNull()
                table.column("query_index", .integer).notNull()
                table.column("court_filter", .text)
                table.column("date_filed_after", .datetime)
                table.column("date_filed_before", .datetime)
                table.column("status", .text).notNull()
                table.column("result_count", .integer)
                table.column("next_url", .text)
                table.column("executed_at", .datetime)
                table.column("request_metadata_json", .text)
                table.column("response_metadata_json", .text)
                table.column("error_message", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_research_queries_session_id", on: "research_queries", columns: ["research_session_id", "query_index"], ifNotExists: true)
        }

        migrator.registerMigration("v017_create_research_results") { db in
            try db.create(table: "research_results", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("research_query_id", .text)
                    .notNull()
                    .references("research_queries", onDelete: .cascade)
                table.column("courtlistener_id", .text)
                table.column("cluster_id", .text)
                table.column("opinion_id", .text)
                table.column("case_name", .text).notNull()
                table.column("case_name_full", .text)
                table.column("citation_json", .text).notNull()
                table.column("preferred_citation", .text)
                table.column("court", .text)
                table.column("court_id", .text)
                table.column("date_filed", .datetime)
                table.column("docket_number", .text)
                table.column("snippet", .text)
                table.column("absolute_url", .text)
                table.column("review_state", .text).notNull()
                table.column("raw_result_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_research_results_query_id", on: "research_results", columns: ["research_query_id"], ifNotExists: true)
            try db.create(index: "idx_research_results_review_state", on: "research_results", columns: ["review_state"], ifNotExists: true)
        }

        migrator.registerMigration("v018_create_authorities") { db in
            try db.create(table: "authorities", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("research_session_id", .text)
                    .notNull()
                    .references("research_sessions", onDelete: .cascade)
                table.column("research_result_id", .text)
                    .notNull()
                    .references("research_results", onDelete: .cascade)
                table.column("courtlistener_id", .text)
                table.column("cluster_id", .text)
                table.column("opinion_id", .text)
                table.column("case_name", .text).notNull()
                table.column("case_name_full", .text)
                table.column("citation_json", .text).notNull()
                table.column("preferred_citation", .text)
                table.column("court", .text)
                table.column("court_id", .text)
                table.column("date_filed", .datetime)
                table.column("docket_number", .text)
                table.column("absolute_url", .text)
                table.column("precedential_status", .text)
                table.column("review_state", .text).notNull()
                table.column("use_status", .text).notNull()
                table.column("user_notes", .text)
                table.column("raw_metadata_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_authorities_matter_id", on: "authorities", columns: ["matter_id", "created_at"], ifNotExists: true)
            try db.create(index: "idx_authorities_matter_result", on: "authorities", columns: ["matter_id", "research_result_id"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v019_create_structured_outputs") { db in
            try db.create(table: "structured_outputs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("chat_id", .text)
                    .references("chats", onDelete: .setNull)
                table.column("research_session_id", .text)
                    .references("research_sessions", onDelete: .setNull)
                table.column("title", .text).notNull()
                table.column("output_type", .text).notNull()
                table.column("active_version_id", .text)
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_structured_outputs_matter_id", on: "structured_outputs", columns: ["matter_id", "updated_at"], ifNotExists: true)
        }

        migrator.registerMigration("v020_create_output_versions") { db in
            try db.create(table: "structured_output_versions", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("structured_output_id", .text)
                    .notNull()
                    .references("structured_outputs", onDelete: .cascade)
                table.column("version_index", .integer).notNull()
                table.column("parent_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("content_markdown", .text).notNull()
                table.column("required_sections_json", .text).notNull()
                table.column("present_sections_json", .text).notNull()
                table.column("missing_sections_json", .text).notNull()
                table.column("repair_reason", .text)
                table.column("generation_session_id", .text)
                    .references("generation_sessions", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_output_versions_output_id", on: "structured_output_versions", columns: ["structured_output_id", "version_index"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v021_create_audit_events_phase2") { db in
            try db.create(table: "audit_events", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .references("matters", onDelete: .setNull)
                table.column("timestamp", .datetime).notNull()
                table.column("event_type", .text).notNull()
                table.column("actor", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("related_table", .text)
                table.column("related_id", .text)
                table.column("metadata_json", .text)
            }
            try db.create(index: "idx_audit_events_matter_id", on: "audit_events", columns: ["matter_id", "timestamp"], ifNotExists: true)
            try db.create(index: "idx_audit_events_event_type", on: "audit_events", columns: ["event_type"], ifNotExists: true)
        }

        // MARK: - Milestone 3: Document Intelligence (v022+)

        migrator.registerMigration("v022_create_document_intelligence_settings") { db in
            try db.create(table: "document_intelligence_settings", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("selected_chat_model_id", .text)
                table.column("chat_model_last_loaded_at", .datetime)
                table.column("selected_embedding_model_id", .text)
                table.column("embedding_model_last_tested_at", .datetime)
                table.column("converter_toolchain_version", .text)
                table.column("converter_capability_json", .text)
                table.column("ocr_available", .boolean)
                table.column("ocr_checked_at", .datetime)
                table.column("notification_permission_status", .text)
                table.column("storage_initialized_at", .datetime)
                table.column("setup_completed_at", .datetime)
                table.column("setup_invalidated_reason", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v023_create_document_blobs") { db in
            try db.create(table: "document_blobs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("sha256", .text).notNull().unique()
                table.column("byte_size", .integer).notNull()
                table.column("original_extension", .text).notNull()
                table.column("managed_relative_path", .text).notNull()
                table.column("mime_type", .text)
                table.column("ut_type", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_blobs_sha256", on: "document_blobs", columns: ["sha256"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v024_create_document_folders") { db in
            try db.create(table: "document_folders", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("parent_folder_id", .text)
                    .references("document_folders", onDelete: .setNull)
                table.column("name", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_document_folders_matter_id", on: "document_folders", columns: ["matter_id", "parent_folder_id"], ifNotExists: true)
        }

        migrator.registerMigration("v025_create_matter_documents") { db in
            try db.create(table: "matter_documents", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("blob_id", .text)
                    .notNull()
                    .references("document_blobs", onDelete: .restrict)
                table.column("parent_document_id", .text)
                    .references("matter_documents", onDelete: .cascade)
                table.column("folder_id", .text)
                    .references("document_folders", onDelete: .setNull)
                // import_batch_id is a plain column (no FK): document_import_batches
                // is created later, in v033, so a SQL-level reference is not used.
                table.column("import_batch_id", .text)
                table.column("display_name", .text).notNull()
                table.column("imported_relative_path", .text)
                table.column("source_display_path", .text)
                table.column("status", .text).notNull()
                table.column("extraction_status", .text).notNull()
                table.column("index_status", .text).notNull()
                table.column("source_kind", .text)
                table.column("extraction_method", .text)
                table.column("extracted_text_checksum", .text)
                table.column("page_part_count", .integer)
                table.column("ocr_confidence_summary", .text)
                table.column("has_user_edited_text", .boolean).notNull().defaults(to: false)
                table.column("extraction_warnings_json", .text)
                table.column("extraction_errors_json", .text)
                table.column("metadata_created_at", .datetime)
                table.column("metadata_modified_at", .datetime)
                table.column("imported_at", .datetime).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "idx_matter_documents_matter_id", on: "matter_documents", columns: ["matter_id", "folder_id"], ifNotExists: true)
            try db.create(index: "idx_matter_documents_blob_id", on: "matter_documents", columns: ["blob_id"], ifNotExists: true)
            try db.create(index: "idx_matter_documents_parent", on: "matter_documents", columns: ["parent_document_id"], ifNotExists: true)
            try db.create(index: "idx_matter_documents_status", on: "matter_documents", columns: ["matter_id", "status"], ifNotExists: true)
        }

        migrator.registerMigration("v026_create_document_tags") { db in
            try db.create(table: "document_tags", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("color", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_tags_matter_name", on: "document_tags", columns: ["matter_id", "name"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v027_create_document_tag_assignments") { db in
            try db.create(table: "document_tag_assignments", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("tag_id", .text)
                    .notNull()
                    .references("document_tags", onDelete: .cascade)
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_tag_assignments_unique", on: "document_tag_assignments", columns: ["tag_id", "document_id"], unique: true, ifNotExists: true)
            try db.create(index: "idx_document_tag_assignments_document", on: "document_tag_assignments", columns: ["document_id"], ifNotExists: true)
        }

        migrator.registerMigration("v028_create_document_pages_parts") { db in
            try db.create(table: "document_pages_parts", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("part_index", .integer).notNull()
                table.column("source_kind", .text).notNull()
                table.column("page_index", .integer)
                table.column("page_label", .text)
                table.column("sheet_name", .text)
                table.column("cell_range", .text)
                table.column("email_part_path", .text)
                table.column("normalized_text", .text).notNull().defaults(to: "")
                table.column("char_count", .integer).notNull().defaults(to: 0)
                table.column("ocr_confidence", .double)
                table.column("bounding_boxes_json", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_pages_parts_document", on: "document_pages_parts", columns: ["document_id", "part_index"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v029_create_document_chunks") { db in
            try db.create(table: "document_chunks", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("page_part_id", .text)
                    .references("document_pages_parts", onDelete: .setNull)
                table.column("chunk_index", .integer).notNull()
                table.column("source_kind", .text).notNull()
                table.column("page_index", .integer)
                table.column("page_label", .text)
                table.column("sheet_name", .text)
                table.column("cell_range", .text)
                table.column("email_part_path", .text)
                table.column("char_start", .integer)
                table.column("char_end", .integer)
                table.column("normalized_text", .text).notNull().defaults(to: "")
                table.column("display_excerpt", .text)
                table.column("bounding_boxes_json", .text)
                table.column("ocr_confidence", .double)
                table.column("token_count", .integer)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_chunks_document", on: "document_chunks", columns: ["document_id", "chunk_index"], unique: true, ifNotExists: true)
        }

        migrator.registerMigration("v030_create_document_chunk_fts") { db in
            try db.create(virtualTable: "document_chunk_fts", ifNotExists: true, using: FTS5()) { table in
                table.column("text")
                table.column("chunk_id").notIndexed()
                table.column("document_id").notIndexed()
                table.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        migrator.registerMigration("v031_create_document_embedding_models") { db in
            try db.create(table: "document_embedding_models", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("repo_id", .text).notNull()
                table.column("local_path", .text)
                table.column("display_name", .text).notNull()
                table.column("dimension", .integer).notNull()
                table.column("runtime_family", .text).notNull()
                table.column("revision", .text)
                table.column("is_default", .boolean).notNull().defaults(to: false)
                table.column("is_selected", .boolean).notNull().defaults(to: false)
                table.column("last_test_load_at", .datetime)
                table.column("last_test_load_result", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_embedding_models_selected", on: "document_embedding_models", columns: ["is_selected"], ifNotExists: true)
        }

        migrator.registerMigration("v032_create_document_chunk_embeddings") { db in
            try db.create(table: "document_chunk_embeddings", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("chunk_id", .text)
                    .notNull()
                    .references("document_chunks", onDelete: .cascade)
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("embedding_model_id", .text).notNull()
                table.column("model_display_name", .text).notNull()
                table.column("model_revision", .text)
                table.column("dimension", .integer).notNull()
                table.column("normalized", .boolean).notNull().defaults(to: true)
                table.column("vector", .blob).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_chunk_embeddings_unique", on: "document_chunk_embeddings", columns: ["chunk_id", "embedding_model_id"], unique: true, ifNotExists: true)
            try db.create(index: "idx_document_chunk_embeddings_model", on: "document_chunk_embeddings", columns: ["embedding_model_id"], ifNotExists: true)
            try db.create(index: "idx_document_chunk_embeddings_document", on: "document_chunk_embeddings", columns: ["document_id"], ifNotExists: true)
        }

        migrator.registerMigration("v033_create_document_import_batches") { db in
            try db.create(table: "document_import_batches", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("status", .text).notNull()
                table.column("source_root_display", .text)
                table.column("discovered_count", .integer).notNull().defaults(to: 0)
                table.column("imported_count", .integer).notNull().defaults(to: 0)
                table.column("failed_count", .integer).notNull().defaults(to: 0)
                table.column("report_json", .text)
                table.column("started_at", .datetime).notNull()
                table.column("completed_at", .datetime)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_import_batches_matter", on: "document_import_batches", columns: ["matter_id", "started_at"], ifNotExists: true)
        }

        migrator.registerMigration("v034_create_document_processing_jobs") { db in
            try db.create(table: "document_processing_jobs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("import_batch_id", .text)
                    .references("document_import_batches", onDelete: .setNull)
                table.column("status", .text).notNull()
                table.column("phase", .text).notNull()
                table.column("queue_position", .integer)
                table.column("total_units", .integer).notNull().defaults(to: 0)
                table.column("completed_units", .integer).notNull().defaults(to: 0)
                table.column("phase_progress_json", .text)
                table.column("resume_state_json", .text)
                table.column("error_summary", .text)
                table.column("started_at", .datetime)
                table.column("paused_at", .datetime)
                table.column("completed_at", .datetime)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_processing_jobs_status", on: "document_processing_jobs", columns: ["status", "queue_position"], ifNotExists: true)
            try db.create(index: "idx_document_processing_jobs_matter", on: "document_processing_jobs", columns: ["matter_id", "created_at"], ifNotExists: true)
        }

        migrator.registerMigration("v035_create_document_source_sets") { db in
            try db.create(table: "document_source_sets", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("structured_output_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("status", .text).notNull()
                table.column("mode", .text).notNull()
                table.column("scope_json", .text).notNull()
                table.column("retrieval_query", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_source_sets_version", on: "document_source_sets", columns: ["structured_output_version_id"], ifNotExists: true)
            try db.create(index: "idx_document_source_sets_matter", on: "document_source_sets", columns: ["matter_id", "created_at"], ifNotExists: true)
        }

        migrator.registerMigration("v036_create_document_output_sources") { db in
            try db.create(table: "document_output_sources", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("source_set_id", .text)
                    .notNull()
                    .references("document_source_sets", onDelete: .cascade)
                table.column("structured_output_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("document_id", .text)
                    .references("matter_documents", onDelete: .setNull)
                table.column("chunk_id", .text)
                    .references("document_chunks", onDelete: .setNull)
                table.column("citation_label", .text).notNull()
                table.column("locator_json", .text).notNull()
                table.column("excerpt", .text).notNull().defaults(to: "")
                table.column("rank", .integer).notNull().defaults(to: 0)
                table.column("warnings_json", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_output_sources_set", on: "document_output_sources", columns: ["source_set_id", "rank"], ifNotExists: true)
            try db.create(index: "idx_document_output_sources_version", on: "document_output_sources", columns: ["structured_output_version_id"], ifNotExists: true)
        }

        migrator.registerMigration("v037_create_document_exports") { db in
            try db.create(table: "document_exports", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("structured_output_id", .text)
                    .references("structured_outputs", onDelete: .cascade)
                table.column("structured_output_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("format", .text).notNull()
                table.column("managed_relative_path", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_document_exports_output", on: "document_exports", columns: ["structured_output_id"], ifNotExists: true)
            try db.create(index: "idx_document_exports_matter", on: "document_exports", columns: ["matter_id", "created_at"], ifNotExists: true)
        }

        migrator.registerMigration("v038_add_matter_information_fields") { db in
            try db.alter(table: "matters") { table in
                table.add(column: "client_names", .text)
                table.add(column: "matter_description", .text)
                table.add(column: "internal_matter_id", .text)
            }
        }

        migrator.registerMigration("v039_add_document_classification_metadata") { db in
            try db.alter(table: "matter_documents") { table in
                table.add(column: "classification_metadata_json", .text)
            }
        }

        migrator.registerMigration("v040_add_authority_soft_delete") { db in
            try db.alter(table: "authorities") { table in
                table.add(column: "deleted_at", .datetime)
            }
        }

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

        migrator.registerMigration("v061_bind_document_output_source_revisions") { db in
            // Historical source rows deliberately stay NULL: their denormalized
            // excerpt/locator remains readable, but no exact revision can be
            // proven retroactively. New repository writes stamp the revision.
            try db.alter(table: "document_output_sources") { table in
                table.add(column: "revision_id", .text)
                    .references("document_part_revisions", onDelete: .setNull)
            }
            try db.create(
                index: "idx_document_output_sources_revision",
                on: "document_output_sources",
                columns: ["revision_id"]
            )
        }

        migrator.registerMigration("v062_create_document_structure") { db in
            // Legacy documents deliberately receive no fabricated tree. Their
            // wrapper is generated lazily on the next extraction/index pass.
            try db.create(table: "document_structure_nodes") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("revision_id", .text)
                    .notNull()
                    .references("document_part_revisions", onDelete: .cascade)
                table.column("node_key", .text).notNull()
                table.column("parent_node_id", .text)
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                table.column("kind", .text).notNull()
                table.column("char_start", .integer)
                table.column("char_end", .integer)
                table.column("text_content", .text)
                table.column("payload_json", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_structure_nodes_key",
                on: "document_structure_nodes",
                columns: ["document_id", "revision_id", "node_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_structure_nodes_parent",
                on: "document_structure_nodes",
                columns: ["document_id", "parent_node_id", "ordinal"]
            )

            try db.create(table: "document_structure_edges") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("from_node_id", .text)
                    .notNull()
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("to_node_id", .text)
                    .notNull()
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_structure_edges_endpoints",
                on: "document_structure_edges",
                columns: ["from_node_id", "to_node_id", "kind"],
                unique: true
            )
            try db.create(
                index: "idx_document_structure_edges_matter",
                on: "document_structure_edges",
                columns: ["matter_id", "kind"]
            )
        }

        migrator.registerMigration("v063_add_chunk_structure_binding") { db in
            // Existing chunks are v1 by definition. The additive defaults keep
            // their bytes/text and locators untouched while v2 remains opt-in.
            try db.alter(table: "document_chunks") { table in
                table.add(column: "node_id", .text)
                    .references("document_structure_nodes", onDelete: .setNull)
                table.add(column: "unit_kind", .text)
                table.add(column: "chunker_version", .integer)
                    .notNull()
                    .defaults(to: 1)
            }
            try db.create(
                index: "idx_document_chunks_node",
                on: "document_chunks",
                columns: ["node_id", "chunk_index"]
            )
            try db.alter(table: "document_intelligence_settings") { table in
                table.add(column: "chunker_version", .integer)
                    .notNull()
                    .defaults(to: 1)
            }
        }

        migrator.registerMigration("v064_create_corpus_analysis_ledger") { db in
            try db.create(table: "corpus_analysis_runs") { table in
                table.column("id", .text).primaryKey()
                table.column("run_key", .text).notNull()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("task_kind", .text).notNull()
                table.column("scope_json", .text).notNull()
                table.column("corpus_snapshot_json", .text).notNull()
                table.column("partition_strategy", .text).notNull()
                table.column("partition_strategy_version", .integer).notNull()
                table.column("model_lineage_json", .text)
                table.column("status", .text).notNull()
                table.column("coverage_json", .text)
                table.column("reconciliation_json", .text)
                table.column("validation_results_json", .text)
                table.column("assurance_state", .text)
                table.column("assurance_reasons_json", .text)
                table.column("structured_output_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
                table.column("completed_at", .datetime)
            }
            try db.create(
                index: "idx_corpus_analysis_runs_matter_key",
                on: "corpus_analysis_runs",
                columns: ["matter_id", "run_key"],
                unique: true
            )
            try db.create(
                index: "idx_corpus_analysis_runs_matter_status",
                on: "corpus_analysis_runs",
                columns: ["matter_id", "status", "created_at"]
            )

            try db.create(table: "corpus_analysis_partitions") { table in
                table.column("id", .text).primaryKey()
                table.column("run_id", .text).notNull()
                    .references("corpus_analysis_runs", onDelete: .cascade)
                table.column("partition_key", .text).notNull()
                table.column("input_revision_ids_json", .text).notNull()
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("attempt_history_json", .text).notNull().defaults(to: "[]")
                table.column("disposition", .text).notNull().defaults(to: "pending")
                table.column("disposition_reason", .text)
                table.column("findings_json", .text)
                table.column("error_summary", .text)
                table.column("started_at", .datetime)
                table.column("completed_at", .datetime)
            }
            try db.create(
                index: "idx_corpus_analysis_partitions_run_key",
                on: "corpus_analysis_partitions",
                columns: ["run_id", "partition_key"],
                unique: true
            )
            try db.create(
                index: "idx_corpus_analysis_partitions_run_disposition",
                on: "corpus_analysis_partitions",
                columns: ["run_id", "disposition", "partition_key"]
            )

            // Defense in depth for INV-10: even direct SQL/repository misuse
            // cannot persist corpus_complete while work is pending/failed or
            // while snapshot exclusions are undisclosed.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_guard
                BEFORE UPDATE OF status, assurance_state, coverage_json ON corpus_analysis_runs
                WHEN NEW.status = 'persisted' AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    ) THEN RAISE(ABORT, 'corpus_complete requires all partitions succeeded') END;
                    SELECT CASE WHEN COALESCE(
                        json_extract(NEW.coverage_json, '$.excluded_members_disclosed'), 0
                    ) <> 1 THEN RAISE(ABORT, 'corpus_complete requires disclosed exclusions') END;
                END
                """)
        }

        migrator.registerMigration("v065_create_document_relations") { db in
            try db.create(table: "document_relations") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("relation_key", .text).notNull()
                table.column("from_document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("to_document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("evidence_json", .text).notNull()
                table.column("confidence", .double)
                table.column("proposed_by", .text)
                table.column("review_state", .text).notNull().defaults(to: "proposed")
                table.column("reviewed_by", .text)
                table.column("reviewed_at", .datetime)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_relations_matter_key_kind",
                on: "document_relations",
                columns: ["matter_id", "relation_key", "kind"],
                unique: true
            )
            try db.create(
                index: "idx_document_relations_matter_review",
                on: "document_relations",
                columns: ["matter_id", "review_state", "kind", "created_at"]
            )
            try db.create(
                index: "idx_document_relations_from",
                on: "document_relations",
                columns: ["matter_id", "from_document_id", "kind"]
            )
            try db.create(
                index: "idx_document_relations_to",
                on: "document_relations",
                columns: ["matter_id", "to_document_id", "kind"]
            )
            try backfillDocumentRelations(db)
        }

        migrator.registerMigration("v066_add_document_source_lineage") { db in
            try db.alter(table: "document_source_sets") { table in
                table.add(column: "packing_report_json", .text)
                table.add(column: "embedding_model_id", .text)
                table.add(column: "embedding_model_revision", .text)
                table.add(column: "chunker_version", .integer)
                table.add(column: "retrieval_config_json", .text)
                table.add(column: "corpus_snapshot_hash", .text)
                table.add(column: "message_id", .text)
                    .references("messages", onDelete: .setNull)
            }
            try db.create(
                index: "idx_document_source_sets_message",
                on: "document_source_sets",
                columns: ["message_id"],
                unique: true
            )
        }

        migrator.registerMigration("v067_add_output_generation_lineage") { db in
            try db.alter(table: "structured_output_versions") { table in
                table.add(column: "prompt_builder_version", .text)
                table.add(column: "assurance_state", .text)
                table.add(column: "stale_reason", .text)
            }

            // Chat sessions predate document generation and required both chat
            // and message owners. Rebuild the table so a completed document
            // generation can use the same durable audit record without minting
            // synthetic chats/messages. The stable repository/revision pair is
            // deliberately separate from the per-load runtime UUID.
            try db.create(table: "generation_sessions_v067") { table in
                table.column("id", .text).primaryKey()
                table.column("chat_id", .text)
                    .references("chats", onDelete: .cascade)
                table.column("message_id", .text)
                    .references("messages", onDelete: .cascade)
                table.column("variant_id", .text)
                table.column("model_id", .text)
                table.column("model_repository", .text)
                table.column("model_revision", .text)
                table.column("prompt_builder_version", .text)
                table.column("prompt", .text).notNull()
                table.column("system_prompt", .text)
                table.column("options_json", .text).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("first_token_at", .datetime)
                table.column("completed_at", .datetime)
                table.column("load_time_ms", .integer)
                table.column("first_token_latency_ms", .integer)
                table.column("tokens_per_second", .double)
                table.column("cancellation_latency_ms", .integer)
                table.column("peak_memory_mb", .integer)
                table.column("generated_token_count", .integer)
                table.column("error_summary", .text)
                table.column("interruption_reason", .text)
                table.column("diagnostic_event_id", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.execute(sql: """
                INSERT INTO generation_sessions_v067 (
                    id, chat_id, message_id, variant_id, model_id,
                    prompt, system_prompt, options_json, status, started_at,
                    first_token_at, completed_at, load_time_ms,
                    first_token_latency_ms, tokens_per_second,
                    cancellation_latency_ms, peak_memory_mb,
                    generated_token_count, error_summary, interruption_reason,
                    diagnostic_event_id, created_at, updated_at
                )
                SELECT
                    id, chat_id, message_id, variant_id, model_id,
                    prompt, system_prompt, options_json, status, started_at,
                    first_token_at, completed_at, load_time_ms,
                    first_token_latency_ms, tokens_per_second,
                    cancellation_latency_ms, peak_memory_mb,
                    generated_token_count, error_summary, interruption_reason,
                    diagnostic_event_id, created_at, updated_at
                FROM generation_sessions
                """)
            try db.drop(table: "generation_sessions")
            try db.rename(table: "generation_sessions_v067", to: "generation_sessions")
            try db.create(
                index: "idx_generation_sessions_chat_id",
                on: "generation_sessions",
                columns: ["chat_id", "started_at"]
            )
            try db.create(
                index: "idx_generation_sessions_message_id",
                on: "generation_sessions",
                columns: ["message_id"]
            )

            // Only a unique v064 run link is enough evidence to copy assurance.
            // Unrelated and ambiguously-linked historical versions stay unknown.
            try db.execute(sql: """
                UPDATE structured_output_versions
                SET assurance_state = (
                    SELECT run.assurance_state
                    FROM corpus_analysis_runs AS run
                    WHERE run.structured_output_version_id = structured_output_versions.id
                      AND run.assurance_state IS NOT NULL
                    ORDER BY run.completed_at DESC, run.id
                    LIMIT 1
                )
                WHERE assurance_state IS NULL
                  AND (
                    SELECT COUNT(*)
                    FROM corpus_analysis_runs AS run
                    WHERE run.structured_output_version_id = structured_output_versions.id
                      AND run.assurance_state IS NOT NULL
                  ) = 1
                """)
        }

        migrator.registerMigration("v068_add_document_classification_lineage") { db in
            // Legacy `matter_documents.classification_metadata_json` remains the
            // compatible latest-value projection. Historical rows are not
            // backfilled because the mutable JSON has no trustworthy input,
            // model, prompt, sampling, or evidence lineage to recover.
            try db.create(table: "document_classifications") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("classification_key", .text).notNull()
                table.column("input_revision_ids_json", .text).notNull()
                table.column("input_checksum", .text).notNull()
                table.column("model_repository", .text).notNull()
                table.column("model_revision", .text).notNull()
                table.column("prompt_version", .text).notNull()
                table.column("sampling_strategy", .text).notNull()
                table.column("sampling_version", .integer).notNull()
                table.column("primary_category", .text)
                table.column("secondary_categories_json", .text).notNull()
                table.column("confidence_json", .text).notNull()
                table.column("calibration_version", .text).notNull()
                table.column("abstained", .boolean).notNull()
                table.column("abstention_reason", .text)
                table.column("evidence_spans_json", .text).notNull()
                table.column("warnings_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_classifications_identity",
                on: "document_classifications",
                columns: ["matter_id", "document_id", "classification_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_classifications_latest",
                on: "document_classifications",
                columns: ["matter_id", "document_id", "created_at", "id"]
            )
            try db.execute(sql: """
                CREATE TRIGGER document_classifications_immutable_update
                BEFORE UPDATE ON document_classifications
                BEGIN
                    SELECT RAISE(ABORT, 'document classifications are append-only');
                END
                """)
        }

        migrator.registerMigration("v069_add_verification_dimensions") { db in
            try db.alter(table: "structured_output_versions") { table in
                table.add(column: "verification_dimensions_json", .text)
            }
        }

        migrator.registerMigration("v070_add_authority_reviewed_proposition") { db in
            // Historical authority rows have no proposition-specific human
            // review that can be reconstructed safely. Keep them unreviewed.
            try db.alter(table: "authorities") { table in
                table.add(column: "reviewed_proposition_json", .text)
            }
        }

        migrator.registerMigration("v071_create_draft_artifact_intents") { db in
            try db.create(table: "draft_artifact_intents") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("artifact_kind", .text).notNull()
                table.column("format", .text).notNull()
                table.column("file_name", .text).notNull()
                table.column("output_sha256", .text).notNull()
                table.column("output_byte_size", .integer).notNull()
                table.column("audit_metadata_json", .text).notNull()
                table.column("audit_metadata_sha256", .text).notNull()
                table.column("motion_snapshot_request_json", .text)
                table.column("motion_snapshot_sha256", .text)
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("terminal_at", .datetime)
            }
            // Only an active operation owns a filename reservation. Terminal
            // history remains durable without poisoning future allocation.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_draft_artifact_intents_matter_file
                ON draft_artifact_intents (matter_id, file_name)
                WHERE status = 'prepared'
                """)
            try db.create(
                index: "idx_draft_artifact_intents_status_created",
                on: "draft_artifact_intents",
                columns: ["status", "created_at", "id"]
            )
        }

        migrator.registerMigration("v072_harden_corpus_review_integrity") { db in
            // Historical v064-v071 rows cannot be upgraded into exact requests:
            // neither their semantic request nor their presented text ranges can
            // be reconstructed safely. Nullable columns preserve that unknown
            // lineage instead of fabricating it during migration.
            try db.execute(sql: """
                ALTER TABLE corpus_analysis_runs
                ADD COLUMN request_schema_version INTEGER
                """)
            try db.execute(sql: """
                ALTER TABLE corpus_analysis_runs
                ADD COLUMN request_digest TEXT
                CHECK (
                    request_digest IS NULL OR (
                        typeof(request_digest) = 'text'
                        AND length(request_digest) = 64
                        AND request_digest NOT GLOB '*[^0-9a-f]*'
                    )
                )
                """)

            // SQLite requires the exact composite parent key to be unique before
            // it can enforce the slice's (partition_id, run_id) ownership FK.
            try db.create(
                index: "idx_corpus_analysis_partitions_id_run",
                on: "corpus_analysis_partitions",
                columns: ["id", "run_id"],
                unique: true
            )

            try db.execute(sql: """
                CREATE TABLE corpus_analysis_partition_slices (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL,
                    partition_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    member_key TEXT NOT NULL CHECK (length(member_key) > 0),
                    document_id TEXT NOT NULL CHECK (length(document_id) > 0),
                    part_index INTEGER NOT NULL CHECK (
                        typeof(part_index) = 'integer' AND part_index >= 0
                    ),
                    revision_id TEXT NOT NULL CHECK (length(revision_id) > 0),
                    char_start INTEGER NOT NULL CHECK (
                        typeof(char_start) = 'integer' AND char_start >= 0
                    ),
                    char_end INTEGER NOT NULL CHECK (
                        typeof(char_end) = 'integer' AND char_end > char_start
                    ),
                    revision_char_count INTEGER NOT NULL
                        CHECK (
                            typeof(revision_char_count) = 'integer'
                            AND revision_char_count >= char_end
                        ),
                    text_sha256 TEXT NOT NULL CHECK (
                        typeof(text_sha256) = 'text'
                        AND length(text_sha256) = 64
                        AND text_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    locator_json TEXT NOT NULL CHECK (
                        json_valid(locator_json) = 1
                        AND json_type(locator_json) = 'object'
                        AND COALESCE((
                            (
                                json_type(locator_json, '$.source_kind') = 'text'
                                AND length(json_extract(locator_json, '$.source_kind')) > 0
                                AND json_type(locator_json, '$.char_start') = 'integer'
                                AND json_type(locator_json, '$.char_end') = 'integer'
                                AND json_extract(locator_json, '$.char_start') = char_start
                                AND json_extract(locator_json, '$.char_end') = char_end
                                AND json_type(locator_json, '$.sourceKind') IS NULL
                                AND json_type(locator_json, '$.pageIndex') IS NULL
                                AND json_type(locator_json, '$.pageLabel') IS NULL
                                AND json_type(locator_json, '$.sheetName') IS NULL
                                AND json_type(locator_json, '$.cellRange') IS NULL
                                AND json_type(locator_json, '$.emailPartPath') IS NULL
                                AND json_type(locator_json, '$.charStart') IS NULL
                                AND json_type(locator_json, '$.charEnd') IS NULL
                                AND json_type(locator_json, '$.boundingBoxesJSON') IS NULL
                                AND json_type(locator_json, '$.partIndex') IS NULL
                                AND (
                                    json_type(locator_json, '$.part_index') IS NULL
                                    OR (
                                        json_type(locator_json, '$.part_index') = 'integer'
                                        AND json_extract(locator_json, '$.part_index') = part_index
                                    )
                                )
                            )
                            OR (
                                json_type(locator_json, '$.sourceKind') = 'text'
                                AND length(json_extract(locator_json, '$.sourceKind')) > 0
                                AND json_type(locator_json, '$.charStart') = 'integer'
                                AND json_type(locator_json, '$.charEnd') = 'integer'
                                AND json_extract(locator_json, '$.charStart') = char_start
                                AND json_extract(locator_json, '$.charEnd') = char_end
                                AND json_type(locator_json, '$.source_kind') IS NULL
                                AND json_type(locator_json, '$.page_index') IS NULL
                                AND json_type(locator_json, '$.page_label') IS NULL
                                AND json_type(locator_json, '$.sheet_name') IS NULL
                                AND json_type(locator_json, '$.cell_range') IS NULL
                                AND json_type(locator_json, '$.email_part_path') IS NULL
                                AND json_type(locator_json, '$.char_start') IS NULL
                                AND json_type(locator_json, '$.char_end') IS NULL
                                AND json_type(locator_json, '$.bounding_boxes_json') IS NULL
                                AND json_type(locator_json, '$.part_index') IS NULL
                                AND (
                                    json_type(locator_json, '$.partIndex') IS NULL
                                    OR (
                                        json_type(locator_json, '$.partIndex') = 'integer'
                                        AND json_extract(locator_json, '$.partIndex') = part_index
                                    )
                                )
                            )
                        ), 0) = 1
                    ),
                    UNIQUE (partition_id, ordinal),
                    UNIQUE (run_id, revision_id, char_start, char_end),
                    FOREIGN KEY (run_id)
                        REFERENCES corpus_analysis_runs(id) ON DELETE CASCADE,
                    FOREIGN KEY (partition_id, run_id)
                        REFERENCES corpus_analysis_partitions(id, run_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_corpus_analysis_slices_run_order",
                on: "corpus_analysis_partition_slices",
                columns: ["run_id", "partition_id", "ordinal", "id"]
            )

            // A v2 exact partition may become succeeded only through a durable,
            // terminal attempt. The trigger is deliberately scoped through its
            // owning run so chronology and every legacy v1 ledger keep their
            // established disposition behavior.
            let exactSucceededAttemptChecks = """
                SELECT CASE WHEN typeof(NEW.attempt_count) <> 'integer'
                        OR NEW.attempt_count < 1
                        OR typeof(NEW.attempt_history_json) <> 'text'
                        OR json_valid(NEW.attempt_history_json) <> 1
                    THEN RAISE(ABORT, 'exact success requires valid attempt history') END;
                SELECT CASE WHEN json_type(NEW.attempt_history_json) IS NOT 'array'
                        OR json_array_length(NEW.attempt_history_json) <> NEW.attempt_count
                        OR (
                            typeof(NEW.started_at) NOT IN ('integer', 'real')
                            AND (
                                typeof(NEW.started_at) <> 'text'
                                OR julianday(NEW.started_at) IS NULL
                            )
                        )
                        OR (
                            typeof(NEW.completed_at) NOT IN ('integer', 'real')
                            AND (
                                typeof(NEW.completed_at) <> 'text'
                                OR julianday(NEW.completed_at) IS NULL
                            )
                        )
                        OR (
                            typeof(NEW.started_at) IN ('integer', 'real')
                            AND typeof(NEW.completed_at) IN ('integer', 'real')
                            AND NEW.completed_at < NEW.started_at
                        )
                        OR (
                            typeof(NEW.started_at) = 'text'
                            AND typeof(NEW.completed_at) = 'text'
                            AND julianday(NEW.completed_at) < julianday(NEW.started_at)
                        )
                        OR (
                            (typeof(NEW.started_at) IN ('integer', 'real'))
                            <> (typeof(NEW.completed_at) IN ('integer', 'real'))
                        )
                    THEN RAISE(ABORT, 'exact success requires coherent attempt history') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.attempt_history_json) AS attempt
                        WHERE attempt.type IS NOT 'object'
                           OR json_type(attempt.value, '$.attempt_number') IS NOT 'integer'
                           OR json_extract(attempt.value, '$.attempt_number')
                                <> CAST(attempt.key AS INTEGER) + 1
                           OR json_type(attempt.value, '$.outcome') IS NOT 'text'
                           OR json_extract(attempt.value, '$.outcome')
                                NOT IN ('failed', 'cancelled', 'succeeded')
                           OR (
                               json_type(attempt.value, '$.retryable') IS NOT 'true'
                               AND json_type(attempt.value, '$.retryable') IS NOT 'false'
                           )
                           OR (
                               json_type(attempt.value, '$.started_at') IS NOT 'integer'
                               AND json_type(attempt.value, '$.started_at') IS NOT 'real'
                           )
                           OR (
                               json_type(attempt.value, '$.completed_at') IS NOT 'integer'
                               AND json_type(attempt.value, '$.completed_at') IS NOT 'real'
                           )
                           OR json_extract(attempt.value, '$.completed_at')
                                < json_extract(attempt.value, '$.started_at')
                           OR (
                               CAST(attempt.key AS INTEGER) < NEW.attempt_count - 1
                               AND json_extract(attempt.value, '$.outcome') = 'succeeded'
                           )
                           OR (
                               CAST(attempt.key AS INTEGER) = NEW.attempt_count - 1
                               AND (
                                   json_extract(attempt.value, '$.outcome') IS NOT 'succeeded'
                                   OR json_type(attempt.value, '$.retryable') IS NOT 'false'
                                   OR (
                                       json_type(attempt.value, '$.error_summary') IS NOT NULL
                                       AND json_type(attempt.value, '$.error_summary') IS NOT 'null'
                                   )
                               )
                           )
                    )
                    THEN RAISE(ABORT, 'exact success requires a terminal succeeded attempt') END;
                SELECT CASE WHEN typeof(NEW.findings_json) <> 'text'
                        OR json_valid(NEW.findings_json) <> 1
                    THEN RAISE(ABORT, 'exact success requires valid findings JSON') END;
                SELECT CASE WHEN json_type(NEW.findings_json) IS NOT 'array'
                    THEN RAISE(ABORT, 'exact success requires a findings array') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.findings_json) AS finding
                        WHERE finding.type IS NOT 'object'
                           OR json_type(finding.value, '$.id') IS NOT 'text'
                           OR length(json_extract(finding.value, '$.id')) = 0
                           OR json_type(finding.value, '$.value') IS NOT 'text'
                           OR json_type(finding.value, '$.evidence') IS NOT 'array'
                           OR (
                               json_type(finding.value, '$.contrary_evidence') IS NOT NULL
                               AND json_type(
                                   finding.value, '$.contrary_evidence'
                               ) IS NOT 'null'
                               AND json_type(
                                   finding.value, '$.contrary_evidence'
                               ) IS NOT 'array'
                           )
                           OR (
                               json_array_length(finding.value, '$.evidence')
                               + COALESCE(json_array_length(
                                   finding.value, '$.contrary_evidence'
                               ), 0)
                           ) < 1
                           OR EXISTS (
                               SELECT 1
                               FROM json_each(finding.value, '$.evidence') AS evidence
                               WHERE evidence.type IS NOT 'object'
                                  OR json_type(
                                      evidence.value, '$.document_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.document_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.revision_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.revision_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.locator_json'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.locator_json'
                                  )) = 0
                                  OR (
                                      json_type(evidence.value, '$.quote') IS NOT NULL
                                      AND json_type(evidence.value, '$.quote') IS NOT 'null'
                                      AND (
                                          json_type(evidence.value, '$.quote') IS NOT 'text'
                                          OR length(json_extract(
                                              evidence.value, '$.quote'
                                          )) = 0
                                      )
                                  )
                                  OR (
                                      (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_start'
                                          ) IS 'null'
                                      ) <> (
                                          json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS 'null'
                                      )
                                  )
                                  OR (
                                      json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT NULL
                                      AND json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT 'null'
                                      AND (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NOT 'integer'
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NOT 'integer'
                                          OR json_extract(
                                              evidence.value, '$.char_start'
                                          ) < 0
                                          OR json_extract(
                                              evidence.value, '$.char_end'
                                          ) <= json_extract(
                                              evidence.value, '$.char_start'
                                          )
                                      )
                                  )
                                  OR NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = NEW.run_id
                                        AND slice.partition_id = NEW.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                           )
                           OR EXISTS (
                               SELECT 1
                               FROM json_each(
                                   finding.value, '$.contrary_evidence'
                               ) AS evidence
                               WHERE evidence.type IS NOT 'object'
                                  OR json_type(
                                      evidence.value, '$.document_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.document_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.revision_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.revision_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.locator_json'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.locator_json'
                                  )) = 0
                                  OR (
                                      json_type(evidence.value, '$.quote') IS NOT NULL
                                      AND json_type(evidence.value, '$.quote') IS NOT 'null'
                                      AND (
                                          json_type(evidence.value, '$.quote') IS NOT 'text'
                                          OR length(json_extract(
                                              evidence.value, '$.quote'
                                          )) = 0
                                      )
                                  )
                                  OR (
                                      (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_start'
                                          ) IS 'null'
                                      ) <> (
                                          json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS 'null'
                                      )
                                  )
                                  OR (
                                      json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT NULL
                                      AND json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT 'null'
                                      AND (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NOT 'integer'
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NOT 'integer'
                                          OR json_extract(
                                              evidence.value, '$.char_start'
                                          ) < 0
                                          OR json_extract(
                                              evidence.value, '$.char_end'
                                          ) <= json_extract(
                                              evidence.value, '$.char_start'
                                          )
                                      )
                                  )
                                  OR NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = NEW.run_id
                                        AND slice.partition_id = NEW.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                           )
                    )
                    THEN RAISE(ABORT, 'exact success findings are not decodable') END;
                """
            let exactSucceededAttemptScope = """
                NEW.disposition = 'succeeded'
                AND EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    WHERE run.id = NEW.run_id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_success_insert_guard
                BEFORE INSERT ON corpus_analysis_partitions
                WHEN \(exactSucceededAttemptScope)
                BEGIN
                    \(exactSucceededAttemptChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_success_update_guard
                BEFORE UPDATE ON corpus_analysis_partitions
                WHEN \(exactSucceededAttemptScope)
                BEGIN
                    \(exactSucceededAttemptChecks)
                END
                """)

            // Preserve v064's universal corpus-complete baseline for every task,
            // and apply it to direct inserts as well as lifecycle updates.
            let corpusCompleteBaselineChecks = """
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'corpus_complete requires planned partitions') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    )
                    THEN RAISE(ABORT, 'corpus_complete requires all partitions succeeded') END;
                SELECT CASE WHEN COALESCE(
                        json_extract(NEW.coverage_json, '$.excluded_members_disclosed'), 0
                    ) <> 1
                    THEN RAISE(ABORT, 'corpus_complete requires disclosed exclusions') END;
                """
            try db.execute(sql: "DROP TRIGGER IF EXISTS corpus_analysis_complete_guard")
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_guard
                BEFORE UPDATE OF status, assurance_state, coverage_json
                ON corpus_analysis_runs
                WHEN NEW.status = 'persisted'
                  AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    \(corpusCompleteBaselineChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.status = 'persisted'
                  AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    \(corpusCompleteBaselineChecks)
                END
                """)

            // Case File Review's two export-eligible assurance states require a
            // complete v2 exact-slice ledger. This guard is intentionally scoped
            // by task kind, never by request version, so chronology remains on
            // its compatible v1 revision-ledger contract.
            let exhaustiveExportChecks = """
                SELECT CASE WHEN NEW.request_schema_version IS NOT 2
                    THEN RAISE(ABORT, 'exhaustive export requires v2 request lineage') END;
                SELECT CASE WHEN typeof(NEW.request_digest) <> 'text'
                        OR length(NEW.request_digest) <> 64
                        OR NEW.request_digest GLOB '*[^0-9a-f]*'
                    THEN RAISE(ABORT, 'exhaustive export requires a valid request digest') END;
                SELECT CASE WHEN NEW.partition_strategy_version IS NOT 2
                        OR NEW.partition_strategy NOT GLOB 'exact_revision_slice*'
                    THEN RAISE(ABORT, 'exhaustive export requires the exact-slice strategy') END;
                SELECT CASE WHEN typeof(NEW.corpus_snapshot_json) <> 'text'
                        OR json_valid(NEW.corpus_snapshot_json) <> 1
                    THEN RAISE(ABORT, 'exhaustive export requires a valid frozen snapshot') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        WHERE json_type(NEW.corpus_snapshot_json) IS NOT 'object'
                           OR json_type(NEW.corpus_snapshot_json, '$.schema_version') IS NOT 'integer'
                           OR json_extract(NEW.corpus_snapshot_json, '$.schema_version') <= 0
                           OR json_type(NEW.corpus_snapshot_json, '$.members') IS NOT 'array'
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires a typed frozen snapshot') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE member.type IS NOT 'object'
                           OR json_type(member.value, '$.member_key') IS NOT 'text'
                           OR length(json_extract(member.value, '$.member_key')) = 0
                           OR json_type(member.value, '$.display_name') IS NOT 'text'
                           OR length(json_extract(member.value, '$.display_name')) = 0
                           OR json_type(member.value, '$.disposition') IS NOT 'text'
                           OR json_extract(member.value, '$.disposition') NOT IN ('eligible', 'excluded')
                           OR json_type(member.value, '$.revision_ids') IS NOT 'array'
                           OR (
                               json_type(member.value, '$.document_id') IS NOT NULL
                               AND json_type(member.value, '$.document_id') IS NOT 'null'
                               AND (
                                   json_type(member.value, '$.document_id') IS NOT 'text'
                                   OR length(json_extract(member.value, '$.document_id')) = 0
                               )
                           )
                           OR (
                               json_type(member.value, '$.index_state') IS NOT NULL
                               AND json_type(member.value, '$.index_state') IS NOT 'null'
                               AND json_type(member.value, '$.index_state') IS NOT 'text'
                           )
                           OR (
                               json_type(member.value, '$.reason') IS NOT NULL
                               AND json_type(member.value, '$.reason') IS NOT 'null'
                               AND json_type(member.value, '$.reason') IS NOT 'text'
                           )
                           OR (
                               json_extract(member.value, '$.disposition') = 'eligible'
                               AND (
                                   json_type(member.value, '$.document_id') IS NOT 'text'
                                   OR length(json_extract(member.value, '$.document_id')) = 0
                                   OR json_array_length(member.value, '$.revision_ids') = 0
                               )
                          )
                    )
                    THEN RAISE(ABORT, 'eligible snapshot member is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        JOIN json_each(member.value, '$.revision_ids') AS revision
                        WHERE revision.type IS NOT 'text' OR length(revision.value) = 0
                    )
                    THEN RAISE(ABORT, 'snapshot revision identity is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        GROUP BY json_extract(member.value, '$.member_key')
                        HAVING COUNT(*) > 1
                    )
                    THEN RAISE(ABORT, 'snapshot member identities are not unique') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE EXISTS (
                            SELECT 1
                            FROM json_each(member.value, '$.revision_ids') AS revision
                            GROUP BY revision.value
                            HAVING COUNT(*) > 1
                        )
                    )
                    THEN RAISE(ABORT, 'snapshot revision identities are not unique') END;
                SELECT CASE WHEN typeof(NEW.coverage_json) <> 'text'
                        OR json_valid(NEW.coverage_json) <> 1
                    THEN RAISE(ABORT, 'exhaustive export requires valid coverage') END;
                SELECT CASE WHEN json_type(NEW.coverage_json) IS NOT 'object'
                        OR json_type(NEW.coverage_json, '$.schema_version') IS NOT 'integer'
                        OR json_extract(NEW.coverage_json, '$.schema_version') <= 0
                        OR json_type(NEW.coverage_json, '$.snapshot_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.eligible_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_members_disclosed') IS NOT 'true'
                        OR json_type(NEW.coverage_json, '$.partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.pending_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.succeeded_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.failed_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.cancelled_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.terminal_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.balance_error_count') IS NOT 'integer'
                    THEN RAISE(ABORT, 'exhaustive export requires complete typed coverage') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires all partitions succeeded') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              typeof(partition.attempt_count) <> 'integer'
                              OR partition.attempt_count < 1
                              OR typeof(partition.attempt_history_json) <> 'text'
                              OR json_valid(partition.attempt_history_json) <> 1
                              OR (
                                  typeof(partition.started_at) NOT IN ('integer', 'real')
                                  AND (
                                      typeof(partition.started_at) <> 'text'
                                      OR julianday(partition.started_at) IS NULL
                                  )
                              )
                              OR (
                                  typeof(partition.completed_at) NOT IN ('integer', 'real')
                                  AND (
                                      typeof(partition.completed_at) <> 'text'
                                      OR julianday(partition.completed_at) IS NULL
                                  )
                              )
                              OR (
                                  typeof(partition.started_at) IN ('integer', 'real')
                                  AND typeof(partition.completed_at) IN ('integer', 'real')
                                  AND partition.completed_at < partition.started_at
                              )
                              OR (
                                  typeof(partition.started_at) = 'text'
                                  AND typeof(partition.completed_at) = 'text'
                                  AND julianday(partition.completed_at)
                                        < julianday(partition.started_at)
                              )
                              OR (
                                  (typeof(partition.started_at) IN ('integer', 'real'))
                                  <> (typeof(partition.completed_at) IN ('integer', 'real'))
                              )
                              OR typeof(partition.findings_json) <> 'text'
                              OR json_valid(partition.findings_json) <> 1
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires valid checkpoints') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              json_type(partition.attempt_history_json) IS NOT 'array'
                              OR json_array_length(partition.attempt_history_json)
                                    <> partition.attempt_count
                              OR json_type(partition.findings_json) IS NOT 'array'
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(partition.attempt_history_json) AS attempt
                                  WHERE attempt.type IS NOT 'object'
                                     OR json_type(
                                         attempt.value, '$.attempt_number'
                                     ) IS NOT 'integer'
                                     OR json_extract(
                                         attempt.value, '$.attempt_number'
                                     ) <> CAST(attempt.key AS INTEGER) + 1
                                     OR json_type(attempt.value, '$.outcome') IS NOT 'text'
                                     OR json_extract(attempt.value, '$.outcome')
                                          NOT IN ('failed', 'cancelled', 'succeeded')
                                     OR (
                                         json_type(
                                             attempt.value, '$.retryable'
                                         ) IS NOT 'true'
                                         AND json_type(
                                             attempt.value, '$.retryable'
                                         ) IS NOT 'false'
                                     )
                                     OR (
                                         json_type(
                                             attempt.value, '$.started_at'
                                         ) IS NOT 'integer'
                                         AND json_type(
                                             attempt.value, '$.started_at'
                                         ) IS NOT 'real'
                                     )
                                     OR (
                                         json_type(
                                             attempt.value, '$.completed_at'
                                         ) IS NOT 'integer'
                                         AND json_type(
                                             attempt.value, '$.completed_at'
                                         ) IS NOT 'real'
                                     )
                                     OR json_extract(attempt.value, '$.completed_at')
                                          < json_extract(attempt.value, '$.started_at')
                                     OR (
                                         CAST(attempt.key AS INTEGER)
                                            < partition.attempt_count - 1
                                         AND json_extract(
                                             attempt.value, '$.outcome'
                                         ) = 'succeeded'
                                     )
                                     OR (
                                         CAST(attempt.key AS INTEGER)
                                            = partition.attempt_count - 1
                                         AND (
                                             json_extract(
                                                 attempt.value, '$.outcome'
                                             ) IS NOT 'succeeded'
                                             OR json_type(
                                                 attempt.value, '$.retryable'
                                             ) IS NOT 'false'
                                             OR (
                                                 json_type(
                                                     attempt.value, '$.error_summary'
                                                 ) IS NOT NULL
                                                 AND json_type(
                                                     attempt.value, '$.error_summary'
                                                 ) IS NOT 'null'
                                             )
                                         )
                                     )
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(partition.findings_json) AS finding
                                  WHERE finding.type IS NOT 'object'
                                     OR json_type(finding.value, '$.id') IS NOT 'text'
                                     OR length(json_extract(finding.value, '$.id')) = 0
                                     OR json_type(finding.value, '$.value') IS NOT 'text'
                                     OR json_type(
                                         finding.value, '$.evidence'
                                     ) IS NOT 'array'
                                     OR (
                                         json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT NULL
                                         AND json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT 'null'
                                         AND json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT 'array'
                                     )
                                     OR EXISTS (
                                         SELECT 1
                                         FROM json_each(
                                             finding.value, '$.evidence'
                                         ) AS evidence
                                         WHERE evidence.type IS NOT 'object'
                                            OR json_type(
                                                evidence.value, '$.document_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.document_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.revision_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.revision_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.locator_json'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.locator_json'
                                            )) = 0
                                     )
                                     OR EXISTS (
                                         SELECT 1
                                         FROM json_each(
                                             finding.value, '$.contrary_evidence'
                                         ) AS evidence
                                         WHERE evidence.type IS NOT 'object'
                                            OR json_type(
                                                evidence.value, '$.document_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.document_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.revision_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.revision_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.locator_json'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.locator_json'
                                            )) = 0
                                     )
                              )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires decodable succeeded proof') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.findings_json) AS finding
                        WHERE partition.run_id = NEW.id
                          AND (
                              (
                                  json_array_length(finding.value, '$.evidence')
                                  + COALESCE(json_array_length(
                                      finding.value, '$.contrary_evidence'
                                  ), 0)
                              ) < 1
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(
                                      finding.value, '$.evidence'
                                  ) AS evidence
                                  WHERE NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = partition.run_id
                                        AND slice.partition_id = partition.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(
                                      finding.value, '$.contrary_evidence'
                                  ) AS evidence
                                  WHERE NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = partition.run_id
                                        AND slice.partition_id = partition.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                              )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export evidence is outside exact slices') END;
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires planned partitions') END;
                SELECT CASE WHEN NEW.structured_output_version_id IS NOT NULL
                        AND (
                            NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.id IS NOT NEW.id
                                  AND other_run.structured_output_version_id
                                        = NEW.structured_output_version_id
                            )
                        )
                    THEN RAISE(ABORT, 'exhaustive export attachment is incompatible') END;
                SELECT CASE WHEN json_extract(
                        NEW.coverage_json, '$.snapshot_member_count'
                    ) <> json_array_length(NEW.corpus_snapshot_json, '$.members')
                    OR json_extract(NEW.coverage_json, '$.eligible_member_count') <> (
                        SELECT COUNT(*)
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE json_extract(member.value, '$.disposition') = 'eligible'
                    )
                    OR json_extract(NEW.coverage_json, '$.excluded_member_count') <> (
                        SELECT COUNT(*)
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE json_extract(member.value, '$.disposition') = 'excluded'
                    )
                    THEN RAISE(ABORT, 'exhaustive export coverage member counts mismatch') END;
                SELECT CASE WHEN json_extract(NEW.coverage_json, '$.partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    OR json_extract(NEW.coverage_json, '$.pending_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'pending'
                    )
                    OR json_extract(NEW.coverage_json, '$.succeeded_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'succeeded'
                    )
                    OR json_extract(NEW.coverage_json, '$.failed_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'failed'
                    )
                    OR json_extract(NEW.coverage_json, '$.cancelled_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'cancelled'
                    )
                    OR json_extract(NEW.coverage_json, '$.excluded_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'excluded'
                    )
                    OR json_extract(NEW.coverage_json, '$.terminal_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition IN (
                            'succeeded', 'failed', 'cancelled', 'excluded'
                        )
                    )
                    OR json_extract(NEW.coverage_json, '$.balance_error_count') <> 0
                    THEN RAISE(ABORT, 'exhaustive export coverage partition counts mismatch') END;
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partition_slices WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires exact slices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1 FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.partition_id = partition.id
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires slices for every partition') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              typeof(partition.input_revision_ids_json) <> 'text'
                              OR json_valid(partition.input_revision_ids_json) <> 1
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision ledger is invalid JSON') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              json_type(partition.input_revision_ids_json) IS NOT 'array'
                              OR json_array_length(partition.input_revision_ids_json) = 0
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision ledger must be a nonempty array') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.input_revision_ids_json) AS input_revision
                        WHERE partition.run_id = NEW.id
                          AND (
                              input_revision.type IS NOT 'text'
                              OR length(input_revision.value) = 0
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision identity is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND EXISTS (
                              SELECT 1
                              FROM json_each(partition.input_revision_ids_json) AS input_revision
                              GROUP BY input_revision.value
                              HAVING COUNT(*) > 1
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision identities are not unique') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS slice
                        JOIN corpus_analysis_partitions AS partition
                          ON partition.id = slice.partition_id
                         AND partition.run_id = slice.run_id
                        WHERE slice.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM json_each(partition.input_revision_ids_json) AS input_revision
                              WHERE input_revision.value = slice.revision_id
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export slice is outside its partition revisions') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.input_revision_ids_json) AS input_revision
                        WHERE partition.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.partition_id = partition.id
                                AND slice.revision_id = input_revision.value
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision is missing exact slices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS slice
                        WHERE slice.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                              WHERE json_extract(member.value, '$.disposition') = 'eligible'
                                AND json_extract(member.value, '$.member_key') = slice.member_key
                                AND json_extract(member.value, '$.document_id') = slice.document_id
                                AND EXISTS (
                                    SELECT 1
                                    FROM json_each(member.value, '$.revision_ids') AS revision
                                    WHERE revision.value = slice.revision_id
                                )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export contains an extraneous slice identity') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        JOIN json_each(member.value, '$.revision_ids') AS revision
                        WHERE json_extract(member.value, '$.disposition') = 'eligible'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.member_key = json_extract(member.value, '$.member_key')
                                AND slice.document_id = json_extract(member.value, '$.document_id')
                                AND slice.revision_id = revision.value
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export is missing an eligible revision') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY partition_id
                        HAVING MIN(ordinal) <> 0 OR MAX(ordinal) <> COUNT(*) - 1
                    )
                    THEN RAISE(ABORT, 'exhaustive export slice ordinals are not contiguous') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY member_key, document_id, revision_id
                        HAVING MIN(part_index) <> MAX(part_index)
                    )
                    THEN RAISE(ABORT, 'frozen revision selects multiple part indices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY member_key, document_id, part_index, revision_id
                        HAVING MIN(revision_char_count) <> MAX(revision_char_count)
                            OR MIN(char_start) <> 0
                            OR MAX(char_end) <> MAX(revision_char_count)
                            OR SUM(char_end - char_start) <> MAX(revision_char_count)
                    )
                    THEN RAISE(ABORT, 'exhaustive export exact ranges are incomplete') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS left_slice
                        JOIN corpus_analysis_partition_slices AS right_slice
                          ON right_slice.run_id = left_slice.run_id
                         AND right_slice.member_key = left_slice.member_key
                         AND right_slice.document_id = left_slice.document_id
                         AND right_slice.part_index = left_slice.part_index
                         AND right_slice.revision_id = left_slice.revision_id
                         AND right_slice.id > left_slice.id
                         AND left_slice.char_start < right_slice.char_end
                         AND right_slice.char_start < left_slice.char_end
                        WHERE left_slice.run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export exact ranges overlap') END;
                """
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exhaustive_export_update_guard
                BEFORE UPDATE OF task_kind, status, assurance_state, coverage_json,
                    request_schema_version, request_digest, corpus_snapshot_json,
                    partition_strategy, partition_strategy_version
                ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.status = 'persisted'
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                BEGIN
                    \(exhaustiveExportChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exhaustive_export_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.status = 'persisted'
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                BEGIN
                    \(exhaustiveExportChecks)
                END
                """)

            // The request digest is meaningful only while every value it binds
            // remains unchanged. A finalized v2 claim must be explicitly
            // downgraded before its frozen proof root can be replaced.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_final_proof_root_update_guard
                BEFORE UPDATE OF id, run_key, matter_id, task_kind, scope_json,
                    corpus_snapshot_json, partition_strategy,
                    partition_strategy_version, model_lineage_json,
                    request_schema_version, request_digest, created_at
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND (
                      NEW.id IS NOT OLD.id
                      OR NEW.run_key IS NOT OLD.run_key
                      OR NEW.matter_id IS NOT OLD.matter_id
                      OR NEW.task_kind IS NOT OLD.task_kind
                      OR NEW.scope_json IS NOT OLD.scope_json
                      OR NEW.corpus_snapshot_json IS NOT OLD.corpus_snapshot_json
                      OR NEW.partition_strategy IS NOT OLD.partition_strategy
                      OR NEW.partition_strategy_version IS NOT OLD.partition_strategy_version
                      OR NEW.model_lineage_json IS NOT OLD.model_lineage_json
                      OR NEW.request_schema_version IS NOT OLD.request_schema_version
                      OR NEW.request_digest IS NOT OLD.request_digest
                      OR NEW.created_at IS NOT OLD.created_at
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'finalized exhaustive proof root is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_final_claim_state_update_guard
                BEFORE UPDATE OF status, assurance_state
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND NEW.status IS NOT 'persisted'
                BEGIN
                    SELECT RAISE(ABORT, 'finalized exhaustive claim must be downgraded explicitly');
                END
                """)

            // A structured output version has one proof owner regardless of
            // whether a second candidate is exact-v2 or a legacy task. This
            // closes the inverse ordering hole where an exact run attached
            // first and a chronology/v1 row borrowed the same version later.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_output_version_owner_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS owner
                      WHERE owner.structured_output_version_id
                            = NEW.structured_output_version_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'structured output version already has a run owner');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_output_version_owner_update_guard
                BEFORE UPDATE OF structured_output_version_id ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT NULL
                  AND NEW.structured_output_version_id
                        IS NOT OLD.structured_output_version_id
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS owner
                      WHERE owner.id IS NOT NEW.id
                        AND owner.structured_output_version_id
                            = NEW.structured_output_version_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'structured output version already has a run owner');
                END
                """)

            // Exact-run output attachment is a one-time binding. A finalized
            // run is normally persisted before its output is generated, so the
            // legitimate NULL-to-compatible transition remains available.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_attachment_guard
                BEFORE UPDATE OF structured_output_version_id
                ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT OLD.structured_output_version_id
                  AND (
                      (
                          OLD.task_kind = 'exhaustive_list'
                          AND OLD.request_schema_version = 2
                          AND OLD.partition_strategy_version = 2
                          AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                      )
                      OR (
                          NEW.task_kind = 'exhaustive_list'
                          AND NEW.request_schema_version = 2
                          AND NEW.partition_strategy_version = 2
                          AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                      )
                  )
                BEGIN
                    SELECT CASE WHEN OLD.structured_output_version_id IS NOT NULL
                            AND EXISTS (
                                SELECT 1
                                FROM matters
                                WHERE id = OLD.matter_id
                            )
                        THEN RAISE(ABORT, 'exact output attachment is immutable') END;
                    SELECT CASE WHEN NEW.structured_output_version_id IS NOT NULL
                            AND (
                                NEW.status IS NOT 'persisted'
                                OR NOT EXISTS (
                                    SELECT 1
                                    FROM structured_output_versions AS version
                                    JOIN structured_outputs AS output
                                      ON output.id = version.structured_output_id
                                    WHERE version.id = NEW.structured_output_version_id
                                      AND version.assurance_state = NEW.assurance_state
                                      AND output.matter_id = NEW.matter_id
                                      AND output.output_type = 'document_exhaustive_list'
                                      AND output.deleted_at IS NULL
                                )
                                OR EXISTS (
                                    SELECT 1
                                    FROM corpus_analysis_runs AS other_run
                                    WHERE other_run.id IS NOT NEW.id
                                      AND other_run.structured_output_version_id
                                            = NEW.structured_output_version_id
                                )
                            )
                        THEN RAISE(ABORT, 'exact output attachment is incompatible') END;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_attachment_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.request_schema_version = 2
                  AND NEW.partition_strategy_version = 2
                  AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                  AND NEW.structured_output_version_id IS NOT NULL
                BEGIN
                    SELECT CASE WHEN NEW.status IS NOT 'persisted'
                            OR NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.structured_output_version_id
                                    = NEW.structured_output_version_id
                            )
                        THEN RAISE(ABORT, 'exact output attachment is incompatible') END;
                END
                """)

            // Attachment checks must also run when a pre-attached non-exact row
            // is reclassified into the v2 exact contract. Otherwise a chronology
            // row could borrow another run's version before changing identity.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_reclassification_guard
                BEFORE UPDATE OF task_kind, request_schema_version,
                    partition_strategy, partition_strategy_version, matter_id
                ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.request_schema_version = 2
                  AND NEW.partition_strategy_version = 2
                  AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                  AND NEW.structured_output_version_id IS NOT NULL
                  AND (
                      NEW.task_kind IS NOT OLD.task_kind
                      OR NEW.request_schema_version IS NOT OLD.request_schema_version
                      OR NEW.partition_strategy IS NOT OLD.partition_strategy
                      OR NEW.partition_strategy_version
                            IS NOT OLD.partition_strategy_version
                      OR NEW.matter_id IS NOT OLD.matter_id
                  )
                BEGIN
                    SELECT CASE WHEN NEW.status IS NOT 'persisted'
                            OR NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.id IS NOT NEW.id
                                  AND other_run.structured_output_version_id
                                        = NEW.structured_output_version_id
                            )
                        THEN RAISE(ABORT, 'exact output reclassification is incompatible') END;
                END
                """)

            // Once a source set is attached to an exact proof version, its
            // identity and frozen corpus lineage are append-only. The atomic
            // publisher performs its pending-to-attached transition before the
            // run is linked, so that legitimate transition remains available.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_source_set_update_guard
                BEFORE UPDATE ON document_source_sets
                WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id
                                = OLD.structured_output_version_id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id
                                = NEW.structured_output_version_id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact source set is append-only');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_source_set_delete_guard
                BEFORE DELETE ON document_source_sets
                WHEN EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    JOIN matters AS matter ON matter.id = run.matter_id
                    WHERE run.structured_output_version_id
                            = OLD.structured_output_version_id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact source set cannot be deleted');
                END
                """)

            // A linked exact version is an append-only projection of its proof
            // root. Deletion and semantic rewrites remain available only after
            // that run is deliberately removed, or as part of whole-matter
            // deletion after the owning matter row has left the parent table.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_version_delete_guard
                BEFORE DELETE ON structured_output_versions
                WHEN EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    JOIN matters AS matter ON matter.id = run.matter_id
                    WHERE run.structured_output_version_id = OLD.id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output version cannot be deleted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_version_identity_guard
                BEFORE UPDATE OF id, structured_output_id, version_index,
                    parent_version_id, content_markdown, required_sections_json,
                    present_sections_json, missing_sections_json, repair_reason,
                    generation_session_id, verification_status,
                    verification_version, verification_json,
                    verification_dimensions_json, verified_at,
                    prompt_builder_version, created_at
                ON structured_output_versions
                WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id = OLD.id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                  AND (
                      NEW.id IS NOT OLD.id
                      OR NEW.structured_output_id IS NOT OLD.structured_output_id
                      OR NEW.version_index IS NOT OLD.version_index
                      OR NEW.parent_version_id IS NOT OLD.parent_version_id
                      OR NEW.content_markdown IS NOT OLD.content_markdown
                      OR NEW.required_sections_json IS NOT OLD.required_sections_json
                      OR NEW.present_sections_json IS NOT OLD.present_sections_json
                      OR NEW.missing_sections_json IS NOT OLD.missing_sections_json
                      OR NEW.repair_reason IS NOT OLD.repair_reason
                      OR NEW.generation_session_id IS NOT OLD.generation_session_id
                      OR NEW.verification_status IS NOT OLD.verification_status
                      OR NEW.verification_version IS NOT OLD.verification_version
                      OR NEW.verification_json IS NOT OLD.verification_json
                      OR NEW.verification_dimensions_json
                            IS NOT OLD.verification_dimensions_json
                      OR NEW.verified_at IS NOT OLD.verified_at
                      OR NEW.prompt_builder_version IS NOT OLD.prompt_builder_version
                      OR NEW.created_at IS NOT OLD.created_at
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output version is append-only');
                END
                """)

            // A strong assurance value must continue to match the one exact run
            // that earned it. A downgrade remains legal, but it is normalized to
            // stale across version, run, and active parent in one transaction.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_assurance_guard
                BEFORE UPDATE OF assurance_state ON structured_output_versions
                WHEN NEW.assurance_state IS NOT OLD.assurance_state
                  AND NEW.assurance_state IN (
                      'corpus_complete', 'proposition_supported'
                  )
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM corpus_analysis_runs AS run
                          WHERE run.structured_output_version_id = OLD.id
                            AND run.task_kind = 'exhaustive_list'
                            AND run.request_schema_version = 2
                            AND run.partition_strategy_version = 2
                            AND run.partition_strategy GLOB 'exact_revision_slice*'
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM structured_outputs AS output
                          JOIN structured_output_versions AS governed_version
                            ON governed_version.structured_output_id = output.id
                          JOIN corpus_analysis_runs AS governed_run
                            ON governed_run.structured_output_version_id
                                = governed_version.id
                          WHERE output.active_version_id = OLD.id
                            AND output.output_type = 'document_exhaustive_list'
                            AND governed_run.task_kind = 'exhaustive_list'
                            AND governed_run.request_schema_version = 2
                            AND governed_run.partition_strategy_version = 2
                            AND governed_run.partition_strategy
                                GLOB 'exact_revision_slice*'
                      )
                  )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM corpus_analysis_runs AS run
                            WHERE run.structured_output_version_id = OLD.id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = NEW.assurance_state
                        ) <> 1
                        THEN RAISE(ABORT, 'linked exact output assurance must match its proof') END;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_assurance_downgrade_stale
                AFTER UPDATE OF assurance_state ON structured_output_versions
                WHEN OLD.assurance_state IN (
                        'corpus_complete', 'proposition_supported'
                    )
                  AND (
                      NEW.assurance_state IS NULL
                      OR NEW.assurance_state NOT IN (
                          'corpus_complete', 'proposition_supported'
                      )
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS run
                      WHERE run.structured_output_version_id = OLD.id
                        AND run.task_kind = 'exhaustive_list'
                        AND run.request_schema_version = 2
                        AND run.partition_strategy_version = 2
                        AND run.partition_strategy GLOB 'exact_revision_slice*'
                        AND run.status = 'persisted'
                        AND run.assurance_state = OLD.assurance_state
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_output_downgraded'
                    WHERE id = OLD.id;
                    UPDATE corpus_analysis_runs
                    SET assurance_state = 'stale'
                    WHERE structured_output_version_id = OLD.id
                      AND task_kind = 'exhaustive_list'
                      AND request_schema_version = 2
                      AND partition_strategy_version = 2
                      AND partition_strategy GLOB 'exact_revision_slice*'
                      AND status = 'persisted'
                      AND assurance_state = OLD.assurance_state;
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.id;
                END
                """)

            // The parent owns the matter/type identity exposed to export. Once
            // any version is exact-proof-linked, those two semantic coordinates
            // cannot be rewritten around the durable run.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_parent_identity_guard
                BEFORE UPDATE OF id, matter_id, output_type
                ON structured_outputs
                WHEN (
                        NEW.id IS NOT OLD.id
                        OR NEW.matter_id IS NOT OLD.matter_id
                        OR NEW.output_type IS NOT OLD.output_type
                    )
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS version
                      JOIN corpus_analysis_runs AS run
                        ON run.structured_output_version_id = version.id
                      WHERE version.structured_output_id = OLD.id
                        AND run.task_kind = 'exhaustive_list'
                        AND run.request_schema_version = 2
                        AND run.partition_strategy_version = 2
                        AND run.partition_strategy GLOB 'exact_revision_slice*'
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output parent identity is immutable');
                END
                """)

            // Draft exhaustive outputs may exist before their proof. After an
            // output has entered the exact-proof graph, however, selecting a new
            // export-eligible active version requires that version's own single,
            // same-matter persisted exact proof.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_active_version_guard
                BEFORE UPDATE OF active_version_id ON structured_outputs
                WHEN NEW.output_type = 'document_exhaustive_list'
                  AND NEW.active_version_id IS NOT NULL
                  AND NEW.active_version_id IS NOT OLD.active_version_id
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS candidate
                      WHERE candidate.id = NEW.active_version_id
                        AND candidate.assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS prior_version
                      JOIN corpus_analysis_runs AS prior_run
                        ON prior_run.structured_output_version_id = prior_version.id
                      WHERE prior_version.structured_output_id = OLD.id
                        AND prior_run.task_kind = 'exhaustive_list'
                        AND prior_run.request_schema_version = 2
                        AND prior_run.partition_strategy_version = 2
                        AND prior_run.partition_strategy GLOB 'exact_revision_slice*'
                  )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM structured_output_versions AS version
                            JOIN corpus_analysis_runs AS run
                              ON run.structured_output_version_id = version.id
                            WHERE version.id = NEW.active_version_id
                              AND version.structured_output_id = NEW.id
                              AND version.assurance_state IN (
                                  'corpus_complete', 'proposition_supported'
                              )
                              AND run.matter_id = NEW.matter_id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy
                                    GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = version.assurance_state
                        ) <> 1
                        THEN RAISE(ABORT, 'active exhaustive version requires one exact proof') END;
                END
                """)

            // Rendering happens before the durable export/audit transaction.
            // Revalidate the exact proof at document_exports insertion time so
            // a revoked run or active-version switch cannot be recorded as a
            // successful export after the file has been installed.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_export_completion_guard
                BEFORE INSERT ON document_exports
                WHEN EXISTS (
                        SELECT 1
                        FROM structured_outputs AS output
                        WHERE output.id = NEW.structured_output_id
                          AND output.output_type = 'document_exhaustive_list'
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM structured_output_versions AS version
                        JOIN structured_outputs AS output
                          ON output.id = version.structured_output_id
                        WHERE version.id = NEW.structured_output_version_id
                          AND output.output_type = 'document_exhaustive_list'
                    )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM structured_outputs AS output
                            JOIN structured_output_versions AS version
                              ON version.id = NEW.structured_output_version_id
                             AND version.structured_output_id = output.id
                            JOIN corpus_analysis_runs AS run
                              ON run.structured_output_version_id = version.id
                            WHERE output.id = NEW.structured_output_id
                              AND output.matter_id = NEW.matter_id
                              AND output.output_type = 'document_exhaustive_list'
                              AND output.deleted_at IS NULL
                              AND output.active_version_id = version.id
                              AND version.verification_status = 'all_supported'
                              AND version.assurance_state IN (
                                  'corpus_complete', 'proposition_supported'
                              )
                              AND run.matter_id = NEW.matter_id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy
                                    GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = version.assurance_state
                              AND (
                                  SELECT COUNT(*)
                                  FROM document_source_sets AS source_set
                                  WHERE source_set.structured_output_version_id
                                        = version.id
                                    AND source_set.matter_id = NEW.matter_id
                                    AND source_set.status = 'attached'
                                    AND source_set.mode = 'exhaustive'
                                    AND typeof(source_set.corpus_snapshot_hash) = 'text'
                                    AND length(source_set.corpus_snapshot_hash) = 64
                                    AND source_set.corpus_snapshot_hash
                                        NOT GLOB '*[^0-9a-f]*'
                              ) = 1
                        ) <> 1
                        THEN RAISE(ABORT, 'exhaustive export proof changed before completion') END;
                END
                """)

            // The linked output is the public/exportable projection of this
            // proof root. If the run is downgraded or removed, invalidate that
            // projection in the same statement transaction before its ledger
            // can become mutable or cascade away.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_linked_export_downgrade_stale
                AFTER UPDATE OF status, assurance_state
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.partition_strategy_version = 2
                  AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND (
                      NEW.status IS NOT 'persisted'
                      OR NEW.assurance_state IS NULL
                      OR NEW.assurance_state NOT IN (
                          'corpus_complete', 'proposition_supported'
                      )
                  )
                  AND OLD.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions
                      WHERE id = OLD.structured_output_version_id
                        AND assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_run_downgraded'
                    WHERE id = OLD.structured_output_version_id
                      AND assurance_state IN (
                          'corpus_complete', 'proposition_supported'
                      );
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.structured_output_version_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_linked_export_delete_stale
                AFTER DELETE ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.partition_strategy_version = 2
                  AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND OLD.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions
                      WHERE id = OLD.structured_output_version_id
                        AND assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_run_deleted'
                    WHERE id = OLD.structured_output_version_id
                      AND assurance_state IN (
                          'corpus_complete', 'proposition_supported'
                      );
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.structured_output_version_id;
                END
                """)

            // Once an exhaustive claim is export-eligible, its proof ledger is
            // immutable until the claim itself is revoked or downgraded.
            for (name, table) in [
                ("partition", "corpus_analysis_partitions"),
                ("slice", "corpus_analysis_partition_slices"),
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_insert_guard
                    BEFORE INSERT ON \(table)
                    WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_runs
                        WHERE id = NEW.run_id
                          AND task_kind = 'exhaustive_list'
                          AND status = 'persisted'
                          AND assurance_state IN ('corpus_complete', 'proposition_supported')
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_update_guard
                    BEFORE UPDATE ON \(table)
                    WHEN EXISTS (
                            SELECT 1 FROM corpus_analysis_runs
                            WHERE id = OLD.run_id
                              AND task_kind = 'exhaustive_list'
                              AND status = 'persisted'
                              AND assurance_state IN ('corpus_complete', 'proposition_supported')
                        )
                        OR EXISTS (
                            SELECT 1 FROM corpus_analysis_runs
                            WHERE id = NEW.run_id
                              AND task_kind = 'exhaustive_list'
                              AND status = 'persisted'
                              AND assurance_state IN ('corpus_complete', 'proposition_supported')
                        )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_delete_guard
                    BEFORE DELETE ON \(table)
                    WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_runs
                        WHERE id = OLD.run_id
                          AND task_kind = 'exhaustive_list'
                          AND status = 'persisted'
                          AND assurance_state IN ('corpus_complete', 'proposition_supported')
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
            }

            // Strong claims created before v072 lack reconstructible requests and
            // exact slice ledgers. Revoke publication eligibility narrowly for
            // exhaustive-list runs while preserving their historical content,
            // reconciliation, attempts, partitions, and audit records.
            let staleReason = "legacy_corpus_trust_upgrade_requires_v2_regeneration"
            try db.execute(
                sql: """
                    UPDATE structured_output_versions
                    SET assurance_state = ?, stale_reason = ?
                    WHERE assurance_state IN (?, ?)
                      AND id IN (
                        SELECT structured_output_version_id
                        FROM corpus_analysis_runs
                        WHERE task_kind = ?
                          AND request_schema_version IS NULL
                          AND structured_output_version_id IS NOT NULL
                    )
                    """,
                arguments: [
                    OutputAssuranceState.stale.rawValue,
                    staleReason,
                    OutputAssuranceState.corpusComplete.rawValue,
                    OutputAssuranceState.propositionSupported.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE structured_outputs
                    SET status = ?
                    WHERE active_version_id IN (
                        SELECT version.id
                        FROM structured_output_versions AS version
                        JOIN corpus_analysis_runs AS run
                          ON run.structured_output_version_id = version.id
                        WHERE run.task_kind = ?
                          AND run.request_schema_version IS NULL
                          AND version.assurance_state = ?
                          AND version.stale_reason = ?
                    )
                    """,
                arguments: [
                    StructuredOutputStatus.needsReview.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    OutputAssuranceState.stale.rawValue,
                    staleReason,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET assurance_state = ?
                    WHERE task_kind = ?
                      AND request_schema_version IS NULL
                      AND assurance_state IN (?, ?)
                    """,
                arguments: [
                    OutputAssuranceState.stale.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    OutputAssuranceState.corpusComplete.rawValue,
                    OutputAssuranceState.propositionSupported.rawValue,
                ]
            )
        }

        migrator.registerMigration("v073_create_case_file_review_projects") { db in
            // The mutable attorney-work layer is intentionally separate from
            // the immutable exact corpus proof and Structured Output snapshot.
            // Frozen source identities are text; nullable live pointers support
            // preview and precise degradation after permanent source deletion.
            try db.execute(sql: """
                CREATE TABLE case_file_review_projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    status TEXT NOT NULL CHECK (status IN ('active', 'stale')),
                    stale_reason TEXT,
                    source_run_id TEXT NOT NULL CHECK (length(source_run_id) > 0),
                    source_output_id TEXT NOT NULL CHECK (length(source_output_id) > 0),
                    source_output_version_id TEXT NOT NULL
                        CHECK (length(source_output_version_id) > 0),
                    source_request_digest TEXT NOT NULL CHECK (
                        length(source_request_digest) = 64
                        AND source_request_digest NOT GLOB '*[^0-9a-f]*'
                    ),
                    frozen_scope_json TEXT NOT NULL CHECK (
                        json_valid(frozen_scope_json) = 1
                        AND json_type(frozen_scope_json) = 'object'
                    ),
                    frozen_corpus_snapshot_json TEXT NOT NULL CHECK (
                        json_valid(frozen_corpus_snapshot_json) = 1
                        AND json_type(frozen_corpus_snapshot_json) = 'object'
                    ),
                    frozen_reconciliation_json TEXT NOT NULL CHECK (
                        json_valid(frozen_reconciliation_json) = 1
                        AND json_type(frozen_reconciliation_json) = 'object'
                    ),
                    active_table_id TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (status = 'active' AND stale_reason IS NULL)
                        OR (status = 'stale' AND length(stale_reason) > 0)
                    ),
                    UNIQUE (source_run_id),
                    UNIQUE (source_output_version_id),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (active_table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE SET NULL
                )
                """)
            try db.create(
                index: "idx_case_file_review_projects_matter_updated",
                on: "case_file_review_projects",
                columns: ["matter_id", "updated_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE case_file_review_tables (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index >= 1
                    ),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, project_id),
                    UNIQUE (project_id, version_index),
                    FOREIGN KEY (project_id)
                        REFERENCES case_file_review_projects(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_columns (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    column_key TEXT NOT NULL CHECK (
                        column_key IN ('finding', 'generated_value', 'sources', 'review')
                    ),
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, table_id),
                    UNIQUE (table_id, column_key),
                    UNIQUE (table_id, ordinal),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_rows (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    row_key TEXT NOT NULL CHECK (length(row_key) > 0),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, table_id),
                    UNIQUE (table_id, row_key),
                    UNIQUE (table_id, ordinal),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_cells (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    column_id TEXT NOT NULL,
                    current_generation_id TEXT,
                    attorney_value TEXT,
                    review_state TEXT NOT NULL CHECK (
                        review_state IN ('needs_review', 'reviewed')
                    ),
                    value_state TEXT NOT NULL CHECK (
                        value_state IN ('generated', 'edited')
                    ),
                    support_state TEXT NOT NULL CHECK (
                        support_state IN ('supported', 'unsupported', 'failed', 'stale')
                    ),
                    reviewed_by TEXT,
                    reviewed_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (review_state = 'needs_review'
                            AND reviewed_by IS NULL AND reviewed_at IS NULL)
                        OR (review_state = 'reviewed'
                            AND length(reviewed_by) > 0 AND reviewed_at IS NOT NULL)
                    ),
                    CHECK (
                        (value_state = 'generated' AND attorney_value IS NULL)
                        OR (value_state = 'edited' AND length(attorney_value) > 0)
                    ),
                    UNIQUE (row_id, column_id),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE,
                    FOREIGN KEY (row_id, table_id)
                        REFERENCES case_file_review_rows(id, table_id) ON DELETE CASCADE,
                    FOREIGN KEY (column_id, table_id)
                        REFERENCES case_file_review_columns(id, table_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_case_file_review_cells_table_row",
                on: "case_file_review_cells",
                columns: ["table_id", "row_id", "column_id"]
            )

            try db.execute(sql: """
                CREATE TABLE case_file_review_cell_generations (
                    id TEXT PRIMARY KEY NOT NULL,
                    cell_id TEXT NOT NULL,
                    generation_index INTEGER NOT NULL CHECK (
                        typeof(generation_index) = 'integer' AND generation_index >= 1
                    ),
                    source_run_id TEXT NOT NULL CHECK (length(source_run_id) > 0),
                    generated_values_json TEXT NOT NULL CHECK (
                        json_valid(generated_values_json) = 1
                        AND json_type(generated_values_json) = 'array'
                        AND json_array_length(generated_values_json) > 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (cell_id, generation_index),
                    FOREIGN KEY (cell_id)
                        REFERENCES case_file_review_cells(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_evidence_edges (
                    id TEXT PRIMARY KEY NOT NULL,
                    generation_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('supporting', 'contrary')),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    frozen_output_source_id TEXT NOT NULL
                        CHECK (length(frozen_output_source_id) > 0),
                    frozen_document_id TEXT NOT NULL CHECK (length(frozen_document_id) > 0),
                    frozen_revision_id TEXT NOT NULL CHECK (length(frozen_revision_id) > 0),
                    frozen_document_name TEXT NOT NULL
                        CHECK (length(frozen_document_name) > 0),
                    citation_label TEXT NOT NULL CHECK (length(citation_label) > 0),
                    char_start INTEGER,
                    char_end INTEGER,
                    locator_json TEXT NOT NULL CHECK (
                        json_valid(locator_json) = 1 AND json_type(locator_json) = 'object'
                    ),
                    excerpt TEXT NOT NULL CHECK (length(excerpt) > 0),
                    excerpt_sha256 TEXT NOT NULL CHECK (
                        length(excerpt_sha256) = 64
                        AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    live_output_source_id TEXT,
                    live_document_id TEXT,
                    live_revision_id TEXT,
                    availability TEXT NOT NULL CHECK (
                        availability IN ('available', 'unavailable')
                    ),
                    unavailable_reason TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (char_start IS NULL AND char_end IS NULL)
                        OR (
                            typeof(char_start) = 'integer'
                            AND typeof(char_end) = 'integer'
                            AND char_start >= 0 AND char_end > char_start
                        )
                    ),
                    CHECK (
                        (availability = 'available' AND unavailable_reason IS NULL
                            AND live_output_source_id IS NOT NULL
                            AND live_document_id IS NOT NULL
                            AND live_revision_id IS NOT NULL)
                        OR (availability = 'unavailable' AND length(unavailable_reason) > 0
                            AND live_output_source_id IS NULL
                            AND live_document_id IS NULL
                            AND live_revision_id IS NULL)
                    ),
                    UNIQUE (generation_id, kind, ordinal),
                    FOREIGN KEY (generation_id)
                        REFERENCES case_file_review_cell_generations(id) ON DELETE CASCADE,
                    FOREIGN KEY (live_output_source_id)
                        REFERENCES document_output_sources(id) ON DELETE SET NULL,
                    FOREIGN KEY (live_document_id)
                        REFERENCES matter_documents(id) ON DELETE SET NULL,
                    FOREIGN KEY (live_revision_id)
                        REFERENCES document_part_revisions(id) ON DELETE SET NULL
                )
                """)
            try db.create(
                index: "idx_case_file_review_evidence_live_document",
                on: "case_file_review_evidence_edges",
                columns: ["live_document_id", "live_revision_id"]
            )

            // Review graph parents are removed only as part of whole-matter
            // deletion. SQLite removes the owning matter row before running its
            // foreign-key cascades, so the matter-exists predicate rejects a
            // direct graph delete without blocking that audited repository path.
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_project_delete_guard
                BEFORE DELETE ON case_file_review_projects
                WHEN EXISTS (
                    SELECT 1 FROM matters WHERE id = OLD.matter_id
                )
                BEGIN SELECT RAISE(ABORT, 'review projects require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_table_delete_guard
                BEFORE DELETE ON case_file_review_tables
                WHEN EXISTS (
                    SELECT 1
                    FROM case_file_review_projects AS project
                    JOIN matters AS matter ON matter.id = project.matter_id
                    WHERE project.id = OLD.project_id
                )
                BEGIN SELECT RAISE(ABORT, 'review tables require whole-matter deletion'); END
                """)

            let reviewTableMatterOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_tables AS review_table
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    JOIN matters AS matter ON matter.id = project.matter_id
                    WHERE review_table.id = OLD.table_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_column_delete_guard
                BEFORE DELETE ON case_file_review_columns
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review columns require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_row_delete_guard
                BEFORE DELETE ON case_file_review_rows
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review rows require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_cell_delete_guard
                BEFORE DELETE ON case_file_review_cells
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review cells require whole-matter deletion'); END
                """)

            // Generated payloads never change in place. Cascading project/matter
            // deletion is still permitted because the owning cell/project has
            // already left the visible graph when its child cascade executes.
            let generationOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_cells AS cell
                    JOIN case_file_review_tables AS review_table
                      ON review_table.id = cell.table_id
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    WHERE cell.id = OLD.cell_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_generation_update_guard
                BEFORE UPDATE ON case_file_review_cell_generations
                WHEN \(generationOwner)
                BEGIN SELECT RAISE(ABORT, 'review cell generations are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_generation_delete_guard
                BEFORE DELETE ON case_file_review_cell_generations
                WHEN \(generationOwner)
                BEGIN SELECT RAISE(ABORT, 'review cell generations are append-only'); END
                """)

            let evidenceOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_cell_generations AS generation
                    JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                    JOIN case_file_review_tables AS review_table
                      ON review_table.id = cell.table_id
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    WHERE generation.id = OLD.generation_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_frozen_update_guard
                BEFORE UPDATE OF generation_id, kind, ordinal, frozen_output_source_id,
                    frozen_document_id, frozen_revision_id, frozen_document_name,
                    citation_label, char_start, char_end, locator_json, excerpt,
                    excerpt_sha256, created_at
                ON case_file_review_evidence_edges
                WHEN \(evidenceOwner)
                BEGIN SELECT RAISE(ABORT, 'review evidence snapshots are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_delete_guard
                BEFORE DELETE ON case_file_review_evidence_edges
                WHEN \(evidenceOwner)
                BEGIN SELECT RAISE(ABORT, 'review evidence snapshots are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_availability_guard
                BEFORE UPDATE OF availability, unavailable_reason, live_output_source_id,
                    live_document_id, live_revision_id
                ON case_file_review_evidence_edges
                WHEN NOT (
                    OLD.availability = 'available'
                    AND NEW.availability = 'unavailable'
                    AND length(NEW.unavailable_reason) > 0
                    AND NEW.live_output_source_id IS NULL
                    AND NEW.live_document_id IS NULL
                    AND NEW.live_revision_id IS NULL
                )
                BEGIN SELECT RAISE(ABORT, 'review evidence availability only degrades'); END
                """)
        }

        migrator.registerMigration("v074_create_canonical_matter_identity") { db in
            // The v1 court identity contract is frozen into this migration. Store
            // does not import SupraResearch and must never apply search or fuzzy
            // matching while converting persisted legal identity.
            let catalogVersion = "jurisdiction-courts-v1"
            let catalogDigest =
                "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
            let eleventhCircuitJurisdictionID =
                "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
            let southernDistrictCourtID =
                "federal-florida-united-states-district-court-for-the-southern-district-of-florida"

            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_jurisdiction_id TEXT
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_court_id TEXT
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN court_resolution_state TEXT NOT NULL
                    DEFAULT 'unresolved'
                    CHECK (court_resolution_state IN (
                        'unresolved', 'jurisdiction_only', 'court', 'not_applicable'
                    ))
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_catalog_version TEXT NOT NULL
                    DEFAULT 'jurisdiction-courts-v1'
                    CHECK (length(canonical_catalog_version) > 0)
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_catalog_digest_sha256 TEXT NOT NULL
                    DEFAULT '0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3'
                    CHECK (
                        length(canonical_catalog_digest_sha256) = 64
                        AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    )
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN identity_revision INTEGER NOT NULL
                    DEFAULT 1
                    CHECK (typeof(identity_revision) = 'integer' AND identity_revision >= 1)
                """)

            // Structured parties are deliberately empty after migration. Legacy
            // client_names and party_perspective remain exact conversion inputs,
            // not authority to invent litigants or representation relationships.
            try db.execute(sql: """
                CREATE TABLE matter_parties (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    display_name TEXT NOT NULL CHECK (length(display_name) > 0),
                    caption_name TEXT NOT NULL CHECK (length(caption_name) > 0),
                    base_role TEXT NOT NULL CHECK (base_role IN (
                        'plaintiff', 'defendant', 'petitioner', 'respondent',
                        'appellant', 'appellee', 'movant', 'third_party',
                        'nonparty', 'other'
                    )),
                    caption_order INTEGER NOT NULL CHECK (
                        typeof(caption_order) = 'integer' AND caption_order >= 0
                    ),
                    client_status TEXT NOT NULL CHECK (client_status IN (
                        'represented', 'not_represented', 'unresolved'
                    )),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    UNIQUE (matter_id, caption_order),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_matter_parties_matter_caption",
                on: "matter_parties",
                columns: ["matter_id", "caption_order"]
            )

            try db.execute(sql: """
                CREATE TABLE matter_representations (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    represented_party_id TEXT NOT NULL,
                    relationship_kind TEXT NOT NULL CHECK (relationship_kind IN (
                        'counsel', 'self_represented', 'guardian', 'other'
                    )),
                    representative_name TEXT NOT NULL CHECK (length(representative_name) > 0),
                    firm_name TEXT CHECK (firm_name IS NULL OR length(firm_name) > 0),
                    service_address_json TEXT CHECK (
                        service_address_json IS NULL
                        OR (
                            json_valid(service_address_json) = 1
                            AND json_type(service_address_json) = 'object'
                        )
                    ),
                    service_emails_json TEXT NOT NULL DEFAULT '[]' CHECK (
                        json_valid(service_emails_json) = 1
                        AND json_type(service_emails_json) = 'array'
                    ),
                    service_order INTEGER CHECK (
                        service_order IS NULL
                        OR (typeof(service_order) = 'integer' AND service_order >= 0)
                    ),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_matter_representations_matter_party",
                on: "matter_representations",
                columns: ["matter_id", "represented_party_id"]
            )

            try db.execute(sql: """
                CREATE TABLE matter_identity_conversion_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    source_kind TEXT NOT NULL CHECK (
                        source_kind IN ('migration', 'create', 'update')
                    ),
                    source_migration TEXT CHECK (
                        (source_kind = 'migration'
                            AND source_migration = 'v074_create_canonical_matter_identity'
                            AND identity_revision = 1)
                        OR (source_kind IN ('create', 'update')
                            AND source_migration IS NULL)
                    ),
                    identity_revision INTEGER NOT NULL CHECK (
                        typeof(identity_revision) = 'integer' AND identity_revision >= 1
                    ),
                    court_resolution_state TEXT NOT NULL CHECK (
                        court_resolution_state IN (
                            'unresolved', 'jurisdiction_only', 'court', 'not_applicable'
                        )
                    ),
                    resolution_reason TEXT NOT NULL CHECK (
                        resolution_reason IN (
                            'explicit_alias', 'ambiguous', 'unknown',
                            'unchanged_canonical', 'jurisdiction_only', 'not_applicable'
                        )
                    ),
                    legacy_jurisdiction TEXT NOT NULL,
                    legacy_court TEXT,
                    legacy_party_perspective TEXT NOT NULL,
                    legacy_client_names TEXT,
                    canonical_jurisdiction_id TEXT,
                    canonical_court_id TEXT,
                    canonical_catalog_version TEXT NOT NULL
                        CHECK (length(canonical_catalog_version) > 0),
                    canonical_catalog_digest_sha256 TEXT NOT NULL CHECK (
                        length(canonical_catalog_digest_sha256) = 64
                        AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    UNIQUE (matter_id, identity_revision),
                    CHECK (
                        (court_resolution_state = 'unresolved'
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL)
                        OR (court_resolution_state = 'jurisdiction_only'
                            AND length(canonical_jurisdiction_id) > 0
                            AND canonical_court_id IS NULL)
                        OR (court_resolution_state = 'court'
                            AND length(canonical_jurisdiction_id) > 0
                            AND length(canonical_court_id) > 0)
                        OR (court_resolution_state = 'not_applicable'
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE matter_identity_decision_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('court_resolution', 'party_override')),
                    source_conversion_receipt_id TEXT,
                    prior_identity_revision INTEGER NOT NULL CHECK (
                        typeof(prior_identity_revision) = 'integer'
                        AND prior_identity_revision >= 1
                    ),
                    result_identity_revision INTEGER NOT NULL CHECK (
                        typeof(result_identity_revision) = 'integer'
                        AND result_identity_revision >= 1
                    ),
                    legacy_court TEXT,
                    canonical_jurisdiction_id TEXT CHECK (
                        canonical_jurisdiction_id IS NULL
                        OR length(canonical_jurisdiction_id) > 0
                    ),
                    canonical_court_id TEXT CHECK (
                        canonical_court_id IS NULL OR length(canonical_court_id) > 0
                    ),
                    canonical_represented_party_id TEXT,
                    requested_represented_party_id TEXT,
                    resolution_source TEXT NOT NULL CHECK (length(resolution_source) > 0),
                    actor TEXT NOT NULL CHECK (length(actor) > 0),
                    purpose TEXT NOT NULL CHECK (length(purpose) > 0),
                    canonical_catalog_version TEXT CHECK (
                        canonical_catalog_version IS NULL
                        OR length(canonical_catalog_version) > 0
                    ),
                    canonical_catalog_digest_sha256 TEXT CHECK (
                        canonical_catalog_digest_sha256 IS NULL
                        OR (
                            length(canonical_catalog_digest_sha256) = 64
                            AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    decided_at DATETIME NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE (request_digest_sha256),
                    CHECK (
                        (kind = 'court_resolution'
                            AND source_conversion_receipt_id IS NOT NULL
                            AND result_identity_revision = prior_identity_revision + 1
                            AND canonical_jurisdiction_id IS NOT NULL
                            AND length(canonical_jurisdiction_id) > 0
                            AND canonical_court_id IS NOT NULL
                            AND length(canonical_court_id) > 0
                            AND canonical_represented_party_id IS NULL
                            AND requested_represented_party_id IS NULL
                            AND canonical_catalog_version IS NOT NULL
                            AND canonical_catalog_version = 'jurisdiction-courts-v1'
                            AND canonical_catalog_digest_sha256 IS NOT NULL
                            AND canonical_catalog_digest_sha256 =
                                '0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3')
                        OR (kind = 'party_override'
                            AND source_conversion_receipt_id IS NULL
                            AND result_identity_revision = prior_identity_revision
                            AND legacy_court IS NULL
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL
                            AND canonical_represented_party_id IS NOT NULL
                            AND length(canonical_represented_party_id) > 0
                            AND requested_represented_party_id IS NOT NULL
                            AND length(requested_represented_party_id) > 0
                            AND canonical_represented_party_id <>
                                requested_represented_party_id
                            AND resolution_source = 'attorney_confirmation'
                            AND canonical_catalog_version IS NULL
                            AND canonical_catalog_digest_sha256 IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (source_conversion_receipt_id, matter_id)
                        REFERENCES matter_identity_conversion_receipts(id, matter_id)
                        ON DELETE CASCADE,
                    FOREIGN KEY (canonical_represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE,
                    FOREIGN KEY (requested_represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_matter_identity_court_result_revision
                ON matter_identity_decision_receipts(matter_id, result_identity_revision)
                WHERE kind = 'court_resolution'
                """)

            // One exact reviewed alias is admitted. The shorter unqualified
            // spelling is intentionally ambiguous, and every other legacy value
            // remains unresolved with its original text untouched.
            try db.execute(
                sql: """
                    UPDATE matters
                    SET canonical_jurisdiction_id = CASE court
                            WHEN 'S.D. Fla.' THEN ?
                            ELSE NULL
                        END,
                        canonical_court_id = CASE court
                            WHEN 'S.D. Fla.' THEN ?
                            ELSE NULL
                        END,
                        court_resolution_state = CASE court
                            WHEN 'S.D. Fla.' THEN 'court'
                            ELSE 'unresolved'
                        END,
                        canonical_catalog_version = ?,
                        canonical_catalog_digest_sha256 = ?,
                        identity_revision = 1
                    """,
                arguments: [
                    eleventhCircuitJurisdictionID,
                    southernDistrictCourtID,
                    catalogVersion,
                    catalogDigest,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO matter_identity_conversion_receipts (
                        id, matter_id, source_kind, source_migration, identity_revision,
                        court_resolution_state, resolution_reason,
                        legacy_jurisdiction, legacy_court,
                        legacy_party_perspective, legacy_client_names,
                        canonical_jurisdiction_id, canonical_court_id,
                        canonical_catalog_version,
                        canonical_catalog_digest_sha256, created_at
                    )
                    SELECT
                        'v074-conversion:' || id,
                        id,
                        'migration',
                        'v074_create_canonical_matter_identity',
                        1,
                        court_resolution_state,
                        CASE court
                            WHEN 'S.D. Fla.' THEN 'explicit_alias'
                            WHEN 'Southern District of Florida' THEN 'ambiguous'
                            ELSE 'unknown'
                        END,
                        jurisdiction,
                        court,
                        party_perspective,
                        client_names,
                        canonical_jurisdiction_id,
                        canonical_court_id,
                        canonical_catalog_version,
                        canonical_catalog_digest_sha256,
                        updated_at
                    FROM matters
                    ORDER BY id
                    """
            )

            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_insert_guard
                BEFORE INSERT ON matters
                WHEN NOT (
                    (NEW.court_resolution_state = 'unresolved'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'jurisdiction_only'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'court'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND length(NEW.canonical_court_id) > 0)
                    OR (NEW.court_resolution_state = 'not_applicable'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                )
                BEGIN SELECT RAISE(ABORT, 'canonical matter identity is incoherent'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_update_guard
                BEFORE UPDATE OF canonical_jurisdiction_id, canonical_court_id,
                    court_resolution_state, canonical_catalog_version,
                    canonical_catalog_digest_sha256, identity_revision
                ON matters
                WHEN NOT (
                    (NEW.court_resolution_state = 'unresolved'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'jurisdiction_only'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'court'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND length(NEW.canonical_court_id) > 0)
                    OR (NEW.court_resolution_state = 'not_applicable'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                )
                BEGIN SELECT RAISE(ABORT, 'canonical matter identity is incoherent'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_receipt_guard
                BEFORE UPDATE OF jurisdiction, party_perspective, court, client_names,
                    canonical_jurisdiction_id, canonical_court_id,
                    court_resolution_state, canonical_catalog_version,
                    canonical_catalog_digest_sha256, identity_revision
                ON matters
                WHEN (
                    OLD.jurisdiction IS NOT NEW.jurisdiction
                    OR OLD.party_perspective IS NOT NEW.party_perspective
                    OR OLD.court IS NOT NEW.court
                    OR OLD.client_names IS NOT NEW.client_names
                    OR OLD.canonical_jurisdiction_id IS NOT NEW.canonical_jurisdiction_id
                    OR OLD.canonical_court_id IS NOT NEW.canonical_court_id
                    OR OLD.court_resolution_state IS NOT NEW.court_resolution_state
                    OR OLD.canonical_catalog_version IS NOT NEW.canonical_catalog_version
                    OR OLD.canonical_catalog_digest_sha256
                        IS NOT NEW.canonical_catalog_digest_sha256
                    OR OLD.identity_revision IS NOT NEW.identity_revision
                ) AND NOT (
                    EXISTS (
                        SELECT 1
                        FROM matter_identity_conversion_receipts AS source
                        WHERE source.matter_id = NEW.id
                          AND source.identity_revision = NEW.identity_revision
                          AND source.court_resolution_state = NEW.court_resolution_state
                          AND source.legacy_jurisdiction = NEW.jurisdiction
                          AND source.legacy_court IS NEW.court
                          AND source.legacy_party_perspective = NEW.party_perspective
                          AND source.legacy_client_names IS NEW.client_names
                          AND source.canonical_jurisdiction_id
                              IS NEW.canonical_jurisdiction_id
                          AND source.canonical_court_id IS NEW.canonical_court_id
                          AND source.canonical_catalog_version
                              = NEW.canonical_catalog_version
                          AND source.canonical_catalog_digest_sha256
                              = NEW.canonical_catalog_digest_sha256
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM matter_identity_decision_receipts AS decision
                        WHERE decision.matter_id = NEW.id
                          AND decision.kind = 'court_resolution'
                          AND decision.result_identity_revision = NEW.identity_revision
                          AND NEW.court_resolution_state = 'court'
                          AND decision.canonical_jurisdiction_id
                              = NEW.canonical_jurisdiction_id
                          AND decision.canonical_court_id = NEW.canonical_court_id
                          AND decision.canonical_catalog_version
                              = NEW.canonical_catalog_version
                          AND decision.canonical_catalog_digest_sha256
                              = NEW.canonical_catalog_digest_sha256
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'canonical matter identity transition lacks receipt');
                END
                """)

            // Receipts are immutable while their owning matter exists. A whole-
            // matter delete remains possible because SQLite removes the parent
            // before running the child cascades.
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_conversion_update_guard
                BEFORE UPDATE ON matter_identity_conversion_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity conversions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_conversion_delete_guard
                BEFORE DELETE ON matter_identity_conversion_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity conversions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_decision_update_guard
                BEFORE UPDATE ON matter_identity_decision_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity decisions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_decision_delete_guard
                BEFORE DELETE ON matter_identity_decision_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity decisions are append-only'); END
                """)

            // Kept deliberately late and non-idempotent within the migration so
            // the shipping closure's transaction rollback can be fault-injected.
            try db.execute(sql: """
                CREATE INDEX idx_matter_identity_decisions_matter
                ON matter_identity_decision_receipts(matter_id, decided_at)
                """)
        }

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

        migrator.registerMigration("v077_create_accepted_research_packets") { db in
            // Provider execution is evidence, not accepted legal authority.
            // This candidate ledger makes the executed -> reviewed -> accepted
            // transition explicit and preserves the exact content-free egress
            // identity used for the provider call.
            try db.execute(sql: """
                CREATE TABLE research_packet_candidates (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(id)) > 0),
                    packet_id TEXT NOT NULL CHECK (length(trim(packet_id)) > 0),
                    matter_id TEXT NOT NULL,
                    research_session_id TEXT NOT NULL,
                    research_query_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('executed', 'reviewed', 'accepted', 'cancelled')
                    ),
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    egress_authority_kind TEXT NOT NULL CHECK (
                        egress_authority_kind = 'approved_grant'
                    ),
                    egress_grant_id TEXT NOT NULL CHECK (
                        length(trim(egress_grant_id)) > 0
                    ),
                    egress_grant_version INTEGER NOT NULL CHECK (
                        typeof(egress_grant_version) = 'integer'
                        AND egress_grant_version > 0
                    ),
                    exact_query_sha256 TEXT NOT NULL CHECK (
                        length(exact_query_sha256) = 64
                        AND exact_query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    execution_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(execution_digest_sha256) = 64
                        AND execution_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    source_digest_sha256 TEXT CHECK (
                        source_digest_sha256 IS NULL OR (
                            length(source_digest_sha256) = 64
                            AND source_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    review_digest_sha256 TEXT CHECK (
                        review_digest_sha256 IS NULL OR (
                            length(review_digest_sha256) = 64
                            AND review_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    reviewer_id TEXT,
                    reviewer_action TEXT CHECK (
                        reviewer_action IS NULL
                        OR reviewer_action = 'approved_for_authority_use'
                    ),
                    reviewed_at DATETIME,
                    cancelled_by TEXT,
                    cancelled_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (state = 'executed'
                            AND source_digest_sha256 IS NULL
                            AND review_digest_sha256 IS NULL
                            AND reviewer_id IS NULL
                            AND reviewer_action IS NULL
                            AND reviewed_at IS NULL
                            AND cancelled_by IS NULL
                            AND cancelled_at IS NULL)
                        OR (state IN ('reviewed', 'accepted')
                            AND source_digest_sha256 IS NOT NULL
                            AND review_digest_sha256 IS NOT NULL
                            AND length(trim(reviewer_id)) > 0
                            AND reviewer_action = 'approved_for_authority_use'
                            AND reviewed_at IS NOT NULL
                            AND cancelled_by IS NULL
                            AND cancelled_at IS NULL)
                        OR (state = 'cancelled'
                            AND length(trim(cancelled_by)) > 0
                            AND cancelled_at IS NOT NULL
                            AND (
                                (source_digest_sha256 IS NULL
                                    AND review_digest_sha256 IS NULL
                                    AND reviewer_id IS NULL
                                    AND reviewer_action IS NULL
                                    AND reviewed_at IS NULL)
                                OR (source_digest_sha256 IS NOT NULL
                                    AND review_digest_sha256 IS NOT NULL
                                    AND length(trim(reviewer_id)) > 0
                                    AND reviewer_action = 'approved_for_authority_use'
                                    AND reviewed_at IS NOT NULL)
                            ))
                    ),
                    FOREIGN KEY (matter_id)
                        REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_query_id)
                        REFERENCES research_queries(id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_research_packet_candidates_packet",
                on: "research_packet_candidates",
                columns: ["packet_id", "created_at", "id"]
            )
            try db.create(
                index: "idx_research_packet_candidates_matter",
                on: "research_packet_candidates",
                columns: ["matter_id", "updated_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE research_packet_candidate_sources (
                    execution_id TEXT NOT NULL,
                    source_index INTEGER NOT NULL CHECK (
                        typeof(source_index) = 'integer' AND source_index >= 0
                    ),
                    research_result_id TEXT NOT NULL CHECK (
                        length(trim(research_result_id)) > 0
                    ),
                    provider_result_id TEXT NOT NULL CHECK (
                        length(trim(provider_result_id)) > 0
                    ),
                    authority_id TEXT,
                    ground_key TEXT,
                    reviewed_proposition_binding_sha256 TEXT CHECK (
                        reviewed_proposition_binding_sha256 IS NULL OR (
                            length(reviewed_proposition_binding_sha256) = 64
                            AND reviewed_proposition_binding_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    excerpt TEXT,
                    excerpt_sha256 TEXT CHECK (
                        excerpt_sha256 IS NULL OR (
                            length(excerpt_sha256) = 64
                            AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    PRIMARY KEY (execution_id, source_index),
                    UNIQUE (execution_id, research_result_id),
                    UNIQUE (execution_id, provider_result_id),
                    CHECK (
                        (authority_id IS NULL
                            AND ground_key IS NULL
                            AND reviewed_proposition_binding_sha256 IS NULL
                            AND excerpt IS NULL
                            AND excerpt_sha256 IS NULL)
                        OR (length(trim(authority_id)) > 0
                            AND length(trim(ground_key)) > 0
                            AND reviewed_proposition_binding_sha256 IS NOT NULL
                            AND length(excerpt) > 0
                            AND excerpt_sha256 IS NOT NULL)
                    ),
                    FOREIGN KEY (execution_id)
                        REFERENCES research_packet_candidates(id) ON DELETE CASCADE
                )
                """)

            // Accepted versions and their ordered frozen sources are an
            // immutable projection. Live authority/result rows remain useful
            // for revalidation but are deliberately not cascade parents here.
            try db.execute(sql: """
                CREATE TABLE accepted_research_packet_versions (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(id)) > 0),
                    packet_id TEXT NOT NULL CHECK (length(trim(packet_id)) > 0),
                    execution_id TEXT NOT NULL UNIQUE,
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index > 0
                    ),
                    state TEXT NOT NULL CHECK (state = 'accepted'),
                    matter_id TEXT NOT NULL,
                    research_session_id TEXT NOT NULL,
                    research_query_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    egress_grant_id TEXT NOT NULL CHECK (
                        length(trim(egress_grant_id)) > 0
                    ),
                    egress_grant_version INTEGER NOT NULL CHECK (
                        typeof(egress_grant_version) = 'integer'
                        AND egress_grant_version > 0
                    ),
                    exact_query_sha256 TEXT NOT NULL CHECK (
                        length(exact_query_sha256) = 64
                        AND exact_query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    source_digest_sha256 TEXT NOT NULL CHECK (
                        length(source_digest_sha256) = 64
                        AND source_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    review_digest_sha256 TEXT NOT NULL CHECK (
                        length(review_digest_sha256) = 64
                        AND review_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    reviewer_id TEXT NOT NULL CHECK (length(trim(reviewer_id)) > 0),
                    reviewer_action TEXT NOT NULL CHECK (
                        reviewer_action = 'approved_for_authority_use'
                    ),
                    aggregate_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(aggregate_digest_sha256) = 64
                        AND aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    audit_event_id TEXT NOT NULL UNIQUE,
                    accepted_at DATETIME NOT NULL,
                    UNIQUE (packet_id, version_index),
                    FOREIGN KEY (execution_id)
                        REFERENCES research_packet_candidates(id) ON DELETE CASCADE,
                    FOREIGN KEY (matter_id)
                        REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_query_id)
                        REFERENCES research_queries(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)
            try db.create(
                index: "idx_accepted_research_packets_matter",
                on: "accepted_research_packet_versions",
                columns: ["matter_id", "accepted_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE accepted_research_packet_sources (
                    packet_version_id TEXT NOT NULL,
                    source_index INTEGER NOT NULL CHECK (
                        typeof(source_index) = 'integer' AND source_index >= 0
                    ),
                    research_result_id TEXT NOT NULL CHECK (
                        length(trim(research_result_id)) > 0
                    ),
                    provider_result_id TEXT NOT NULL CHECK (
                        length(trim(provider_result_id)) > 0
                    ),
                    authority_id TEXT NOT NULL CHECK (length(trim(authority_id)) > 0),
                    ground_key TEXT NOT NULL CHECK (length(trim(ground_key)) > 0),
                    excerpt TEXT NOT NULL CHECK (length(excerpt) > 0),
                    excerpt_sha256 TEXT NOT NULL CHECK (
                        length(excerpt_sha256) = 64
                        AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    reviewed_proposition_binding_sha256 TEXT NOT NULL CHECK (
                        length(reviewed_proposition_binding_sha256) = 64
                        AND reviewed_proposition_binding_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    PRIMARY KEY (packet_version_id, source_index),
                    UNIQUE (packet_version_id, research_result_id),
                    UNIQUE (packet_version_id, authority_id),
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE research_packet_acceptance_receipts (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    accepted_version_id TEXT NOT NULL UNIQUE,
                    created_at DATETIME NOT NULL,
                    FOREIGN KEY (accepted_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE research_packet_version_dispositions (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    packet_version_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('superseded', 'revoked')),
                    replacement_packet_version_id TEXT,
                    actor TEXT NOT NULL CHECK (length(trim(actor)) > 0),
                    reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
                    occurred_at DATETIME NOT NULL,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    CHECK (
                        (kind = 'superseded'
                            AND length(trim(replacement_packet_version_id)) > 0
                            AND replacement_packet_version_id <> packet_version_id)
                        OR (kind = 'revoked'
                            AND replacement_packet_version_id IS NULL)
                    ),
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)
            try db.create(
                index: "idx_research_packet_dispositions_version",
                on: "research_packet_version_dispositions",
                columns: ["packet_version_id", "occurred_at", "idempotency_key"]
            )

            try db.execute(sql: """
                CREATE TABLE research_packet_work_product_bindings (
                    structured_output_version_id TEXT PRIMARY KEY NOT NULL,
                    idempotency_key TEXT NOT NULL UNIQUE CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    packet_version_id TEXT NOT NULL,
                    packet_aggregate_digest_sha256 TEXT NOT NULL CHECK (
                        length(packet_aggregate_digest_sha256) = 64
                        AND packet_aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    created_at DATETIME NOT NULL,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    FOREIGN KEY (structured_output_version_id)
                        REFERENCES structured_output_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)

            // Candidate identities are immutable from execution onward. Only
            // review evidence may be attached while executed, followed by one
            // legal state edge. Terminal candidates are append-only.
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_identity_update_guard
                BEFORE UPDATE OF packet_id, matter_id, research_session_id,
                    research_query_id, provider_id, egress_authority_kind,
                    egress_grant_id, egress_grant_version, exact_query_sha256,
                    execution_digest_sha256, created_at
                ON research_packet_candidates
                BEGIN SELECT RAISE(ABORT, 'research packet execution is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_review_update_guard
                BEFORE UPDATE OF source_digest_sha256, review_digest_sha256,
                    reviewer_id, reviewer_action, reviewed_at
                ON research_packet_candidates
                WHEN OLD.state <> 'executed'
                BEGIN SELECT RAISE(ABORT, 'research packet review is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_transition_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NOT (
                    (OLD.state = 'executed' AND NEW.state IN ('reviewed', 'cancelled'))
                    OR (OLD.state = 'reviewed' AND NEW.state IN ('accepted', 'cancelled'))
                )
                BEGIN SELECT RAISE(ABORT, 'invalid research packet transition'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_review_completion_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NEW.state = 'reviewed' AND (
                    NOT EXISTS (
                        SELECT 1 FROM research_packet_candidate_sources
                        WHERE execution_id = OLD.id
                    )
                    OR EXISTS (
                        SELECT 1 FROM research_packet_candidate_sources
                        WHERE execution_id = OLD.id
                          AND (authority_id IS NULL
                            OR ground_key IS NULL
                            OR reviewed_proposition_binding_sha256 IS NULL
                            OR excerpt IS NULL
                            OR excerpt_sha256 IS NULL)
                    )
                )
                BEGIN SELECT RAISE(ABORT, 'research packet review is incomplete'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_acceptance_completion_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NEW.state = 'accepted' AND NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS version
                    JOIN research_packet_acceptance_receipts AS receipt
                      ON receipt.accepted_version_id = version.id
                    WHERE version.execution_id = OLD.id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet acceptance is incomplete'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_terminal_update_guard
                BEFORE UPDATE ON research_packet_candidates
                WHEN OLD.state IN ('accepted', 'cancelled')
                BEGIN SELECT RAISE(ABORT, 'terminal research packet is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_delete_guard
                BEFORE DELETE ON research_packet_candidates
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'research packet history is append-only'); END
                """)

            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_insert_guard
                BEFORE INSERT ON research_packet_candidate_sources
                WHEN NOT EXISTS (
                    SELECT 1 FROM research_packet_candidates
                    WHERE id = NEW.execution_id AND state = 'executed'
                )
                BEGIN SELECT RAISE(ABORT, 'candidate sources require executed packet'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_update_guard
                BEFORE UPDATE ON research_packet_candidate_sources
                WHEN OLD.execution_id IS NOT NEW.execution_id
                  OR OLD.source_index IS NOT NEW.source_index
                  OR OLD.research_result_id IS NOT NEW.research_result_id
                  OR OLD.provider_result_id IS NOT NEW.provider_result_id
                  OR NOT EXISTS (
                    SELECT 1 FROM research_packet_candidates
                    WHERE id = OLD.execution_id AND state = 'executed'
                  )
                BEGIN SELECT RAISE(ABORT, 'candidate source identity is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_delete_guard
                BEFORE DELETE ON research_packet_candidate_sources
                WHEN EXISTS (
                    SELECT 1 FROM research_packet_candidates WHERE id = OLD.execution_id
                )
                BEGIN SELECT RAISE(ABORT, 'candidate sources are append-only'); END
                """)

            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_version_insert_guard
                BEFORE INSERT ON accepted_research_packet_versions
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM research_packet_candidates AS candidate
                    WHERE candidate.id = NEW.execution_id
                      AND candidate.state = 'reviewed'
                      AND candidate.packet_id = NEW.packet_id
                      AND candidate.matter_id = NEW.matter_id
                      AND candidate.research_session_id = NEW.research_session_id
                      AND candidate.research_query_id = NEW.research_query_id
                      AND candidate.provider_id = NEW.provider_id
                      AND candidate.egress_grant_id = NEW.egress_grant_id
                      AND candidate.egress_grant_version = NEW.egress_grant_version
                      AND candidate.exact_query_sha256 = NEW.exact_query_sha256
                      AND candidate.source_digest_sha256 = NEW.source_digest_sha256
                      AND candidate.review_digest_sha256 = NEW.review_digest_sha256
                      AND candidate.reviewer_id = NEW.reviewer_id
                      AND candidate.reviewer_action = NEW.reviewer_action
                )
                BEGIN SELECT RAISE(ABORT, 'accepted packet does not match review'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_source_insert_guard
                BEFORE INSERT ON accepted_research_packet_sources
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS version
                    JOIN research_packet_candidate_sources AS source
                      ON source.execution_id = version.execution_id
                     AND source.source_index = NEW.source_index
                    WHERE version.id = NEW.packet_version_id
                      AND source.research_result_id = NEW.research_result_id
                      AND source.provider_result_id = NEW.provider_result_id
                      AND source.authority_id = NEW.authority_id
                      AND source.ground_key = NEW.ground_key
                      AND source.excerpt = NEW.excerpt
                      AND source.excerpt_sha256 = NEW.excerpt_sha256
                      AND source.reviewed_proposition_binding_sha256
                          = NEW.reviewed_proposition_binding_sha256
                )
                BEGIN SELECT RAISE(ABORT, 'accepted packet source does not match review'); END
                """)

            for (name, table) in [
                ("version", "accepted_research_packet_versions"),
                ("source", "accepted_research_packet_sources"),
                ("receipt", "research_packet_acceptance_receipts"),
                ("disposition", "research_packet_version_dispositions"),
                ("work_product_binding", "research_packet_work_product_bindings"),
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER accepted_research_packet_\(name)_update_guard
                    BEFORE UPDATE ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'accepted research packet ledger is immutable'); END
                    """)
            }
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_version_delete_guard
                BEFORE DELETE ON accepted_research_packet_versions
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'accepted research packet is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_source_delete_guard
                BEFORE DELETE ON accepted_research_packet_sources
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'accepted research source is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_receipt_delete_guard
                BEFORE DELETE ON research_packet_acceptance_receipts
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.accepted_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet receipt is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_disposition_insert_guard
                BEFORE INSERT ON research_packet_version_dispositions
                WHEN NEW.kind = 'superseded' AND NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS prior
                    JOIN accepted_research_packet_versions AS replacement
                      ON replacement.id = NEW.replacement_packet_version_id
                    WHERE prior.id = NEW.packet_version_id
                      AND replacement.packet_id = prior.packet_id
                )
                BEGIN SELECT RAISE(ABORT, 'packet supersession must remain in packet'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_disposition_delete_guard
                BEFORE DELETE ON research_packet_version_dispositions
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet disposition is append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_work_product_insert_guard
                BEFORE INSERT ON research_packet_work_product_bindings
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS packet
                    JOIN structured_output_versions AS output_version
                      ON output_version.id = NEW.structured_output_version_id
                    JOIN structured_outputs AS output
                      ON output.id = output_version.structured_output_id
                    WHERE packet.id = NEW.packet_version_id
                      AND packet.aggregate_digest_sha256
                          = NEW.packet_aggregate_digest_sha256
                      AND output.matter_id = packet.matter_id
                      AND output.deleted_at IS NULL
                )
                BEGIN SELECT RAISE(ABORT, 'invalid accepted packet work-product binding'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_work_product_delete_guard
                BEFORE DELETE ON research_packet_work_product_bindings
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet binding is immutable'); END
                """)
        }

        migrator.registerMigration("v078_govern_structured_work_publication") { db in
            // A successful provider response yields only content-free receipt
            // provenance. Store registration is spent transactionally by one
            // research packet execution; query and matter bodies are never
            // retained here.
            try db.execute(sql: """
                CREATE TABLE research_packet_egress_consumptions (
                    receipt_id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(receipt_id)) > 0),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    grant_version INTEGER NOT NULL CHECK (
                        typeof(grant_version) = 'integer' AND grant_version > 0
                    ),
                    origin TEXT NOT NULL CHECK (
                        origin IN ('formalResearch', 'quickResearch')
                    ),
                    matter_id TEXT,
                    research_session_id TEXT,
                    classification TEXT NOT NULL CHECK (
                        classification IN (
                            'publicCitation', 'userApprovedQuery',
                            'matterDerived', 'unknown'
                        )
                    ),
                    query_sha256 TEXT NOT NULL CHECK (
                        length(query_sha256) = 64
                        AND query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    binding_digest_sha256 TEXT NOT NULL CHECK (
                        length(binding_digest_sha256) = 64
                        AND binding_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    registered_at DATETIME NOT NULL,
                    used_by_execution_id TEXT UNIQUE,
                    used_at DATETIME,
                    CHECK (
                        (used_by_execution_id IS NULL AND used_at IS NULL)
                        OR (length(trim(used_by_execution_id)) > 0 AND used_at IS NOT NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (used_by_execution_id)
                        REFERENCES research_packet_candidates(id)
                        DEFERRABLE INITIALLY DEFERRED
                )
                """)
            try db.create(
                index: "idx_research_packet_egress_consumptions_scope",
                on: "research_packet_egress_consumptions",
                columns: ["matter_id", "research_session_id", "registered_at", "receipt_id"]
            )
            try db.execute(sql: """
                CREATE TRIGGER research_packet_egress_consumption_update_guard
                BEFORE UPDATE ON research_packet_egress_consumptions
                WHEN NOT (
                    OLD.used_by_execution_id IS NULL
                    AND OLD.used_at IS NULL
                    AND length(trim(NEW.used_by_execution_id)) > 0
                    AND NEW.used_at IS NOT NULL
                    AND NEW.receipt_id = OLD.receipt_id
                    AND NEW.request_digest_sha256 = OLD.request_digest_sha256
                    AND NEW.provider_id = OLD.provider_id
                    AND NEW.grant_version = OLD.grant_version
                    AND NEW.origin = OLD.origin
                    AND NEW.matter_id IS OLD.matter_id
                    AND NEW.research_session_id IS OLD.research_session_id
                    AND NEW.classification = OLD.classification
                    AND NEW.query_sha256 = OLD.query_sha256
                    AND NEW.binding_digest_sha256 = OLD.binding_digest_sha256
                    AND NEW.registered_at = OLD.registered_at
                )
                BEGIN
                    SELECT RAISE(ABORT, 'egress consumption registration is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_egress_consumption_delete_guard
                BEFORE DELETE ON research_packet_egress_consumptions
                WHEN OLD.matter_id IS NULL OR EXISTS (
                    SELECT 1 FROM matters WHERE id = OLD.matter_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'egress consumption registration is immutable');
                END
                """)

            // One receipt terminates the complete publication aggregate: output,
            // source packet, generation, version, accepted-packet binding, audit,
            // and active selection all commit or roll back with this final row.
            try db.execute(sql: """
                CREATE TABLE structured_work_product_publications (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    publication_mode TEXT NOT NULL CHECK (
                        publication_mode IN (
                            'ordinary', 'governed_authority',
                            'provisional_issue_outline'
                        )
                    ),
                    matter_id TEXT NOT NULL,
                    structured_output_id TEXT NOT NULL,
                    structured_output_version_id TEXT NOT NULL UNIQUE,
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index > 0
                    ),
                    source_set_id TEXT NOT NULL UNIQUE,
                    generation_session_id TEXT NOT NULL UNIQUE,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    aggregate_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(aggregate_digest_sha256) = 64
                        AND aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    accepted_packet_version_id TEXT,
                    accepted_packet_version_index INTEGER,
                    accepted_packet_aggregate_digest_sha256 TEXT,
                    created_at DATETIME NOT NULL,
                    CHECK (
                        (publication_mode = 'governed_authority'
                            AND length(trim(accepted_packet_version_id)) > 0
                            AND accepted_packet_version_index > 0
                            AND length(accepted_packet_aggregate_digest_sha256) = 64
                            AND accepted_packet_aggregate_digest_sha256
                                NOT GLOB '*[^0-9a-f]*')
                        OR (publication_mode <> 'governed_authority'
                            AND accepted_packet_version_id IS NULL
                            AND accepted_packet_version_index IS NULL
                            AND accepted_packet_aggregate_digest_sha256 IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (structured_output_id)
                        REFERENCES structured_outputs(id) ON DELETE CASCADE,
                    FOREIGN KEY (structured_output_version_id)
                        REFERENCES structured_output_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (source_set_id)
                        REFERENCES document_source_sets(id) ON DELETE CASCADE,
                    FOREIGN KEY (generation_session_id)
                        REFERENCES generation_sessions(id),
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id),
                    FOREIGN KEY (accepted_packet_version_id)
                        REFERENCES accepted_research_packet_versions(id)
                )
                """)
            try db.create(
                index: "idx_structured_work_publications_matter",
                on: "structured_work_product_publications",
                columns: ["matter_id", "created_at", "idempotency_key"]
            )
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_insert_guard
                BEFORE INSERT ON structured_work_product_publications
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM structured_outputs AS output
                    JOIN structured_output_versions AS version
                      ON version.id = NEW.structured_output_version_id
                     AND version.structured_output_id = output.id
                    JOIN document_source_sets AS source_set
                      ON source_set.id = NEW.source_set_id
                     AND source_set.structured_output_version_id = version.id
                     AND source_set.matter_id = NEW.matter_id
                     AND source_set.status = 'attached'
                    JOIN generation_sessions AS generation
                      ON generation.id = NEW.generation_session_id
                     AND generation.id = version.generation_session_id
                     AND generation.status = 'completed'
                    JOIN audit_events AS audit
                      ON audit.id = NEW.audit_event_id
                     AND audit.event_type = 'structured_work_product_published'
                     AND audit.matter_id = NEW.matter_id
                     AND audit.related_table = 'structured_outputs'
                     AND audit.related_id = output.id
                    WHERE output.id = NEW.structured_output_id
                      AND output.matter_id = NEW.matter_id
                      AND output.deleted_at IS NULL
                      AND output.active_version_id = version.id
                      AND version.version_index = NEW.version_index
                ) OR (
                    NEW.publication_mode = 'governed_authority'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM accepted_research_packet_versions AS packet
                        JOIN research_packet_work_product_bindings AS binding
                          ON binding.packet_version_id = packet.id
                         AND binding.structured_output_version_id
                            = NEW.structured_output_version_id
                        WHERE packet.id = NEW.accepted_packet_version_id
                          AND packet.version_index = NEW.accepted_packet_version_index
                          AND packet.aggregate_digest_sha256
                            = NEW.accepted_packet_aggregate_digest_sha256
                          AND binding.packet_aggregate_digest_sha256
                            = NEW.accepted_packet_aggregate_digest_sha256
                          AND packet.matter_id = NEW.matter_id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM research_packet_version_dispositions AS disposition
                              WHERE disposition.packet_version_id = packet.id
                                AND disposition.kind = 'revoked'
                          )
                    )
                ) OR (
                    NEW.publication_mode <> 'governed_authority'
                    AND EXISTS (
                        SELECT 1 FROM research_packet_work_product_bindings
                        WHERE structured_output_version_id
                            = NEW.structured_output_version_id
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'incomplete structured work publication aggregate');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_update_guard
                BEFORE UPDATE ON structured_work_product_publications
                BEGIN
                    SELECT RAISE(ABORT, 'structured work publication is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_delete_guard
                BEFORE DELETE ON structured_work_product_publications
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN
                    SELECT RAISE(ABORT, 'structured work publication is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_version_insert_guard
                BEFORE INSERT ON structured_output_versions
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE structured_output_id = NEW.structured_output_id
                      AND publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be promoted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_output_update_guard
                BEFORE UPDATE OF active_version_id, status ON structured_outputs
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE structured_output_id = OLD.id
                      AND publication_mode = 'provisional_issue_outline'
                ) AND (
                    NEW.active_version_id IS NOT OLD.active_version_id
                    OR NEW.status <> 'needs_review'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be promoted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_export_insert_guard
                BEFORE INSERT ON document_exports
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE (
                        structured_output_id = NEW.structured_output_id
                        OR structured_output_version_id
                            = NEW.structured_output_version_id
                    )
                      AND publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be exported');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_binding_insert_guard
                BEFORE INSERT ON research_packet_work_product_bindings
                WHEN EXISTS (
                    SELECT 1
                    FROM structured_work_product_publications AS publication
                    JOIN structured_output_versions AS version
                      ON version.structured_output_id = publication.structured_output_id
                    WHERE version.id = NEW.structured_output_version_id
                      AND publication.publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot bind authority');
                END
                """)
        }

        return migrator
    }

    private struct RelationBackfillDocument: Sendable {
        var id: String
        var matterID: String
        var blobID: String
        var createdAt: Date
    }

    private struct RelationBackfillGroupKey: Hashable {
        var matterID: String
        var value: String
    }

    /// v065 backfill is intentionally deterministic and proposal-only. It uses
    /// the same SHA-256 text key as retrieval duplicate collapse, but hashes the
    /// complete ordered chunk text for each document instance.
    private static func backfillDocumentRelations(_ db: Database) throws {
        let documents = try Row.fetchAll(
            db,
            sql: """
            SELECT id, matter_id, blob_id, created_at
            FROM matter_documents
            WHERE deleted_at IS NULL
            ORDER BY matter_id, id
            """
        ).map { row in
            RelationBackfillDocument(
                id: row["id"],
                matterID: row["matter_id"],
                blobID: row["blob_id"],
                createdAt: row["created_at"]
            )
        }
        let documentByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        let exactGroups = Dictionary(grouping: documents) {
            RelationBackfillGroupKey(matterID: $0.matterID, value: $0.blobID)
        }
        for key in exactGroups.keys.sorted(by: backfillGroupLessThan) {
            let group = exactGroups[key, default: []].sorted { $0.id < $1.id }
            for (from, to) in relationPairs(group) {
                try insertBackfillRelation(
                    db,
                    matterID: key.matterID,
                    from: from,
                    to: to,
                    kind: .exactDuplicate,
                    evidence: [
                        "basis": "shared_blob",
                        "blob_id": key.value,
                        "schema_version": 1,
                    ]
                )
            }
        }

        let chunkRows = try Row.fetchAll(
            db,
            sql: """
            SELECT d.id AS document_id, c.normalized_text
            FROM matter_documents d
            JOIN document_chunks c ON c.document_id = d.id
            WHERE d.deleted_at IS NULL
            ORDER BY d.matter_id, d.id, c.chunk_index, c.id
            """
        )
        var chunkTextsByDocumentID: [String: [String]] = [:]
        for row in chunkRows {
            let documentID: String = row["document_id"]
            let text: String = row["normalized_text"]
            chunkTextsByDocumentID[documentID, default: []].append(text)
        }
        var normalizedGroups: [RelationBackfillGroupKey: [RelationBackfillDocument]] = [:]
        for (documentID, chunkTexts) in chunkTextsByDocumentID {
            guard let document = documentByID[documentID] else { continue }
            let fullText = chunkTexts.joined(separator: "\n\n")
            guard !fullText.isEmpty else { continue }
            let digest = SHA256.hash(data: Data(fullText.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            normalizedGroups[
                RelationBackfillGroupKey(matterID: document.matterID, value: digest),
                default: []
            ].append(document)
        }
        for key in normalizedGroups.keys.sorted(by: backfillGroupLessThan) {
            let group = normalizedGroups[key, default: []].sorted { $0.id < $1.id }
            for (from, to) in relationPairs(group) where from.blobID != to.blobID {
                try insertBackfillRelation(
                    db,
                    matterID: key.matterID,
                    from: from,
                    to: to,
                    kind: .normalizedDuplicate,
                    evidence: [
                        "basis": "normalized_text_digest",
                        "digest": key.value,
                        "schema_version": 1,
                    ]
                )
            }
        }
    }

    private static func insertBackfillRelation(
        _ db: Database,
        matterID: String,
        from: RelationBackfillDocument,
        to: RelationBackfillDocument,
        kind: DocumentRelationKind,
        evidence: [String: Any]
    ) throws {
        let ordered = [from, to].sorted { $0.id < $1.id }
        let relationKey = "\(ordered[0].id)|\(ordered[1].id)"
        let identity = "\(matterID)|\(relationKey)|\(kind.rawValue)"
        let id = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let evidenceData = try JSONSerialization.data(
            withJSONObject: evidence,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO document_relations (
                id, matter_id, relation_key, from_document_id, to_document_id,
                kind, evidence_json, confidence, proposed_by, review_state, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1.0, 'system', 'proposed', ?)
            """,
            arguments: [
                id,
                matterID,
                relationKey,
                ordered[0].id,
                ordered[1].id,
                kind.rawValue,
                String(decoding: evidenceData, as: UTF8.self),
                max(from.createdAt, to.createdAt),
            ]
        )
    }

    private static func relationPairs<T>(_ values: [T]) -> [(T, T)] {
        guard values.count > 1 else { return [] }
        return values.indices.flatMap { firstIndex in
            values.indices.compactMap { secondIndex in
                guard secondIndex > firstIndex else { return nil }
                return (values[firstIndex], values[secondIndex])
            }
        }
    }

    private static func backfillGroupLessThan(
        _ lhs: RelationBackfillGroupKey,
        _ rhs: RelationBackfillGroupKey
    ) -> Bool {
        (lhs.matterID, lhs.value) < (rhs.matterID, rhs.value)
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
