import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class CaseFileReviewIntegrityMigrationTests: XCTestCase {
    func testTSTORE01V072CreatesNormalizedExactSliceSchemaAndConstraints() throws {
        // T-STORE-01 expected RED: v072 and the normalized exact-slice table do
        // not exist, so persisted corpus partitions still prove only revision
        // membership rather than exact, ordered character-range coverage.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v072_harden_corpus_review_integrity"))

        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        let hasSliceTable = try queue.read { db in
            let runColumns = try db.columns(in: "corpus_analysis_runs")
            XCTAssertTrue(runColumns.contains { $0.name == "request_schema_version" && !$0.isNotNull })
            XCTAssertTrue(runColumns.contains { $0.name == "request_digest" && !$0.isNotNull })

            let tableExists = try db.tableExists("corpus_analysis_partition_slices")
            XCTAssertTrue(tableExists)
            if tableExists {
                XCTAssertEqual(
                    Set(try db.columns(in: "corpus_analysis_partition_slices").map(\.name)),
                    Set([
                        "id", "run_id", "partition_id", "ordinal", "member_key",
                        "document_id", "part_index", "revision_id", "char_start",
                        "char_end", "revision_char_count", "text_sha256", "locator_json",
                    ])
                )
                XCTAssertEqual(
                    try foreignKeyContracts(db, table: "corpus_analysis_partition_slices"),
                    Set([
                        "run_id->corpus_analysis_runs:CASCADE",
                        "partition_id->corpus_analysis_partitions:CASCADE",
                    ]),
                    "document/revision values are durable snapshot identities, not live foreign keys"
                )
            }
            return tableExists
        }

        if hasSliceTable {
            let matter = try MattersRepository(writer: queue).createMatter(
                name: "Synthetic exact-slice constraints",
                jurisdiction: "North Carolina",
                partyPerspective: .defendant
            )
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, request_schema_version,
                        request_digest, status, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "t-store-01-run", "t-store-01-key", matter.id, "exhaustive_list",
                        #"{"document_ids":["document-97"],"schema_version":7}"#,
                        #"{"members":[{"member_key":"member-97","document_id":"document-97","display_name":"Synthetic-97.txt","revision_ids":["revision-97"],"index_state":"ready","disposition":"eligible"}]}"#,
                        "exact_revision_slice", 2, 2,
                        String(repeating: "a", count: 64), "planning",
                        Date(timeIntervalSince1970: 1_790_000_097),
                    ]
                )
                for (index, invalidDigest) in [
                    String(repeating: "2", count: 63),
                    String(repeating: "A", count: 64),
                    String(repeating: "g", count: 64),
                ].enumerated() {
                    XCTAssertThrowsError(try db.execute(
                        sql: """
                        INSERT INTO corpus_analysis_runs (
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, request_schema_version,
                            request_digest, status, created_at
                        ) VALUES (?, ?, ?, ?, '{}', '{"members":[]}', ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            "t-store-01-invalid-digest-\(index)",
                            "t-store-01-invalid-digest-key-\(index)",
                            matter.id, "exhaustive_list", "exact_revision_slice",
                            2, 2, invalidDigest, "planning",
                            Date(timeIntervalSince1970: 1_790_000_107 + Double(index)),
                        ]
                    ))
                }
                for (id, key) in [
                    ("t-store-01-partition-a", "member-97#slice:0"),
                    ("t-store-01-partition-b", "member-97#slice:1"),
                ] {
                    try db.execute(
                        sql: """
                        INSERT INTO corpus_analysis_partitions (
                            id, run_id, partition_key, input_revision_ids_json
                        ) VALUES (?, 't-store-01-run', ?, '["revision-97"]')
                        """,
                        arguments: [id, key]
                    )
                }

                try insertSlice(
                    db,
                    id: "t-store-01-slice-valid",
                    partitionID: "t-store-01-partition-a",
                    ordinal: 17,
                    charStart: 113,
                    charEnd: 389,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "b", count: 64)
                )

                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-duplicate-ordinal",
                    partitionID: "t-store-01-partition-a",
                    ordinal: 17,
                    charStart: 389,
                    charEnd: 501,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "c", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-duplicate-range",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 23,
                    charStart: 113,
                    charEnd: 389,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "d", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-negative-start",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 29,
                    charStart: -1,
                    charEnd: 7,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "e", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-empty-range",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 31,
                    charStart: 401,
                    charEnd: 401,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "f", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-past-end",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 37,
                    charStart: 997,
                    charEnd: 1_003,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "1", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-short-digest",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 41,
                    charStart: 501,
                    charEnd: 611,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "2", count: 63)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-uppercase-digest",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 43,
                    charStart: 611,
                    charEnd: 701,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "A", count: 64)
                ))
                XCTAssertThrowsError(try insertSlice(
                    db,
                    id: "t-store-01-slice-nonhex-digest",
                    partitionID: "t-store-01-partition-b",
                    ordinal: 47,
                    charStart: 701,
                    charEnd: 811,
                    revisionCharCount: 997,
                    textSHA256: String(repeating: "g", count: 64)
                ))

                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices"),
                    1,
                    "every invalid non-default range/digest must be rejected rather than partially inserted"
                )
                try db.execute(
                    sql: "DELETE FROM corpus_analysis_partitions WHERE id = ?",
                    arguments: ["t-store-01-partition-a"]
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices"),
                    0,
                    "partition deletion must cascade its exact persisted slices"
                )
            }
        }
    }

    func testTSTORE01V2CorpusCompleteRequiresExactOnceOnlySliceCoverage() throws {
        // T-STORE-01 expected RED: v071 has no v2 request/slice schema or
        // completion barrier, so corpus_complete can still be persisted with
        // missing v2 request identity, zero slices, a gap, or overlapping coverage.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v072_harden_corpus_review_integrity"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        let runColumns = try queue.read { db in Set(try db.columns(in: "corpus_analysis_runs").map(\.name)) }
        XCTAssertTrue(runColumns.contains("request_schema_version"))
        XCTAssertTrue(runColumns.contains("request_digest"))
        let hasSliceTable = try queue.read { db in try db.tableExists("corpus_analysis_partition_slices") }
        XCTAssertTrue(hasSliceTable)

        if hasSliceTable,
           runColumns.contains("request_schema_version"),
           runColumns.contains("request_digest") {
            let matter = try MattersRepository(writer: queue).createMatter(
                name: "Synthetic v2 completion barrier",
                jurisdiction: "Tennessee",
                partyPerspective: .defendant
            )
            try queue.write { db in
                let zero = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "zero",
                    digestDigit: "3",
                    disposition: .succeeded
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: zero.runID, exclusionsDisclosed: true))
                try assertNotCorpusComplete(db, runID: zero.runID)

                let gap = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "gap",
                    digestDigit: "4",
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-gap-left",
                    partitionID: gap.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 47,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "4", count: 64),
                    runID: gap.runID,
                    memberKey: gap.memberKey,
                    documentID: gap.documentID,
                    partIndex: 7,
                    revisionID: gap.revisionID
                )
                try insertSlice(
                    db,
                    id: "t-store-01-gap-right",
                    partitionID: gap.partitionID,
                    ordinal: 1,
                    charStart: 53,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "5", count: 64),
                    runID: gap.runID,
                    memberKey: gap.memberKey,
                    documentID: gap.documentID,
                    partIndex: 7,
                    revisionID: gap.revisionID
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: gap.runID, exclusionsDisclosed: true))
                try assertNotCorpusComplete(db, runID: gap.runID)

                let overlap = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "overlap",
                    digestDigit: "5",
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-overlap-left",
                    partitionID: overlap.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 60,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "6", count: 64),
                    runID: overlap.runID,
                    memberKey: overlap.memberKey,
                    documentID: overlap.documentID,
                    partIndex: 11,
                    revisionID: overlap.revisionID
                )
                try insertSlice(
                    db,
                    id: "t-store-01-overlap-right",
                    partitionID: overlap.partitionID,
                    ordinal: 1,
                    charStart: 50,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "7", count: 64),
                    runID: overlap.runID,
                    memberKey: overlap.memberKey,
                    documentID: overlap.documentID,
                    partIndex: 11,
                    revisionID: overlap.revisionID
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: overlap.runID, exclusionsDisclosed: true))
                try assertNotCorpusComplete(db, runID: overlap.runID)

                let exact = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "exact",
                    digestDigit: "6",
                    disposition: .pending
                )
                try insertSlice(
                    db,
                    id: "t-store-01-exact-full-range",
                    partitionID: exact.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "8", count: 64),
                    runID: exact.runID,
                    memberKey: exact.memberKey,
                    documentID: exact.documentID,
                    partIndex: 13,
                    revisionID: exact.revisionID
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql: "UPDATE corpus_analysis_partitions SET disposition = ? WHERE id = ?",
                    arguments: [CorpusAnalysisPartitionDisposition.succeeded.rawValue, exact.partitionID]
                )
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_schema_version = 1 WHERE id = ?",
                    arguments: [exact.runID]
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_schema_version = 2, request_digest = NULL WHERE id = ?",
                    arguments: [exact.runID]
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_digest = ? WHERE id = ?",
                    arguments: [String(repeating: "6", count: 64), exact.runID]
                )
                XCTAssertThrowsError(try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: false))

                try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true)
                let completed = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: exact.runID))
                XCTAssertEqual(completed.status, CorpusAnalysisRunStatus.persisted.rawValue)
                XCTAssertEqual(completed.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
            }
        }
    }

    func testTSTORE02V072LeavesLegacyLineageUnknownAndRevokesPublishableAssurance() throws {
        // T-STORE-02 expected RED: v071 leaves a legacy corpus-complete run and
        // its linked output export-eligible even though no exact request digest
        // or normalized character slices can be proven for that historical run.
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v071_create_draft_artifact_intents")
        let store = SupraStore(database: try SupraDatabase(writer: queue))
        let matter = try store.matters.createMatter(
            name: "Synthetic legacy corpus claim",
            jurisdiction: "Virginia",
            partyPerspective: .plaintiff
        )
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Historical exact-slice unknown",
            outputType: .documentExhaustiveList
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "# Preserved synthetic reconciliation\n\nLegacy finding 97 [S97].",
            requiredSections: ["Finding 97"],
            presentSections: ["Finding 97"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "legacy-corpus-verifier/7",
            verificationResults: [try supportedResult(sourceID: "legacy-source-97")],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_000_197),
            promptBuilderVersion: "legacy-corpus-prompt/7",
            assuranceState: .corpusComplete,
            outputStatus: .complete
        )
        let preservedReconciliation = #"{"finding":"Legacy value 97","schema_version":7}"#
        let preservedAuditMetadata = #"{"run_id":"t-store-02-run","retained_marker":97}"#
        try queue.write { db in
            try CorpusAnalysisRunRecord(
                id: "t-store-02-run",
                runKey: "t-store-02-key",
                matterID: matter.id,
                taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                scopeJSON: #"{"document_ids":["legacy-document-97"],"schema_version":7}"#,
                corpusSnapshotJSON: #"{"members":[{"member_key":"legacy-member-97","document_id":"legacy-document-97","display_name":"Legacy-97.txt","revision_ids":["legacy-revision-97"],"index_state":"ready","disposition":"eligible"}]}"#,
                partitionStrategy: "part_range",
                partitionStrategyVersion: 1,
                modelLineageJSON: #"{"repository":"synthetic/model","revision":"legacy-revision-7"}"#,
                status: CorpusAnalysisRunStatus.persisted.rawValue,
                coverageJSON: #"{"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#,
                reconciliationJSON: preservedReconciliation,
                assuranceState: OutputAssuranceState.corpusComplete.rawValue,
                assuranceReasonsJSON: #"["Legacy revision-only ledger passed"]"#,
                structuredOutputVersionID: version.id,
                createdAt: Date(timeIntervalSince1970: 1_790_000_197),
                completedAt: Date(timeIntervalSince1970: 1_790_000_297)
            ).insert(db)
            try CorpusAnalysisPartitionRecord(
                id: "t-store-02-partition",
                runID: "t-store-02-run",
                partitionKey: "legacy-member-97#part:13",
                inputRevisionIDsJSON: #"["legacy-revision-97"]"#,
                disposition: CorpusAnalysisPartitionDisposition.succeeded.rawValue,
                findingsJSON: #"[{"finding_id":"legacy-finding-97"}]"#,
                startedAt: Date(timeIntervalSince1970: 1_790_000_207),
                completedAt: Date(timeIntervalSince1970: 1_790_000_227)
            ).insert(db)
            try AuditEventRecord(
                id: "t-store-02-audit",
                matterID: matter.id,
                timestamp: Date(timeIntervalSince1970: 1_790_000_307),
                eventType: "legacy_corpus_completed",
                actor: "system",
                summary: "Preserved historical corpus event 97",
                relatedTable: "corpus_analysis_runs",
                relatedID: "t-store-02-run",
                metadataJSON: preservedAuditMetadata
            ).insert(db)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v072_harden_corpus_review_integrity"
            )
            let runColumns = Set(try db.columns(in: "corpus_analysis_runs").map(\.name))
            XCTAssertTrue(runColumns.contains("request_schema_version"))
            XCTAssertTrue(runColumns.contains("request_digest"))
            if runColumns.contains("request_schema_version"), runColumns.contains("request_digest") {
                let request = try XCTUnwrap(Row.fetchOne(
                    db,
                    sql: "SELECT request_schema_version, request_digest FROM corpus_analysis_runs WHERE id = ?",
                    arguments: ["t-store-02-run"]
                ))
                XCTAssertNil(request["request_schema_version"] as Int?)
                XCTAssertNil(request["request_digest"] as String?)
            }

            let hasSliceTable = try db.tableExists("corpus_analysis_partition_slices")
            XCTAssertTrue(hasSliceTable)
            if hasSliceTable {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: ["t-store-02-run"]
                    ),
                    0,
                    "v072 must not fabricate exact slices from a revision-only legacy partition"
                )
            }

            let migratedRun = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: "t-store-02-run"))
            XCTAssertEqual(migratedRun.reconciliationJSON, preservedReconciliation)
            XCTAssertEqual(migratedRun.assuranceState, OutputAssuranceState.stale.rawValue)
            let migratedVersion = try XCTUnwrap(StructuredOutputVersionRecord.fetchOne(db, key: version.id))
            XCTAssertEqual(migratedVersion.contentMarkdown, version.contentMarkdown)
            XCTAssertEqual(migratedVersion.assuranceState, OutputAssuranceState.stale.rawValue)
            XCTAssertNotNil(migratedVersion.staleReason)
            XCTAssertFalse(migratedVersion.staleReason?.isEmpty ?? true)
            let assurance = migratedVersion.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
            XCTAssertNotNil(assurance)
            XCTAssertFalse(assurance.map(OutputAssurancePresentation.isExportEligible) ?? true)
            let migratedOutput = try XCTUnwrap(StructuredOutputRecord.fetchOne(db, key: output.id))
            XCTAssertEqual(migratedOutput.activeVersionID, version.id)
            XCTAssertEqual(migratedOutput.status, StructuredOutputStatus.needsReview.rawValue)

            let preservedAudit = try XCTUnwrap(AuditEventRecord.fetchOne(db, key: "t-store-02-audit"))
            XCTAssertEqual(preservedAudit.summary, "Preserved historical corpus event 97")
            XCTAssertEqual(preservedAudit.metadataJSON, preservedAuditMetadata)
        }
    }

    private func insertSlice(
        _ db: Database,
        id: String,
        partitionID: String,
        ordinal: Int,
        charStart: Int,
        charEnd: Int,
        revisionCharCount: Int,
        textSHA256: String,
        runID: String = "t-store-01-run",
        memberKey: String = "member-97",
        documentID: String = "document-97",
        partIndex: Int = 13,
        revisionID: String = "revision-97"
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO corpus_analysis_partition_slices (
                id, run_id, partition_id, ordinal, member_key, document_id,
                part_index, revision_id, char_start, char_end,
                revision_char_count, text_sha256, locator_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, runID, partitionID, ordinal, memberKey,
                documentID, partIndex, revisionID, charStart, charEnd,
                revisionCharCount, textSHA256,
                "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":\(charStart),\"char_end\":\(charEnd)}",
            ]
        )
    }

    private func insertCompletionBarrierRun(
        _ db: Database,
        matterID: String,
        caseName: String,
        digestDigit: String,
        disposition: CorpusAnalysisPartitionDisposition
    ) throws -> (
        runID: String,
        partitionID: String,
        memberKey: String,
        documentID: String,
        revisionID: String
    ) {
        let runID = "t-store-01-barrier-\(caseName)-run"
        let partitionID = "t-store-01-barrier-\(caseName)-partition"
        let memberKey = "t-store-01-barrier-\(caseName)-member"
        let documentID = "t-store-01-barrier-\(caseName)-document"
        let revisionID = "t-store-01-barrier-\(caseName)-revision"
        try db.execute(
            sql: """
            INSERT INTO corpus_analysis_runs (
                id, run_key, matter_id, task_kind, scope_json,
                corpus_snapshot_json, partition_strategy,
                partition_strategy_version, request_schema_version,
                request_digest, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                runID, "t-store-01-barrier-\(caseName)-key", matterID,
                CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                "{\"document_ids\":[\"\(documentID)\"],\"schema_version\":7}",
                "{\"members\":[{\"member_key\":\"\(memberKey)\",\"document_id\":\"\(documentID)\",\"display_name\":\"Synthetic-\(caseName).txt\",\"revision_ids\":[\"\(revisionID)\"],\"index_state\":\"ready\",\"disposition\":\"eligible\"}]}",
                "exact_revision_slice", 2, 2,
                String(repeating: digestDigit, count: 64),
                CorpusAnalysisRunStatus.planning.rawValue,
                Date(timeIntervalSince1970: 1_790_000_500),
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO corpus_analysis_partitions (
                id, run_id, partition_key, input_revision_ids_json, disposition
            ) VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                partitionID, runID, "\(memberKey)#slice:0", "[\"\(revisionID)\"]",
                disposition.rawValue,
            ]
        )
        return (runID, partitionID, memberKey, documentID, revisionID)
    }

    private func persistCorpusComplete(
        _ db: Database,
        runID: String,
        exclusionsDisclosed: Bool
    ) throws {
        let disclosed = exclusionsDisclosed ? "true" : "false"
        try db.execute(
            sql: """
            UPDATE corpus_analysis_runs
            SET status = ?, assurance_state = ?, coverage_json = ?
            WHERE id = ?
            """,
            arguments: [
                CorpusAnalysisRunStatus.persisted.rawValue,
                OutputAssuranceState.corpusComplete.rawValue,
                "{\"excluded_members_disclosed\":\(disclosed),\"partition_count\":1,\"succeeded_partition_count\":1,\"balance_error_count\":0}",
                runID,
            ]
        )
    }

    private func assertNotCorpusComplete(
        _ db: Database,
        runID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let run = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: runID), file: file, line: line)
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.planning.rawValue, file: file, line: line)
        XCTAssertNotEqual(run.assuranceState, OutputAssuranceState.corpusComplete.rawValue, file: file, line: line)
    }

    private func foreignKeyContracts(_ db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").map { row in
            "\(row["from"] as String)->\(row["table"] as String):\(row["on_delete"] as String)"
        })
    }

    private func supportedResult(sourceID: String) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "legacy-proposition-97",
            status: .supported,
            reasons: ["synthetic_legacy_support"],
            evidence: [SupportEvidence(
                sourceID: sourceID,
                sourceLabel: "S97",
                locator: "Legacy-97.txt, part 13, characters 113–389",
                retainedExcerpt: "Synthetic retained legacy evidence value 97.",
                verifierName: "LegacyCorpusVerifier",
                verifierVersion: "legacy-corpus-verifier/7"
            )],
            timestamp: Date(timeIntervalSince1970: 1_790_000_197)
        )
    }

    private func supportedDimensions() -> VerificationDimensions {
        .complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied),
            .init(dimension: .citationResolution, status: .satisfied),
            .init(dimension: .criticalValueFidelity, status: .satisfied),
            .init(dimension: .lowConfidenceHandling, status: .satisfied),
        ])
    }
}
