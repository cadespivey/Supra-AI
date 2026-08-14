import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Standing compatibility guards for WP-1.5 Case File Review retirement.
///
/// These tests intentionally keep the already-shared v073 migration while the
/// product capability is removed. They use no retired repository, record, or
/// export type that the feature retirement deletes.
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
        let v074Anchor =
            #"        migrator.registerMigration("v074_create_canonical_matter_identity") { db in"#
        let v075Anchor =
            #"        migrator.registerMigration("v075_create_grounded_chat_publications") { db in"#
        let returnAnchor = "        return migrator"
        let resetAnchor =
            "            // Case File Review: children before project/matter ownership."
        let resetEndAnchor =
            "            // Draft artifact intents are children of matters and must be gone"

        let v072Start = try XCTUnwrap(source.range(of: v072Anchor)?.lowerBound)
        let v073Start = try XCTUnwrap(source.range(of: v073Anchor)?.lowerBound)
        let v074Start = try XCTUnwrap(source.range(of: v074Anchor)?.lowerBound)
        let v075Start = try XCTUnwrap(source.range(of: v075Anchor)?.lowerBound)
        let migratorReturn = try XCTUnwrap(source.range(of: returnAnchor)?.lowerBound)
        let resetStart = try XCTUnwrap(source.range(of: resetAnchor)?.lowerBound)
        let resetEnd = try XCTUnwrap(source.range(of: resetEndAnchor)?.lowerBound)

        XCTAssertLessThan(v072Start, v073Start)
        XCTAssertLessThan(v073Start, v074Start)
        XCTAssertLessThan(v074Start, v075Start)
        XCTAssertLessThan(v075Start, migratorReturn)
        XCTAssertLessThan(migratorReturn, resetStart)
        XCTAssertLessThan(resetStart, resetEnd)

        let v072WithSeparator = source[v072Start..<v073Start]
        let v073WithSeparator = source[v073Start..<v074Start]
        let orderedWithSeparator = source[v072Start..<v074Start]
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
        XCTAssertEqual(migrations.count, 75)
        XCTAssertEqual(Array(migrations.suffix(7)), [
            "v069_add_verification_dimensions",
            "v070_add_authority_reviewed_proposition",
            "v071_create_draft_artifact_intents",
            "v072_harden_corpus_review_integrity",
            "v073_create_case_file_review_projects",
            "v074_create_canonical_matter_identity",
            "v075_create_grounded_chat_publications",
        ])
        XCTAssertEqual(
            sha256(linesData(migrations)),
            "1a69d1bf89e66a6c4cee1fb904666f91e62276d51c0c739d6b28d742ac2cfdd4"
        )
        XCTAssertEqual(
            sha256(linesData(Array(migrations.suffix(7)))),
            "67e0750d02af2de776151bf4fe37e5ba3fda6750aa77b955cdfe655c7a2637cc"
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
            try migrator.migrate(queue)
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

    func testRRSchema03DormantV073SchemaContractSurvivesWithoutFeatureAPI() throws {
        // Standing compatibility guard expected GREEN before and after product
        // retirement. It owns the persisted schema contract using raw SQL only.
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v072_harden_corpus_review_integrity")
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic dormant v073 compatibility matter"
        )

        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                "v075_create_grounded_chat_publications"
            )
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_projects").map(\.name)), Set([
                "id", "matter_id", "title", "status", "stale_reason", "source_run_id",
                "source_output_id", "source_output_version_id", "source_request_digest",
                "frozen_scope_json", "frozen_corpus_snapshot_json", "frozen_reconciliation_json",
                "active_table_id", "created_at", "updated_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_tables").map(\.name)), Set([
                "id", "project_id", "title", "version_index", "created_at", "updated_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_columns").map(\.name)), Set([
                "id", "table_id", "column_key", "title", "ordinal", "created_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_rows").map(\.name)), Set([
                "id", "table_id", "row_key", "ordinal", "created_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_cells").map(\.name)), Set([
                "id", "table_id", "row_id", "column_id", "current_generation_id",
                "attorney_value", "review_state", "value_state", "support_state",
                "reviewed_by", "reviewed_at", "created_at", "updated_at",
            ]))
            XCTAssertEqual(
                Set(try db.columns(in: "case_file_review_cell_generations").map(\.name)),
                Set([
                    "id", "cell_id", "generation_index", "source_run_id",
                    "generated_values_json", "created_at",
                ])
            )
            XCTAssertEqual(
                Set(try db.columns(in: "case_file_review_evidence_edges").map(\.name)),
                Set([
                    "id", "generation_id", "kind", "ordinal", "frozen_output_source_id",
                    "frozen_document_id", "frozen_revision_id", "frozen_document_name",
                    "citation_label", "char_start", "char_end", "locator_json", "excerpt",
                    "excerpt_sha256", "live_output_source_id", "live_document_id",
                    "live_revision_id", "availability", "unavailable_reason", "created_at",
                    "updated_at",
                ])
            )

            XCTAssertEqual(try foreignKeyContracts(db, table: "case_file_review_projects"), Set([
                "matter_id->matters:id:CASCADE",
                "active_table_id->case_file_review_tables:id:SET NULL",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "case_file_review_tables"), Set([
                "project_id->case_file_review_projects:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "case_file_review_columns"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "case_file_review_rows"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeyContracts(db, table: "case_file_review_cells"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
                "row_id,table_id->case_file_review_rows:id,table_id:CASCADE",
                "column_id,table_id->case_file_review_columns:id,table_id:CASCADE",
            ]))
            XCTAssertEqual(
                try foreignKeyContracts(db, table: "case_file_review_cell_generations"),
                Set(["cell_id->case_file_review_cells:id:CASCADE"])
            )
            XCTAssertEqual(
                try foreignKeyContracts(db, table: "case_file_review_evidence_edges"),
                Set([
                    "generation_id->case_file_review_cell_generations:id:CASCADE",
                    "live_output_source_id->document_output_sources:id:SET NULL",
                    "live_document_id->matter_documents:id:SET NULL",
                    "live_revision_id->document_part_revisions:id:SET NULL",
                ])
            )

            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_projects")
                    .contains(["source_output_version_id"])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_tables")
                    .contains(["project_id", "version_index"])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_columns")
                    .isSuperset(of: [
                        ["table_id", "column_key"], ["table_id", "ordinal"],
                        ["id", "table_id"],
                    ])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_rows")
                    .isSuperset(of: [
                        ["table_id", "row_key"], ["table_id", "ordinal"],
                        ["id", "table_id"],
                    ])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_cells")
                    .contains(["row_id", "column_id"])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_cell_generations")
                    .contains(["cell_id", "generation_index"])
            )
            XCTAssertTrue(
                try uniqueIndexColumnSets(db, table: "case_file_review_evidence_edges")
                    .contains(["generation_id", "kind", "ordinal"])
            )

            for table in dormantV073Tables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0,
                    "v073 must remain create-only for preexisting matter \(matter.id)"
                )
            }
        }
    }

    func testRRSchema04PermanentDocumentDeletionDegradesDormantV073Evidence() throws {
        // Standing compatibility guard: predecessor code already passed this
        // invariant through the retired repository hook. Retirement must keep
        // the ordinary document-deletion path usable without restoring any
        // public Review repository, record, controller, or rendering API.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Dormant evidence matter 811")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "rr-schema-blob-813",
            sha256: String(repeating: "8", count: 64),
            byteSize: 821,
            originalExtension: "txt",
            managedRelativePath: "documents/rr-schema-dormant-823.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: "rr-schema-document-827",
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Dormant source 829.txt"
        ))
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "rr-schema-revision-839",
            documentID: document.id,
            partIndex: 7,
            derivationKey: "rr-schema-derivation-853",
            origin: "parser",
            method: "synthetic_dormant_compatibility",
            text: "Dormant exact evidence 857",
            charCount: 26
        ))
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .guided,
            scopeJSON: #"{"document_ids":["rr-schema-document-827"],"schema_version":7}"#
        )
        let source = DocumentOutputSourceRecord(
            id: "rr-schema-source-859",
            sourceSetID: sourceSet.id,
            documentID: document.id,
            revisionID: revision.id,
            citationLabel: "S863",
            locatorJSON: #"{"char_end":26,"char_start":0,"part_index":7,"source_kind":"text"}"#,
            excerpt: "Dormant exact evidence 857",
            rank: 7
        )
        try store.documentSources.addOutputSource(source)

        let projectID = "rr-schema-project-877"
        let tableID = "rr-schema-table-881"
        let columnID = "rr-schema-column-883"
        let rowID = "rr-schema-row-887"
        let cellID = "rr-schema-cell-907"
        let generationID = "rr-schema-generation-911"
        let edgeID = "rr-schema-edge-919"
        let frozenDigest = String(repeating: "9", count: 64)
        try store.database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_projects (
                        id, matter_id, title, status, stale_reason,
                        source_run_id, source_output_id, source_output_version_id,
                        source_request_digest, frozen_scope_json,
                        frozen_corpus_snapshot_json, frozen_reconciliation_json,
                        active_table_id, created_at, updated_at
                    ) VALUES (?, ?, ?, 'active', NULL, ?, ?, ?, ?, '{}', '{}', '{}', NULL, ?, ?)
                    """,
                arguments: [
                    projectID, matter.id, "Dormant project 929", "rr-schema-run-937",
                    "rr-schema-output-941", "rr-schema-version-947",
                    String(repeating: "7", count: 64), Wire.timestamp, Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_tables
                        (id, project_id, title, version_index, created_at, updated_at)
                    VALUES (?, ?, 'Dormant table 953', 7, ?, ?)
                    """,
                arguments: [tableID, projectID, Wire.timestamp, Wire.timestamp]
            )
            try db.execute(
                sql: "UPDATE case_file_review_projects SET active_table_id = ? WHERE id = ?",
                arguments: [tableID, projectID]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_columns
                        (id, table_id, column_key, title, ordinal, created_at)
                    VALUES (?, ?, 'generated_value', 'Generated value 967', 7, ?)
                    """,
                arguments: [columnID, tableID, Wire.timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_rows
                        (id, table_id, row_key, ordinal, created_at)
                    VALUES (?, ?, 'dormant-row-971', 7, ?)
                    """,
                arguments: [rowID, tableID, Wire.timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_cells (
                        id, table_id, row_id, column_id, current_generation_id,
                        attorney_value, review_state, value_state, support_state,
                        reviewed_by, reviewed_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, NULL, NULL, 'needs_review', 'generated',
                              'supported', NULL, NULL, ?, ?)
                    """,
                arguments: [cellID, tableID, rowID, columnID, Wire.timestamp, Wire.timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_cell_generations (
                        id, cell_id, generation_index, source_run_id,
                        generated_values_json, created_at
                    ) VALUES (?, ?, 7, 'rr-schema-run-937', '["dormant-value-977"]', ?)
                    """,
                arguments: [generationID, cellID, Wire.timestamp]
            )
            try db.execute(
                sql: "UPDATE case_file_review_cells SET current_generation_id = ? WHERE id = ?",
                arguments: [generationID, cellID]
            )
            try db.execute(
                sql: """
                    INSERT INTO case_file_review_evidence_edges (
                        id, generation_id, kind, ordinal,
                        frozen_output_source_id, frozen_document_id, frozen_revision_id,
                        frozen_document_name, citation_label, char_start, char_end,
                        locator_json, excerpt, excerpt_sha256,
                        live_output_source_id, live_document_id, live_revision_id,
                        availability, unavailable_reason, created_at, updated_at
                    ) VALUES (?, ?, 'supporting', 7, ?, ?, ?, ?, 'S863', 0, 26,
                              ?, ?, ?, ?, ?, ?, 'available', NULL, ?, ?)
                    """,
                arguments: [
                    edgeID, generationID, source.id, document.id, revision.id,
                    document.displayName, source.locatorJSON, source.excerpt, frozenDigest,
                    source.id, document.id, revision.id, Wire.timestamp, Wire.timestamp,
                ]
            )
        }

        let frozenBefore = try store.database.writer.read { db in
            try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT frozen_output_source_id, frozen_document_id,
                           frozen_revision_id, frozen_document_name, citation_label,
                           locator_json, excerpt, excerpt_sha256
                    FROM case_file_review_evidence_edges WHERE id = ?
                    """,
                arguments: [edgeID]
            ))
        }

        _ = try store.documentLibrary.permanentlyDeleteDocument(
            id: document.id,
            actor: "synthetic-attorney-983",
            at: Date(timeIntervalSince1970: 1_799_009_983)
        )

        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matter_documents WHERE id = ?", arguments: [document.id]),
                0
            )
            let edge = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT availability, unavailable_reason, live_output_source_id,
                           live_document_id, live_revision_id,
                           frozen_output_source_id, frozen_document_id,
                           frozen_revision_id, frozen_document_name, citation_label,
                           locator_json, excerpt, excerpt_sha256
                    FROM case_file_review_evidence_edges WHERE id = ?
                    """,
                arguments: [edgeID]
            ))
            XCTAssertEqual(edge["availability"] as String, "unavailable")
            XCTAssertEqual(edge["unavailable_reason"] as String, "source_permanently_deleted")
            XCTAssertNil(edge["live_output_source_id"] as String?)
            XCTAssertNil(edge["live_document_id"] as String?)
            XCTAssertNil(edge["live_revision_id"] as String?)
            XCTAssertEqual(edge["frozen_output_source_id"] as String, frozenBefore["frozen_output_source_id"] as String)
            XCTAssertEqual(edge["frozen_document_id"] as String, frozenBefore["frozen_document_id"] as String)
            XCTAssertEqual(edge["frozen_revision_id"] as String, frozenBefore["frozen_revision_id"] as String)
            XCTAssertEqual(edge["excerpt_sha256"] as String, frozenBefore["excerpt_sha256"] as String)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT support_state FROM case_file_review_cells WHERE id = ?", arguments: [cellID]),
                "stale"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM case_file_review_projects WHERE id = ?", arguments: [projectID]),
                "stale"
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
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

    private var dormantV073Tables: [String] {
        [
            "case_file_review_projects",
            "case_file_review_tables",
            "case_file_review_columns",
            "case_file_review_rows",
            "case_file_review_cells",
            "case_file_review_cell_generations",
            "case_file_review_evidence_edges",
        ]
    }

    private func foreignKeyContracts(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        return Set(Dictionary(grouping: rows) { $0["id"] as Int }.values.map { group in
            let ordered = group.sorted { ($0["seq"] as Int) < ($1["seq"] as Int) }
            return "\(ordered.map { $0["from"] as String }.joined(separator: ","))->\(ordered[0]["table"] as String):\(ordered.map { $0["to"] as String }.joined(separator: ",")):\(ordered[0]["on_delete"] as String)"
        })
    }

    private func uniqueIndexColumnSets(_ db: Database, table: String) throws -> Set<[String]> {
        var result = Set<[String]>()
        for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
        where (index["unique"] as Int) == 1 {
            let name = index["name"] as String
            result.insert(
                try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                    .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
                    .map { $0["name"] as String }
            )
        }
        return result
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
