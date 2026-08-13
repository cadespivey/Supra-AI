import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Standing compatibility guards for WP-1.5 Case File Review retirement.
///
/// These tests intentionally keep the already-shared v073 migration while the
/// product capability is removed. They do not use CaseFileReviewRepository,
/// Review record types, or any other feature API that retirement will delete.
final class ArchitectureUXReviewRetirementSchemaTests: XCTestCase {
    func testRRSchema01V072AndV073SourceClosuresRemainByteIdenticalAndOrdered() throws {
        // Standing guard: the intended pre-retirement result is GREEN. The
        // separate public-capability retirement gate owns the observable RED.
        // This test must fail if implementation work rewrites shared migration
        // history or removes the exact DEBUG reset compatibility entries.
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/SupraStore/Database/SupraMigrator.swift")
        let sourceData = try Data(contentsOf: sourceURL)
        let source = try XCTUnwrap(String(data: sourceData, encoding: .utf8))

        let v072Anchor =
            #"        migrator.registerMigration("v072_harden_corpus_review_integrity") { db in"#
        let v073Anchor =
            #"        migrator.registerMigration("v073_create_case_file_review_projects") { db in"#
        let returnAnchor = "        return migrator"
        let resetAnchor =
            "            // Case File Review: children before project/matter ownership."
        let resetEndAnchor =
            "            // Draft artifact intents are children of matters and must be gone"

        let v072Start = try XCTUnwrap(source.range(of: v072Anchor)?.lowerBound)
        let v073Start = try XCTUnwrap(source.range(of: v073Anchor)?.lowerBound)
        let migratorReturn = try XCTUnwrap(source.range(of: returnAnchor)?.lowerBound)
        let resetStart = try XCTUnwrap(source.range(of: resetAnchor)?.lowerBound)
        let resetEnd = try XCTUnwrap(source.range(of: resetEndAnchor)?.lowerBound)

        XCTAssertLessThan(v072Start, v073Start)
        XCTAssertLessThan(v073Start, migratorReturn)
        XCTAssertLessThan(migratorReturn, resetStart)
        XCTAssertLessThan(resetStart, resetEnd)

        let v072WithSeparator = source[v072Start..<v073Start]
        let v073WithSeparator = source[v073Start..<migratorReturn]
        let orderedWithSeparator = source[v072Start..<migratorReturn]
        XCTAssertTrue(v072WithSeparator.hasSuffix("\n\n"))
        XCTAssertTrue(v073WithSeparator.hasSuffix("\n\n"))
        XCTAssertTrue(orderedWithSeparator.hasSuffix("\n\n"))

        // Keep the newline terminating each registration's closing brace, but
        // exclude the one blank separator line. This is the exact byte-slice
        // definition used to freeze the hashes below.
        let v072 = Data(v072WithSeparator.dropLast().utf8)
        let v073 = Data(v073WithSeparator.dropLast().utf8)
        let ordered = Data(orderedWithSeparator.dropLast().utf8)
        let resetEntries = Data(source[resetStart..<resetEnd].utf8)

        XCTAssertEqual(v072.count, 110_753)
        XCTAssertEqual(v072.filter { $0 == 0x0a }.count, 1_924)
        XCTAssertEqual(
            sha256(v072),
            "239d5a4a1c6ad610366446c14709682b87ede15b47e4aa7535d0d901851553e6"
        )
        XCTAssertEqual(v073.count, 18_728)
        XCTAssertEqual(v073.filter { $0 == 0x0a }.count, 365)
        XCTAssertEqual(
            sha256(v073),
            "819515bfe405e1459adbbce65288754f241b94239543fe077793c624f4c4d14f"
        )
        XCTAssertEqual(
            sha256(ordered),
            "c06998aa1c98b1b91840d8938c2c4e177c31c48fd3718fb662da30c024814811"
        )
        XCTAssertEqual(
            sha256(resetEntries),
            "93a75b7fb141dc79698ea3ee42f132784b3cd81020302b5b3670a3f18ad8e1ee"
        )

        let migrations = SupraMigrator.makeMigrator().migrations
        XCTAssertEqual(migrations.count, 73)
        XCTAssertEqual(Array(migrations.suffix(5)), [
            "v069_add_verification_dimensions",
            "v070_add_authority_reviewed_proposition",
            "v071_create_draft_artifact_intents",
            "v072_harden_corpus_review_integrity",
            "v073_create_case_file_review_projects",
        ])
        XCTAssertEqual(
            sha256(linesData(migrations)),
            "004b49c67d96e2420b1a222e88c2c8c2e6f8fe04f38b2566baa79bd7aca3f130"
        )
        XCTAssertEqual(
            sha256(linesData(Array(migrations.suffix(5)))),
            "e49b082bd34027881c6faa733a53b330a334b0608732999fb34ae807c8e0ad69"
        )

        // v072 embeds these persisted raw values into its data upgrade. Freeze
        // their resolved semantics without preventing unrelated future enum
        // cases from being appended for later migrations.
        let rawValueClosure = [
            "OutputAssuranceState.stale=\(OutputAssuranceState.stale.rawValue)",
            "OutputAssuranceState.corpusComplete=\(OutputAssuranceState.corpusComplete.rawValue)",
            "OutputAssuranceState.propositionSupported=\(OutputAssuranceState.propositionSupported.rawValue)",
            "CorpusAnalysisTaskKind.exhaustiveList=\(CorpusAnalysisTaskKind.exhaustiveList.rawValue)",
            "StructuredOutputStatus.needsReview=\(StructuredOutputStatus.needsReview.rawValue)",
        ]
        XCTAssertEqual(
            sha256(linesData(rawValueClosure)),
            "07032aa97ebc38df26a12d3249741a11ed986cbf473c11e1ed0c5115a29c710f"
        )
    }

