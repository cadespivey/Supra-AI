import CryptoKit
import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// T-MIGRATION-01 — immutable migration registration can be split mechanically
/// only while the exact catalog and resulting SQLite schema remain unchanged.
final class ArchitectureUXTMigration01Tests: XCTestCase {
    private enum Wire {
        static let marker = "T_MIGRATION_01_WIRE_731"
        static let forbiddenDefault = "DEFAULT-000"
        static let expectedCount = 78
        static let nextVersion = 79
    }

    func testRegistrationCatalogMatchesFrozenV001ThroughV078Order() {
        // Standing pre-change parity guard: this is intentionally green in the
        // RED commit so the mechanical split cannot redefine its own baseline.
        let migrations = SupraMigrator.makeMigrator().migrations

        XCTAssertEqual(migrations, Self.expectedMigrations)
        XCTAssertEqual(migrations.count, Wire.expectedCount)
        XCTAssertEqual(migrations.first, "v001_create_app_settings")
        XCTAssertEqual(migrations.last, "v078_govern_structured_work_publication")
        XCTAssertNil(migrations.first { $0.hasPrefix("v0\(Wire.nextVersion)_") })
        XCTAssertFalse(migrations.contains(Wire.forbiddenDefault))
    }

    func testFreshCurrentSchemaMatchesFrozenPreSplitSnapshot() throws {
        // Standing pre-change parity guard frozen before any source move. Raw
        // whitespace is normalized, while every renderer-owned SQLite token,
        // object identity, index, and trigger remains digest-significant.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)

        let _: Void = try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT type, name, tbl_name, COALESCE(sql, '') AS sql
                FROM sqlite_master
                WHERE type IN ('table', 'index', 'trigger', 'view')
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY type, name, tbl_name, sql
                """
            )
            let canonical = rows.map(Self.canonicalSchemaLine).joined(separator: "\n")
            let counts = Dictionary(grouping: rows) { row -> String in row["type"] }
                .mapValues(\.count)

            XCTAssertEqual(counts, ["index": 101, "table": 82, "trigger": 89])
            XCTAssertEqual(canonical.utf8.count, 189_873)
            XCTAssertEqual(
                Self.sha256(canonical),
                "36acdbd50d93fd2f062ac82ad9aa50da3fa8166cd94c386e93eb4cedd11cc6a9"
            )
            XCTAssertFalse(canonical.contains(Wire.forbiddenDefault))
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0
            )
        }
    }

    func testRegistrationSourceIsMechanicallySplitIntoOrderedVersionFiles() throws {
        // Expected RED: all 78 closures still live in SupraMigrator.swift; none
        // of the eleven cohesive/versioned registration files or ordered calls
        // exists yet.
        let databaseRoot = Self.repositoryRoot.appendingPathComponent(
            "Packages/SupraStore/Sources/SupraStore/Database",
            isDirectory: true
        )
        let actualFiles = try FileManager.default.contentsOfDirectory(
            at: databaseRoot,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).filter {
            $0.hasPrefix("SupraMigration") && $0 != "SupraMigrator.swift"
        }.sorted()
        XCTAssertEqual(actualFiles, Self.expectedRegistrationFiles.sorted())

        let orchestrator = try String(
            contentsOf: databaseRoot.appendingPathComponent("SupraMigrator.swift"),
            encoding: .utf8
        )
        var cursor = orchestrator.startIndex
        for call in Self.expectedRegistrationCalls {
            let range = try XCTUnwrap(
                orchestrator.range(of: call, range: cursor..<orchestrator.endIndex),
                "Expected RED: missing ordered registration call \(call)"
            )
            cursor = range.upperBound
        }
        XCTAssertFalse(orchestrator.contains("migrator.registerMigration("))
        XCTAssertTrue(orchestrator.contains(Wire.marker))
        XCTAssertFalse(orchestrator.contains(Wire.forbiddenDefault))
    }

    private static let expectedRegistrationFiles = [
        "SupraMigrationV072.swift",
        "SupraMigrationV073.swift",
        "SupraMigrationV074.swift",
        "SupraMigrationV075.swift",
        "SupraMigrationV076.swift",
        "SupraMigrationV077.swift",
        "SupraMigrationV078.swift",
        "SupraMigrationsV001V021.swift",
        "SupraMigrationsV022V040.swift",
        "SupraMigrationsV041V060.swift",
        "SupraMigrationsV061V071.swift",
    ]

    private static let expectedRegistrationCalls = [
        "registerMigrationsV001ThroughV021(&migrator)",
        "registerMigrationsV022ThroughV040(&migrator)",
        "registerMigrationsV041ThroughV060(&migrator)",
        "registerMigrationsV061ThroughV071(&migrator)",
        "registerMigrationV072(&migrator)",
        "registerMigrationV073(&migrator)",
        "registerMigrationV074(&migrator)",
        "registerMigrationV075(&migrator)",
        "registerMigrationV076(&migrator)",
        "registerMigrationV077(&migrator)",
        "registerMigrationV078(&migrator)",
    ]

    private static let expectedMigrations = [
        "v001_create_app_settings",
        "v002_create_models",
        "v003_create_runtime_profiles",
        "v004_create_chats",
        "v005_create_messages",
        "v006_create_generation_sessions",
        "v007_create_message_variants",
        "v008_create_diagnostic_events",
        "v009_create_model_validation_runs",
        "v010_create_model_validation_tests",
        "v011_create_exported_reports",
        "v012_create_matters",
        "v013_enrich_matters",
        "v014_create_research_sessions",
        "v015_create_network_requests",
        "v016_create_research_queries",
        "v017_create_research_results",
        "v018_create_authorities",
        "v019_create_structured_outputs",
        "v020_create_output_versions",
        "v021_create_audit_events_phase2",
        "v022_create_document_intelligence_settings",
        "v023_create_document_blobs",
        "v024_create_document_folders",
        "v025_create_matter_documents",
        "v026_create_document_tags",
        "v027_create_document_tag_assignments",
        "v028_create_document_pages_parts",
        "v029_create_document_chunks",
        "v030_create_document_chunk_fts",
        "v031_create_document_embedding_models",
        "v032_create_document_chunk_embeddings",
        "v033_create_document_import_batches",
        "v034_create_document_processing_jobs",
        "v035_create_document_source_sets",
        "v036_create_document_output_sources",
        "v037_create_document_exports",
        "v038_add_matter_information_fields",
        "v039_add_document_classification_metadata",
        "v040_add_authority_soft_delete",
        "v041_create_scratch_pad_days",
        "v042_create_scratch_pad_entries",
        "v043_create_scratch_pad_attachments",
        "v044_create_billing_drafts",
        "v045_create_billing_line_items",
        "v046_create_matter_billing_profiles",
        "v047_add_matter_ledes_fields",
        "v048_add_billing_narrative_terminal",
        "v049_create_message_citations",
        "v050_add_source_set_retrieval_depth",
        "v051_add_authority_opinion_text",
        "v052_add_authority_case_summary",
        "v053_add_matter_sort_order",
        "v054_add_matter_pinned_at",
        "v055_add_output_verification_provenance",
        "v056_add_document_blob_integrity",
        "v057_add_remediation_recovery_queue",
        "v058_add_document_job_kind",
        "v059_create_document_import_sources",
        "v060_create_document_part_lineage",
        "v061_bind_document_output_source_revisions",
        "v062_create_document_structure",
        "v063_add_chunk_structure_binding",
        "v064_create_corpus_analysis_ledger",
        "v065_create_document_relations",
        "v066_add_document_source_lineage",
        "v067_add_output_generation_lineage",
        "v068_add_document_classification_lineage",
        "v069_add_verification_dimensions",
        "v070_add_authority_reviewed_proposition",
        "v071_create_draft_artifact_intents",
        "v072_harden_corpus_review_integrity",
        "v073_create_case_file_review_projects",
        "v074_create_canonical_matter_identity",
        "v075_create_grounded_chat_publications",
        "v076_link_export_publication_intents",
        "v077_create_accepted_research_packets",
        "v078_govern_structured_work_publication",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func canonicalSchemaLine(_ row: Row) -> String {
        let type: String = row["type"]
        let name: String = row["name"]
        let table: String = row["tbl_name"]
        let sql: String = row["sql"]
        let normalizedSQL = sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "\(type)|\(name)|\(table)|\(normalizedSQL)"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
