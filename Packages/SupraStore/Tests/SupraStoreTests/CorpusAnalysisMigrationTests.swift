import Foundation
import GRDB
@testable import SupraStore
import XCTest

final class CorpusAnalysisMigrationTests: XCTestCase {
    func testTMIG06V064CreatesCoverageLedgerWithoutFabricatingRuns() throws {
        // T-MIG-06 expected RED: v064 and both corpus-analysis tables do not exist.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v064_create_corpus_analysis_ledger"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v063_add_chunk_structure_binding")

        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic v063 history")
        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v067_add_output_generation_lineage")
            XCTAssertEqual(Set(try db.columns(in: "corpus_analysis_runs").map(\.name)), Set([
                "id", "run_key", "matter_id", "task_kind", "scope_json",
                "corpus_snapshot_json", "partition_strategy", "partition_strategy_version",
                "model_lineage_json", "status", "coverage_json", "reconciliation_json",
                "validation_results_json", "assurance_state", "assurance_reasons_json",
                "structured_output_version_id", "created_at", "completed_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "corpus_analysis_partitions").map(\.name)), Set([
                "id", "run_id", "partition_key", "input_revision_ids_json", "attempt_count",
                "attempt_history_json", "disposition", "disposition_reason", "findings_json",
                "error_summary", "started_at", "completed_at",
            ]))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_runs WHERE matter_id = ?", arguments: [matter.id]),
                0,
                "v064 is create-only and must not synthesize historical runs"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT dflt_value FROM pragma_table_info('corpus_analysis_partitions') WHERE name = 'attempt_history_json'"
                ),
                "'[]'"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT dflt_value FROM pragma_table_info('corpus_analysis_partitions') WHERE name = 'disposition'"
                ),
                "'pending'"
            )

            let runForeignKeys = try foreignKeyContracts(db, table: "corpus_analysis_runs")
            XCTAssertEqual(runForeignKeys, Set([
                "matter_id->matters:CASCADE",
                "structured_output_version_id->structured_output_versions:SET NULL",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "corpus_analysis_partitions"), Set([
                "run_id->corpus_analysis_runs:CASCADE",
            ]))

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT \"unique\" FROM pragma_index_list('corpus_analysis_runs') WHERE name = 'idx_corpus_analysis_runs_matter_key'"
                ),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT \"unique\" FROM pragma_index_list('corpus_analysis_partitions') WHERE name = 'idx_corpus_analysis_partitions_run_key'"
                ),
                1
            )
        }
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    private func foreignKeyContracts(_ db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").map { row in
            "\(row["from"] as String)->\(row["table"] as String):\(row["on_delete"] as String)"
        })
    }
}
