import Foundation
import GRDB

public enum SupraMigrator {
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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
                table.column("entry_id", .text).references("scratch_pad_entries", onDelete: .setNull)
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

        return migrator
    }

    #if DEBUG
    public static func deleteAllTables(_ db: Database) throws {
        for table in [
            // Milestone 4 ScratchPad / billing tables: drop children before parents.
            "billing_line_items",
            "billing_drafts",
            "scratch_pad_attachments",
            "scratch_pad_entries",
            "scratch_pad_days",
            "matter_billing_profiles",
            // Milestone 3 document intelligence tables: drop children before parents.
            "document_exports",
            "document_output_sources",
            "document_source_sets",
            "document_processing_jobs",
            "document_import_batches",
            "document_chunk_embeddings",
            "document_embedding_models",
            "document_chunk_fts",
            "document_chunks",
            "document_pages_parts",
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
