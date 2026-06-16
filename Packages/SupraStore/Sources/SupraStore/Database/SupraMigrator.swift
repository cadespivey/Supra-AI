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

        return migrator
    }

    #if DEBUG
    public static func deleteAllTables(_ db: Database) throws {
        for table in [
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