    func testRRSchema02DormantV073RowSurvivesFileBackedFinalOpenAndReopen() throws {
        // Standing guard expected GREEN before feature removal. It proves an
        // already-main database remains openable after the Review repository and
        // records are gone; all Review compatibility work below is raw SQL.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-SCHEMA-02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let migrator = SupraMigrator.makeMigrator()

        let expectedProjectDigest: String
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try migrator.migrate(queue, upTo: "v073_create_case_file_review_projects")
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO matters (
                            id, name, jurisdiction, party_perspective,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        Wire.matterID,
                        Wire.matterName,
                        "Synthetic District 731",
                        "plaintiff",
                        Wire.timestamp,
                        Wire.timestamp,
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO case_file_review_projects (
                            id, matter_id, title, status, stale_reason,
                            source_run_id, source_output_id, source_output_version_id,
                            source_request_digest, frozen_scope_json,
                            frozen_corpus_snapshot_json, frozen_reconciliation_json,
                            active_table_id, created_at, updated_at
                        ) VALUES (?, ?, ?, 'active', NULL, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                        """,
                    arguments: [
                        Wire.projectID,
                        Wire.matterID,
                        Wire.projectTitle,
                        Wire.runID,
                        Wire.outputID,
                        Wire.outputVersionID,
                        Wire.requestDigest,
                        Wire.scopeJSON,
                        Wire.snapshotJSON,
                        Wire.reconciliationJSON,
                        Wire.timestamp,
                        Wire.timestamp,
                    ]
                )
            }
            try assertHealthyDormantCompatibilityState(queue, migrator: migrator)
            expectedProjectDigest = try dormantProjectDigest(queue)
        }

        for reopenIndex in 1...2 {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try migrator.migrate(queue)
            try assertHealthyDormantCompatibilityState(queue, migrator: migrator)
            XCTAssertEqual(
                try dormantProjectDigest(queue),
                expectedProjectDigest,
                "reopen \(reopenIndex) must not rewrite or discard the dormant v073 row"
            )
        }
    }

    // TODO(WP-1.5 process evidence): the authenticated public v069 fixture has
    // no matter/document/output/audit business rows, and this source-only slice
    // must not impersonate the owner's observed v072 profile. Add a separately
    // authenticated rich synthetic v069 fixture and run the verified owner-v072
    // copy through restore/open/reopen before any ordinary-profile launch. That
    // evidence must cover managed-document files and selected content digests;
    // it is not satisfied by constructing another current-migrator database here.

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraStoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraStore
    }

    private func assertHealthyDormantCompatibilityState(
        _ queue: DatabaseQueue,
        migrator: DatabaseMigrator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                "ok",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ),
                migrator.migrations,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT name FROM matters WHERE id = ?",
                    arguments: [Wire.matterID]
                ),
                Wire.matterName,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM case_file_review_projects WHERE id = ?",
                    arguments: [Wire.projectID]
                ),
                1,
                file: file,
                line: line
            )

            let reviewTables = [
                "case_file_review_projects",
                "case_file_review_tables",
                "case_file_review_columns",
                "case_file_review_rows",
                "case_file_review_cells",
                "case_file_review_cell_generations",
                "case_file_review_evidence_edges",
            ]
            for table in reviewTables {
                XCTAssertTrue(try db.tableExists(table), file: file, line: line)
            }
            for emptyChild in reviewTables.dropFirst() {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(emptyChild)"),
                    0,
                    "v073 must not fabricate child data in \(emptyChild)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func dormantProjectDigest(_ queue: DatabaseQueue) throws -> String {
        try queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT id, matter_id, title, status, stale_reason,
                           source_run_id, source_output_id, source_output_version_id,
                           source_request_digest, frozen_scope_json,
                           frozen_corpus_snapshot_json, frozen_reconciliation_json,
                           active_table_id, CAST(created_at AS TEXT) AS created_at_text,
                           CAST(updated_at AS TEXT) AS updated_at_text
                    FROM case_file_review_projects
                    WHERE id = ?
                    """,
                arguments: [Wire.projectID]
            ))
            let values = [
                row["id"] as String,
                row["matter_id"] as String,
                row["title"] as String,
                row["status"] as String,
                (row["stale_reason"] as String?) ?? "<NULL>",
                row["source_run_id"] as String,
                row["source_output_id"] as String,
                row["source_output_version_id"] as String,
                row["source_request_digest"] as String,
                row["frozen_scope_json"] as String,
                row["frozen_corpus_snapshot_json"] as String,
                row["frozen_reconciliation_json"] as String,
                (row["active_table_id"] as String?) ?? "<NULL>",
                row["created_at_text"] as String,
                row["updated_at_text"] as String,
            ]
            XCTAssertEqual(values[0], Wire.projectID)
            XCTAssertEqual(values[2], Wire.projectTitle)
            XCTAssertEqual(values[7], Wire.outputVersionID)
            XCTAssertEqual(values[10], Wire.snapshotJSON)
            XCTAssertFalse(values.contains("DEFAULT-000"))
            return sha256(Data(values.joined(separator: "\u{1f}").utf8))
        }
    }

    private func linesData(_ values: [String]) -> Data {
        Data((values.joined(separator: "\n") + "\n").utf8)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum Wire {
    static let matterID = "rr-schema-matter-713"
    static let matterName = "Synthetic Dormant Compatibility Matter 731"
    static let projectID = "rr-schema-project-719"
    static let projectTitle = "Dormant Compatibility Project 727"
    static let runID = "rr-schema-run-733"
    static let outputID = "rr-schema-output-739"
    static let outputVersionID = "rr-schema-version-743"
    static let requestDigest = String(repeating: "7", count: 64)
    static let scopeJSON = #"{"schema_version":7,"matter_id":"rr-schema-matter-713"}"#
    static let snapshotJSON =
        #"{"members":[{"document_id":"synthetic-document-751","revision_id":"synthetic-revision-757"}],"schema_version":7}"#
    static let reconciliationJSON =
        #"{"excluded_members":[],"included_count":1,"schema_version":7}"#
    static let timestamp = "2026-08-13T19:27:31Z"
}
