import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationsV022ThroughV040(_ migrator: inout DatabaseMigrator) {
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
    }
}
