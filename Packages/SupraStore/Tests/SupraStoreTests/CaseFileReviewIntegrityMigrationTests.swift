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
                let sliceColumns = Set(
                    try db.columns(in: "corpus_analysis_partition_slices").map(\.name)
                )
                let requiredSliceColumns = Set([
                    "id", "run_id", "partition_id", "ordinal", "member_key",
                    "document_id", "part_index", "revision_id", "char_start",
                    "char_end", "revision_char_count", "text_sha256", "locator_json",
                ])
                XCTAssertTrue(
                    requiredSliceColumns.isSubset(of: sliceColumns),
                    "v072 may add operational columns, but it must retain every exact-slice contract column"
                )
                let foreignKeys = try foreignKeyContracts(
                    db,
                    table: "corpus_analysis_partition_slices"
                )
                XCTAssertTrue(
                    foreignKeys.contains("run_id->corpus_analysis_runs:id:CASCADE"),
                    "the durable slice ledger must cascade with its owning run"
                )
                XCTAssertTrue(
                    foreignKeys.contains(
                        "partition_id,run_id->corpus_analysis_partitions:id,run_id:CASCADE"
                    ),
                    "a slice's partition and run must be one composite relationship; independent foreign keys permit cross-run provenance laundering"
                )
                XCTAssertTrue(
                    try uniqueIndexColumnSets(db, table: "corpus_analysis_partitions")
                        .contains(["id", "run_id"]),
                    "the parent key for the composite slice-to-partition relationship must be unique"
                )
                XCTAssertFalse(
                    foreignKeys.contains { contract in
                        contract.contains("->matter_documents:")
                            || contract.contains("->document_part_revisions:")
                    },
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
                    XCTAssertThrowsError(
                        try db.execute(
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
                        "t-store-01-other-run", "t-store-01-other-key", matter.id,
                        "exhaustive_list",
                        #"{"document_ids":["document-other"],"schema_version":7}"#,
                        #"{"members":[{"member_key":"member-other","document_id":"document-other","display_name":"Synthetic-other.txt","revision_ids":["revision-other"],"index_state":"ready","disposition":"eligible"}]}"#,
                        "exact_revision_slice", 2, 2,
                        String(repeating: "9", count: 64), "planning",
                        Date(timeIntervalSince1970: 1_790_000_197),
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_partitions (
                            id, run_id, partition_key, input_revision_ids_json
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        "t-store-01-other-partition", "t-store-01-other-run",
                        "member-other#slice:0", #"["revision-other"]"#,
                    ]
                )

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

                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-cross-run-partition",
                        partitionID: "t-store-01-other-partition",
                        ordinal: 19,
                        charStart: 389,
                        charEnd: 501,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "2", count: 64)
                    ))
                XCTAssertThrowsError(
                    try db.execute(
                        sql: "UPDATE corpus_analysis_runs SET request_digest = ? WHERE id = ?",
                        arguments: [String(repeating: "A", count: 64), "t-store-01-run"]
                    ))
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT request_digest FROM corpus_analysis_runs WHERE id = ?",
                        arguments: ["t-store-01-run"]
                    ),
                    String(repeating: "a", count: 64),
                    "digest constraints must protect mutations as well as initial inserts"
                )
                XCTAssertThrowsError(
                    try db.execute(
                        sql: "UPDATE corpus_analysis_runs SET request_digest = ? WHERE id = ?",
                        arguments: [Data(repeating: 0x61, count: 64), "t-store-01-run"]
                    ),
                    "a 64-byte lowercase-hex BLOB is not a text request digest"
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT request_digest FROM corpus_analysis_runs WHERE id = ?",
                        arguments: ["t-store-01-run"]
                    ),
                    String(repeating: "a", count: 64)
                )

                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-duplicate-ordinal",
                        partitionID: "t-store-01-partition-a",
                        ordinal: 17,
                        charStart: 389,
                        charEnd: 501,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "c", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-duplicate-range",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 23,
                        charStart: 113,
                        charEnd: 389,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "d", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-negative-start",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 29,
                        charStart: -1,
                        charEnd: 7,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "e", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-empty-range",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 31,
                        charStart: 401,
                        charEnd: 401,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "f", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-past-end",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 37,
                        charStart: 997,
                        charEnd: 1_003,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "1", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-short-digest",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 41,
                        charStart: 501,
                        charEnd: 611,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "2", count: 63)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
                        db,
                        id: "t-store-01-slice-uppercase-digest",
                        partitionID: "t-store-01-partition-b",
                        ordinal: 43,
                        charStart: 611,
                        charEnd: 701,
                        revisionCharCount: 997,
                        textSHA256: String(repeating: "A", count: 64)
                    ))
                XCTAssertThrowsError(
                    try insertSlice(
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
        // missing v2 request identity, zero/gapped/overlapping ranges, missing
        // snapshot members or revisions, or an extraneous snapshot identity.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v072_harden_corpus_review_integrity"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        let runColumns = try queue.read { db in
            Set(try db.columns(in: "corpus_analysis_runs").map(\.name))
        }
        XCTAssertTrue(runColumns.contains("request_schema_version"))
        XCTAssertTrue(runColumns.contains("request_digest"))
        let hasSliceTable = try queue.read { db in
            try db.tableExists("corpus_analysis_partition_slices")
        }
        XCTAssertTrue(hasSliceTable)

        if hasSliceTable,
            runColumns.contains("request_schema_version"),
            runColumns.contains("request_digest")
        {
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
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: zero.runID, exclusionsDisclosed: true))
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
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: gap.runID, exclusionsDisclosed: true))
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
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: overlap.runID, exclusionsDisclosed: true))
                try assertNotCorpusComplete(db, runID: overlap.runID)

                let missingRevision = try insertCompletionMatrixRun(
                    db,
                    matterID: matter.id,
                    caseName: "missing-revision",
                    digestDigit: "a",
                    members: [
                        CompletionMemberSpec(
                            memberKey: "t-store-01-missing-revision-member",
                            documentID: "t-store-01-missing-revision-document",
                            revisions: [
                                .init(id: "t-store-01-missing-revision-a", partIndex: 17, charCount: 101),
                                .init(id: "t-store-01-missing-revision-b", partIndex: 19, charCount: 137),
                            ]
                        )
                    ]
                )
                try insertFullSlice(
                    db,
                    target: missingRevision.targets[0],
                    id: "t-store-01-missing-revision-only-first-slice",
                    digestDigit: "a"
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: missingRevision.runID,
                        exclusionsDisclosed: true,
                        partitionCount: 2
                    ))
                try assertNotCorpusComplete(db, runID: missingRevision.runID)

                let missingMember = try insertCompletionMatrixRun(
                    db,
                    matterID: matter.id,
                    caseName: "missing-member",
                    digestDigit: "b",
                    members: [
                        CompletionMemberSpec(
                            memberKey: "t-store-01-missing-member-a",
                            documentID: "t-store-01-missing-member-document-a",
                            revisions: [
                                .init(id: "t-store-01-missing-member-revision-a", partIndex: 23, charCount: 109)
                            ]
                        ),
                        CompletionMemberSpec(
                            memberKey: "t-store-01-missing-member-b",
                            documentID: "t-store-01-missing-member-document-b",
                            revisions: [
                                .init(id: "t-store-01-missing-member-revision-b", partIndex: 29, charCount: 149)
                            ]
                        ),
                    ]
                )
                try insertFullSlice(
                    db,
                    target: missingMember.targets[0],
                    id: "t-store-01-missing-member-only-first-slice",
                    digestDigit: "b"
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: missingMember.runID,
                        exclusionsDisclosed: true,
                        partitionCount: 2
                    ))
                try assertNotCorpusComplete(db, runID: missingMember.runID)

                let extraneous = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "extraneous-snapshot-identity",
                    digestDigit: "c",
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-extraneous-snapshot-slice",
                    partitionID: extraneous.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "c", count: 64),
                    runID: extraneous.runID,
                    memberKey: "t-store-01-member-not-in-extraneous-snapshot",
                    documentID: "t-store-01-document-not-in-extraneous-snapshot",
                    partIndex: 31,
                    revisionID: "t-store-01-revision-not-in-extraneous-snapshot"
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: extraneous.runID,
                        exclusionsDisclosed: true
                    ))
                try assertNotCorpusComplete(db, runID: extraneous.runID)

                let completeMatrix = try insertCompletionMatrixRun(
                    db,
                    matterID: matter.id,
                    caseName: "complete-matrix",
                    digestDigit: "d",
                    members: [
                        CompletionMemberSpec(
                            memberKey: "t-store-01-complete-member-a",
                            documentID: "t-store-01-complete-document-a",
                            revisions: [
                                .init(id: "t-store-01-complete-revision-a1", partIndex: 37, charCount: 127),
                                .init(id: "t-store-01-complete-revision-a2", partIndex: 41, charCount: 151),
                            ]
                        ),
                        CompletionMemberSpec(
                            memberKey: "t-store-01-complete-member-b",
                            documentID: "t-store-01-complete-document-b",
                            revisions: [
                                .init(id: "t-store-01-complete-revision-b1", partIndex: 43, charCount: 163)
                            ]
                        ),
                    ]
                )
                for (index, target) in completeMatrix.targets.enumerated() {
                    try insertFullSlice(
                        db,
                        target: target,
                        id: "t-store-01-complete-matrix-slice-\(index)",
                        digestDigit: String(index + 1)
                    )
                }
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: completeMatrix.runID,
                        exclusionsDisclosed: true,
                        partitionCount: 1
                    ))
                try persistCorpusComplete(
                    db,
                    runID: completeMatrix.runID,
                    exclusionsDisclosed: true,
                    partitionCount: completeMatrix.targets.count
                )
                let completedMatrix = try XCTUnwrap(
                    CorpusAnalysisRunRecord.fetchOne(db, key: completeMatrix.runID)
                )
                XCTAssertEqual(completedMatrix.status, CorpusAnalysisRunStatus.persisted.rawValue)
                XCTAssertEqual(
                    completedMatrix.assuranceState,
                    OutputAssuranceState.corpusComplete.rawValue
                )

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
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql: "UPDATE corpus_analysis_partitions SET disposition = ? WHERE id = ?",
                    arguments: [CorpusAnalysisPartitionDisposition.succeeded.rawValue, exact.partitionID]
                )
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_schema_version = 1 WHERE id = ?",
                    arguments: [exact.runID]
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql:
                        "UPDATE corpus_analysis_runs SET request_schema_version = 2, request_digest = NULL WHERE id = ?",
                    arguments: [exact.runID]
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true))
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_digest = ? WHERE id = ?",
                    arguments: [String(repeating: "6", count: 64), exact.runID]
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: false))

                try persistCorpusComplete(db, runID: exact.runID, exclusionsDisclosed: true)
                let completed = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: exact.runID))
                XCTAssertEqual(completed.status, CorpusAnalysisRunStatus.persisted.rawValue)
                XCTAssertEqual(completed.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertThrowsError(
                    try db.execute(
                        sql: "DELETE FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: [exact.runID]
                    ),
                    "a finalized exact ledger must remain frozen while its completion claim exists"
                )
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: [exact.runID]
                    ),
                    1
                )

                let malformed = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: "malformed-eligible-member",
                    digestDigit: "e",
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-malformed-valid-slice",
                    partitionID: malformed.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "e", count: 64),
                    runID: malformed.runID,
                    memberKey: malformed.memberKey,
                    documentID: malformed.documentID,
                    partIndex: 13,
                    revisionID: malformed.revisionID
                )
                let malformedSnapshot = try JSONSerialization.data(
                    withJSONObject: [
                        "schema_version": 2,
                        "members": [
                            [
                                "member_key": malformed.memberKey,
                                "document_id": malformed.documentID,
                                "display_name": "Valid member.txt",
                                "revision_ids": [malformed.revisionID],
                                "index_state": "ready",
                                "disposition": "eligible",
                            ],
                            [
                                "member_key": "malformed-eligible",
                                "display_name": "Malformed member.txt",
                                "index_state": "ready",
                                "disposition": "eligible",
                            ],
                        ],
                    ],
                    options: [.sortedKeys]
                )
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET corpus_snapshot_json = ? WHERE id = ?",
                    arguments: [String(decoding: malformedSnapshot, as: UTF8.self), malformed.runID]
                )
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT json_valid(corpus_snapshot_json) FROM corpus_analysis_runs WHERE id = ?",
                        arguments: [malformed.runID]
                    ),
                    1
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: malformed.runID,
                        exclusionsDisclosed: true
                    ),
                    "an eligible snapshot member with missing identity fields must fail closed"
                ) { error in
                    XCTAssertTrue(
                        error.localizedDescription.contains("eligible snapshot member is malformed"),
                        "the malformed-member barrier must be the reason for rejection: \(error)"
                    )
                }
                try assertNotCorpusComplete(db, runID: malformed.runID)
            }
        }
    }

    func testTSTORE01V072RejectsDirectInsertOfCompletedExhaustiveRun() throws {
        // T-STORE-01 expected RED: an UPDATE-only completion trigger can be
        // bypassed by inserting an exhaustive run directly in its terminal
        // corpus-complete state without any partitions or exact slices.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic direct-insert completion bypass"
        )

        try queue.write { db in
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_runs (
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, request_schema_version,
                            request_digest, status, coverage_json,
                            assurance_state, created_at, completed_at
                        ) VALUES (?, ?, ?, ?, '{}', ?, ?, 2, 2, ?,
                            'persisted', ?, 'corpus_complete', ?, ?)
                        """,
                    arguments: [
                        "t-store-01-direct-insert-run",
                        "t-store-01-direct-insert-key",
                        matter.id,
                        CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                        #"{"schema_version":2,"members":[{"member_key":"document:direct-insert","document_id":"direct-insert","display_name":"Direct insert.txt","revision_ids":["direct-insert-revision"],"index_state":"ready","disposition":"eligible"}]}"#,
                        "exact_revision_slice:characters=1973",
                        String(repeating: "d", count: 64),
                        #"{"excluded_members_disclosed":true,"partition_count":0,"succeeded_partition_count":0,"balance_error_count":0}"#,
                        Date(timeIntervalSince1970: 1_790_001_701),
                        Date(timeIntervalSince1970: 1_790_001_702),
                    ]
                )
            )
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(
                    db,
                    key: "t-store-01-direct-insert-run"
                )
            )

            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_runs (
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, status, coverage_json,
                            assurance_state, created_at, completed_at
                        ) VALUES (?, ?, ?, ?, '{}', '{"schema_version":2,"members":[]}',
                            'part_range:characters=1979', 1, 'persisted', ?,
                            'proposition_supported', ?, ?)
                        """,
                    arguments: [
                        "t-store-01-direct-proposition-run",
                        "t-store-01-direct-proposition-key",
                        matter.id,
                        CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                        #"{"excluded_members_disclosed":true,"partition_count":0,"succeeded_partition_count":0,"balance_error_count":0}"#,
                        Date(timeIntervalSince1970: 1_790_001_711),
                        Date(timeIntervalSince1970: 1_790_001_712),
                    ]
                ),
                "exhaustive proposition-supported output is equally export-eligible and must require v2 exact lineage"
            )
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(
                    db,
                    key: "t-store-01-direct-proposition-run"
                )
            )
        }
    }

    func testTSTORE02V072LeavesLegacyLineageUnknownAndRevokesPublishableAssurance() throws {
        // T-STORE-02 expected RED: v071 leaves a legacy corpus-complete run and
        // its linked output export-eligible even though no exact request digest
        // or normalized character slices can be proven for that historical run.
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v071_create_draft_artifact_intents")
        let matters = MattersRepository(writer: queue)
        let outputs = StructuredOutputRepository(writer: queue)
        let matter = try matters.createMatter(
            name: "Synthetic legacy corpus claim",
            jurisdiction: "Virginia",
            partyPerspective: .plaintiff
        )
        let output = try outputs.createOutput(
            matterID: matter.id,
            title: "Historical exact-slice unknown",
            outputType: .documentExhaustiveList
        )
        let version = try outputs.createVersion(
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
            // Seed through the exact v071 column surface. Using the current
            // PersistableRecord here would let future record fields leak into
            // this historical fixture before the migration under test runs.
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, model_lineage_json, status,
                        coverage_json, reconciliation_json, assurance_state,
                        assurance_reasons_json, structured_output_version_id,
                        created_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "t-store-02-run", "t-store-02-key", matter.id,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    #"{"document_ids":["legacy-document-97"],"schema_version":7}"#,
                    #"{"members":[{"member_key":"legacy-member-97","document_id":"legacy-document-97","display_name":"Legacy-97.txt","revision_ids":["legacy-revision-97"],"index_state":"ready","disposition":"eligible"}]}"#,
                    "part_range", 1,
                    #"{"repository":"synthetic/model","revision":"legacy-revision-7"}"#,
                    CorpusAnalysisRunStatus.persisted.rawValue,
                    #"{"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#,
                    preservedReconciliation,
                    OutputAssuranceState.corpusComplete.rawValue,
                    #"["Legacy revision-only ledger passed"]"#,
                    version.id,
                    Date(timeIntervalSince1970: 1_790_000_197),
                    Date(timeIntervalSince1970: 1_790_000_297),
                ]
            )
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
                try String.fetchOne(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v072_harden_corpus_review_integrity"
            )
            let runColumns = Set(try db.columns(in: "corpus_analysis_runs").map(\.name))
            XCTAssertTrue(runColumns.contains("request_schema_version"))
            XCTAssertTrue(runColumns.contains("request_digest"))
            if runColumns.contains("request_schema_version"), runColumns.contains("request_digest") {
                let request = try XCTUnwrap(
                    Row.fetchOne(
                        db,
                        sql:
                            "SELECT request_schema_version, request_digest FROM corpus_analysis_runs WHERE id = ?",
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
            let migratedVersion = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: version.id))
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

    func testTSTORE02V072DoesNotExpandCaseFileReviewEnforcementIntoChronology() throws {
        // T-STORE-02 compatibility guard expected RED: v072 does not yet exist.
        // When it lands, its exact-slice upgrade must not revoke or block the
        // separate chronology path, which still owns a v1 revision ledger and
        // requires its own future migration packet.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v072_harden_corpus_review_integrity"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v071_create_draft_artifact_intents")
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic chronology compatibility",
            jurisdiction: "Colorado",
            partyPerspective: .plaintiff
        )

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, status, coverage_json,
                        assurance_state, created_at, completed_at
                    ) VALUES (?, ?, ?, ?, '{}', ?, 'chronology_document', 1,
                        'persisted', ?, 'corpus_complete', ?, ?)
                    """,
                arguments: [
                    "t-store-02-legacy-chronology-run",
                    "t-store-02-legacy-chronology-key",
                    matter.id,
                    CorpusAnalysisTaskKind.chronology.rawValue,
                    #"{"schema_version":1,"members":[{"member_key":"document:chronology-legacy","document_id":"chronology-legacy","display_name":"Chronology legacy.txt","revision_ids":["chronology-legacy-revision"],"index_state":"ready","disposition":"eligible"}]}"#,
                    #"{"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#,
                    Date(timeIntervalSince1970: 1_790_001_001),
                    Date(timeIntervalSince1970: 1_790_001_101),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_partitions (
                        id, run_id, partition_key, input_revision_ids_json,
                        disposition
                    ) VALUES (?, ?, ?, ?, 'succeeded')
                    """,
                arguments: [
                    "t-store-02-legacy-chronology-partition",
                    "t-store-02-legacy-chronology-run",
                    "chronology-legacy#document",
                    #"["chronology-legacy-revision"]"#,
                ]
            )
        }

        try migrator.migrate(queue)

        try queue.write { db in
            let legacy = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(
                    db,
                    key: "t-store-02-legacy-chronology-run"
                )
            )
            XCTAssertNil(legacy.requestSchemaVersion)
            XCTAssertNil(legacy.requestDigest)
            XCTAssertEqual(
                legacy.assuranceState,
                OutputAssuranceState.corpusComplete.rawValue,
                "the Case File Review migration must not revoke chronology assurance"
            )

            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, request_schema_version,
                        request_digest, status, created_at
                    ) VALUES (?, ?, ?, ?, '{}', ?, 'chronology_document', 1,
                        2, ?, 'planning', ?)
                    """,
                arguments: [
                    "t-store-02-current-chronology-run",
                    "t-store-02-current-chronology-key",
                    matter.id,
                    CorpusAnalysisTaskKind.chronology.rawValue,
                    #"{"schema_version":1,"members":[{"member_key":"document:chronology-current","document_id":"chronology-current","display_name":"Chronology current.txt","revision_ids":["chronology-current-revision"],"index_state":"ready","disposition":"eligible"}]}"#,
                    String(repeating: "c", count: 64),
                    Date(timeIntervalSince1970: 1_790_001_201),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_partitions (
                        id, run_id, partition_key, input_revision_ids_json,
                        disposition
                    ) VALUES (?, ?, ?, ?, 'succeeded')
                    """,
                arguments: [
                    "t-store-02-current-chronology-partition",
                    "t-store-02-current-chronology-run",
                    "chronology-current#document",
                    #"["chronology-current-revision"]"#,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET status = 'persisted', assurance_state = 'corpus_complete',
                        coverage_json = ?
                    WHERE id = ?
                    """,
                arguments: [
                    #"{"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#,
                    "t-store-02-current-chronology-run",
                ]
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT assurance_state FROM corpus_analysis_runs WHERE id = ?",
                    arguments: ["t-store-02-current-chronology-run"]
                ),
                OutputAssuranceState.corpusComplete.rawValue
            )
        }
    }

    func testTSTORE02V072PreservesBaselineChronologyCompletionGuard() throws {
        // T-STORE-02 expected RED: replacing v064's universal completion guard
        // with an exhaustive/v2-only trigger lets chronology claim completion
        // while its revision-ledger partition is still pending.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic chronology completion guard"
        )

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, status, created_at
                    ) VALUES (?, ?, ?, ?, '{}', ?, 'chronology_document', 1,
                        'planning', ?)
                    """,
                arguments: [
                    "t-store-02-guarded-chronology-run",
                    "t-store-02-guarded-chronology-key",
                    matter.id,
                    CorpusAnalysisTaskKind.chronology.rawValue,
                    #"{"schema_version":1,"members":[{"member_key":"document:guarded-chronology","document_id":"guarded-chronology","display_name":"Guarded chronology.txt","revision_ids":["guarded-chronology-revision"],"index_state":"ready","disposition":"eligible"}]}"#,
                    Date(timeIntervalSince1970: 1_790_001_801),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_partitions (
                        id, run_id, partition_key, input_revision_ids_json,
                        disposition
                    ) VALUES (?, ?, ?, ?, 'pending')
                    """,
                arguments: [
                    "t-store-02-guarded-chronology-partition",
                    "t-store-02-guarded-chronology-run",
                    "guarded-chronology#document",
                    #"["guarded-chronology-revision"]"#,
                ]
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET status = 'persisted', assurance_state = 'corpus_complete',
                            coverage_json = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        #"{"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":0,"balance_error_count":0}"#,
                        "t-store-02-guarded-chronology-run",
                    ]
                )
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM corpus_analysis_runs WHERE id = ?",
                    arguments: ["t-store-02-guarded-chronology-run"]
                ),
                CorpusAnalysisRunStatus.planning.rawValue
            )

            try db.execute(
                sql: """
                    UPDATE corpus_analysis_partitions
                    SET disposition = 'succeeded'
                    WHERE id = ?
                    """,
                arguments: ["t-store-02-guarded-chronology-partition"]
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET status = 'persisted', assurance_state = 'corpus_complete',
                            coverage_json = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        #"{"excluded_members_disclosed":false,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#,
                        "t-store-02-guarded-chronology-run",
                    ]
                ),
                "the universal completion guard must continue requiring disclosed exclusions"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM corpus_analysis_runs WHERE id = ?",
                    arguments: ["t-store-02-guarded-chronology-run"]
                ),
                CorpusAnalysisRunStatus.planning.rawValue
            )
        }
    }

    func testTSTORE01V072RequiresLiteralExactSliceStrategy() throws {
        // T-STORE-01 review finding expected RED: SQL LIKE treats each `_` in
        // `exact_revision_slice%` as a wildcard, so a lookalike strategy can
        // retain corpus-complete assurance without using the exact planner.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic literal strategy guard 1987"
        )

        try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "literal-strategy-1987",
                digestDigit: "1",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-literal-strategy-slice-1987",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "1", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 79,
                revisionID: target.revisionID
            )
            let lookalikeStrategy = "exactXrevisionYslice:characters=1987"
            XCTAssertNotEqual(lookalikeStrategy, "exact_revision_slice:characters=1987")
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET partition_strategy = ? WHERE id = ?",
                arguments: [lookalikeStrategy, target.runID]
            )

            XCTAssertThrowsError(
                try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true),
                "the exact strategy prefix must compare underscores literally"
            )
            try assertNotCorpusComplete(db, runID: target.runID)
        }
    }

    func testTSTORE01V072RejectsMultiplePartIndicesForOneFrozenRevision() throws {
        // T-STORE-01 review finding expected RED: range completeness is grouped
        // by part_index, so the same frozen revision can be fully represented
        // once at one part and again with different cuts at another part.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic once-only part guard 1991"
        )

        try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "duplicate-part-1991",
                digestDigit: "2",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-part-primary-1991",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "2", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 83,
                revisionID: target.revisionID
            )
            let duplicatePartitionID = "t-store-01-part-duplicate-partition-1991"
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_partitions (
                        id, run_id, partition_key, input_revision_ids_json, disposition
                    ) VALUES (?, ?, ?, ?, 'succeeded')
                    """,
                arguments: [
                    duplicatePartitionID,
                    target.runID,
                    "duplicate-part-index-89#revision:\(target.revisionID)",
                    "[\"\(target.revisionID)\"]",
                ]
            )
            try insertSlice(
                db,
                id: "t-store-01-part-duplicate-left-1991",
                partitionID: duplicatePartitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 37,
                revisionCharCount: 100,
                textSHA256: String(repeating: "3", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 89,
                revisionID: target.revisionID
            )
            try insertSlice(
                db,
                id: "t-store-01-part-duplicate-right-1991",
                partitionID: duplicatePartitionID,
                ordinal: 1,
                charStart: 37,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "4", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 89,
                revisionID: target.revisionID
            )

            XCTAssertThrowsError(
                try persistCorpusComplete(
                    db,
                    runID: target.runID,
                    exclusionsDisclosed: true,
                    partitionCount: 2
                ),
                "one frozen member/document/revision identity must select exactly one part index"
            )
            try assertNotCorpusComplete(db, runID: target.runID)
        }
    }

    func testTSTORE01V072RequiresTypedEqualPartitionRevisionLedger() throws {
        // T-STORE-01 review finding expected RED: json_each accepts a scalar JSON
        // string, and the trigger checks only slice-to-input membership. A scalar
        // or an input array containing an unsliced revision can therefore finalize.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic typed revision ledger 1993"
        )

        try queue.write { db in
            let scalar = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "scalar-revision-ledger-1993",
                digestDigit: "3",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-scalar-revision-slice-1993",
                partitionID: scalar.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "5", count: 64),
                runID: scalar.runID,
                memberKey: scalar.memberKey,
                documentID: scalar.documentID,
                partIndex: 97,
                revisionID: scalar.revisionID
            )
            try db.execute(
                sql: "UPDATE corpus_analysis_partitions SET input_revision_ids_json = ? WHERE id = ?",
                arguments: ["\"\(scalar.revisionID)\"", scalar.partitionID]
            )
            XCTAssertThrowsError(
                try persistCorpusComplete(db, runID: scalar.runID, exclusionsDisclosed: true),
                "partition input revisions must be encoded as a JSON array"
            )
            try assertNotCorpusComplete(db, runID: scalar.runID)

            let extra = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "extra-revision-ledger-1997",
                digestDigit: "4",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-extra-revision-slice-1997",
                partitionID: extra.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "6", count: 64),
                runID: extra.runID,
                memberKey: extra.memberKey,
                documentID: extra.documentID,
                partIndex: 101,
                revisionID: extra.revisionID
            )
            let unslicedRevisionID = "t-store-01-unsliced-revision-1997"
            try db.execute(
                sql: "UPDATE corpus_analysis_partitions SET input_revision_ids_json = ? WHERE id = ?",
                arguments: [
                    "[\"\(extra.revisionID)\",\"\(unslicedRevisionID)\"]",
                    extra.partitionID,
                ]
            )
            XCTAssertThrowsError(
                try persistCorpusComplete(db, runID: extra.runID, exclusionsDisclosed: true),
                "partition input revisions and exact-slice revisions must be equal in both directions"
            )
            try assertNotCorpusComplete(db, runID: extra.runID)
        }
    }

    func testTSTORE01V072RejectsMalformedOrDuplicateSnapshotMembers() throws {
        // T-STORE-01 review finding expected RED: `WHERE disposition = 'eligible'`
        // silently filters NULL dispositions, while duplicate revision IDs are
        // each satisfied by the same slice. Both malformed denominators finalize.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic snapshot member validation 2003"
        )

        try queue.write { db in
            let missingDisposition = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "missing-disposition-2003",
                digestDigit: "5",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-missing-disposition-slice-2003",
                partitionID: missingDisposition.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "7", count: 64),
                runID: missingDisposition.runID,
                memberKey: missingDisposition.memberKey,
                documentID: missingDisposition.documentID,
                partIndex: 103,
                revisionID: missingDisposition.revisionID
            )
            let malformedSnapshot = """
                {"schema_version":23,"members":[
                    {"member_key":"\(missingDisposition.memberKey)","document_id":"\(missingDisposition.documentID)","display_name":"Valid-2003.txt","revision_ids":["\(missingDisposition.revisionID)"],"index_state":"ready","disposition":"eligible"},
                    {"member_key":"hidden-null-disposition-2003","display_name":"Hidden-2003.txt"}
                ]}
                """
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET corpus_snapshot_json = ? WHERE id = ?",
                arguments: [malformedSnapshot, missingDisposition.runID]
            )
            XCTAssertThrowsError(
                try persistCorpusComplete(
                    db,
                    runID: missingDisposition.runID,
                    exclusionsDisclosed: true
                ),
                "every frozen snapshot member must have a typed supported disposition"
            )
            try assertNotCorpusComplete(db, runID: missingDisposition.runID)

            let duplicateRevision = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "duplicate-revision-2011",
                digestDigit: "6",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-duplicate-revision-slice-2011",
                partitionID: duplicateRevision.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "8", count: 64),
                runID: duplicateRevision.runID,
                memberKey: duplicateRevision.memberKey,
                documentID: duplicateRevision.documentID,
                partIndex: 107,
                revisionID: duplicateRevision.revisionID
            )
            let duplicateSnapshot = """
                {"schema_version":29,"members":[
                    {"member_key":"\(duplicateRevision.memberKey)","document_id":"\(duplicateRevision.documentID)","display_name":"Duplicate-2011.txt","revision_ids":["\(duplicateRevision.revisionID)","\(duplicateRevision.revisionID)"],"index_state":"ready","disposition":"eligible"}
                ]}
                """
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET corpus_snapshot_json = ? WHERE id = ?",
                arguments: [duplicateSnapshot, duplicateRevision.runID]
            )
            XCTAssertThrowsError(
                try persistCorpusComplete(
                    db,
                    runID: duplicateRevision.runID,
                    exclusionsDisclosed: true
                ),
                "eligible revision IDs must be unique rather than sharing one exact slice"
            )
            try assertNotCorpusComplete(db, runID: duplicateRevision.runID)
        }
    }

    func testTSTORE01V072FreezesFinalizedRequestIdentityAndLedger() throws {
        // T-STORE-01 review finding expected RED: finalized child rows are guarded,
        // but the root digest/task identity is still mutable. Changing task_kind to
        // chronology disables the child trigger and permits deletion of all slices.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic finalized proof root 2017"
        )

        try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "immutable-root-2017",
                digestDigit: "a",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-immutable-root-slice-2017",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "9", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 109,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)

            let originalDigest = String(repeating: "a", count: 64)
            let forgedDigest = String(repeating: "b", count: 64)
            XCTAssertNotEqual(forgedDigest, originalDigest)
            XCTAssertThrowsError(
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET request_digest = ? WHERE id = ?",
                    arguments: [forgedDigest, target.runID]
                ),
                "the finalized request digest must remain bound to the frozen proof"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT request_digest FROM corpus_analysis_runs WHERE id = ?",
                    arguments: [target.runID]
                ),
                originalDigest
            )

            XCTAssertThrowsError(
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET task_kind = 'chronology' WHERE id = ?",
                    arguments: [target.runID]
                ),
                "an export-eligible exhaustive claim cannot change task identity without downgrade"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT task_kind FROM corpus_analysis_runs WHERE id = ?",
                    arguments: [target.runID]
                ),
                CorpusAnalysisTaskKind.exhaustiveList.rawValue
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: "DELETE FROM corpus_analysis_partition_slices WHERE run_id = ?",
                    arguments: [target.runID]
                ),
                "task-identity laundering must not disable finalized ledger immutability"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                    arguments: [target.runID]
                ),
                1
            )
        }
    }

    func testTSTORE01V072RejectsUndecodableCoverageJSON() throws {
        // T-STORE-01 review finding expected RED: the completion trigger calls
        // coverage valid after checking only four fields, so corpus_complete can
        // persist coverage that the required CorpusAnalysisCoverage type rejects.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic complete coverage schema 2027"
        )

        try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "incomplete-coverage-2027",
                digestDigit: "c",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-incomplete-coverage-slice-2027",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "c", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 113,
                revisionID: target.revisionID
            )
            let incompleteCoverage =
                #"{"schema_version":31,"excluded_members_disclosed":true,"partition_count":1,"succeeded_partition_count":1,"balance_error_count":0}"#
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    CorpusAnalysisCoverage.self,
                    from: Data(incompleteCoverage.utf8)
                ),
                "the fixture must remain observably incomplete for the domain schema"
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET status = 'persisted', assurance_state = 'corpus_complete',
                            coverage_json = ?
                        WHERE id = ?
                        """,
                    arguments: [incompleteCoverage, target.runID]
                ),
                "undecodable coverage must not cross the completion barrier"
            )
            try assertNotCorpusComplete(db, runID: target.runID)
        }
    }

    func testTSTORE02V072StalesLinkedExportVersionDespiteDriftedRunAssurance() throws {
        // T-STORE-02 review finding expected RED: the migration selects linked
        // versions through the run's assurance value. If that value drifted weak
        // while the linked version stayed corpus_complete, the actual export gate
        // survives v072 even though the legacy run has no exact request lineage.
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v071_create_draft_artifact_intents")
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic drifted legacy assurance 2039"
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let output = try outputs.createOutput(
            matterID: matter.id,
            title: "Drifted legacy exact proof 2039",
            outputType: .documentExhaustiveList
        )
        let version = try outputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "# Preserved drifted legacy output\n\nSynthetic value 2039 [S2039].",
            requiredSections: ["Synthetic value 2039"],
            presentSections: ["Synthetic value 2039"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "legacy-drift-verifier/2039",
            verificationResults: [try supportedResult(sourceID: "legacy-drift-source-2039")],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_203_901),
            promptBuilderVersion: "legacy-drift-prompt/2039",
            assuranceState: .corpusComplete,
            outputStatus: .complete
        )
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, model_lineage_json, status,
                        assurance_state, structured_output_version_id,
                        created_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "t-store-02-drifted-run-2039",
                    "t-store-02-drifted-key-2039",
                    matter.id,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    #"{"document_ids":["legacy-drift-document-2039"],"schema_version":37}"#,
                    #"{"schema_version":37,"members":[{"member_key":"legacy-drift-member-2039","document_id":"legacy-drift-document-2039","display_name":"Legacy-drift-2039.txt","revision_ids":["legacy-drift-revision-2039"],"index_state":"ready","disposition":"eligible"}]}"#,
                    "part_range:characters=2039",
                    1,
                    #"{"repository":"synthetic/drift-model","revision":"legacy-drift-2039"}"#,
                    CorpusAnalysisRunStatus.persisted.rawValue,
                    OutputAssuranceState.corpusIncomplete.rawValue,
                    version.id,
                    Date(timeIntervalSince1970: 1_790_203_801),
                    Date(timeIntervalSince1970: 1_790_203_901),
                ]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let migratedRun = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(db, key: "t-store-02-drifted-run-2039")
            )
            XCTAssertNil(migratedRun.requestSchemaVersion)
            XCTAssertNil(migratedRun.requestDigest)
            XCTAssertEqual(
                migratedRun.assuranceState,
                OutputAssuranceState.corpusIncomplete.rawValue,
                "the already-weak run does not need fabricated stronger or different assurance"
            )

            let migratedVersion = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: version.id)
            )
            XCTAssertEqual(migratedVersion.assuranceState, OutputAssuranceState.stale.rawValue)
            XCTAssertNotEqual(
                migratedVersion.assuranceState,
                OutputAssuranceState.corpusComplete.rawValue,
                "the legacy export-eligible default must be absent after fail-closed migration"
            )
            let assurance = migratedVersion.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
            XCTAssertFalse(assurance.map(OutputAssurancePresentation.isExportEligible) ?? true)
            let migratedOutput = try XCTUnwrap(StructuredOutputRecord.fetchOne(db, key: output.id))
            XCTAssertEqual(migratedOutput.status, StructuredOutputStatus.needsReview.rawValue)
            XCTAssertNotEqual(migratedOutput.status, StructuredOutputStatus.complete.rawValue)
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
                "{\"schema_version\":7,\"members\":[{\"member_key\":\"\(memberKey)\",\"document_id\":\"\(documentID)\",\"display_name\":\"Synthetic-\(caseName).txt\",\"revision_ids\":[\"\(revisionID)\"],\"index_state\":\"ready\",\"disposition\":\"eligible\"}]}",
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

    private func insertCompletionMatrixRun(
        _ db: Database,
        matterID: String,
        caseName: String,
        digestDigit: String,
        members: [CompletionMemberSpec]
    ) throws -> CompletionMatrixFixture {
        let runID = "t-store-01-matrix-\(caseName)-run"
        let snapshotMembers: [[String: Any]] = members.map { member in
            [
                "member_key": member.memberKey,
                "document_id": member.documentID,
                "display_name": "Synthetic-\(member.memberKey).txt",
                "revision_ids": member.revisions.map(\.id),
                "index_state": "ready",
                "disposition": "eligible",
            ]
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: ["members": snapshotMembers, "schema_version": 7],
            options: [.sortedKeys]
        )
        let scopeData = try JSONSerialization.data(
            withJSONObject: [
                "document_ids": members.map(\.documentID),
                "schema_version": 7,
            ],
            options: [.sortedKeys]
        )
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
                runID, "t-store-01-matrix-\(caseName)-key", matterID,
                CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                String(decoding: scopeData, as: UTF8.self),
                String(decoding: snapshotData, as: UTF8.self),
                "exact_revision_slice", 2, 2,
                String(repeating: digestDigit, count: 64),
                CorpusAnalysisRunStatus.planning.rawValue,
                Date(timeIntervalSince1970: 1_790_000_600),
            ]
        )

        var targets: [CompletionSliceTarget] = []
        for member in members {
            for (index, revision) in member.revisions.enumerated() {
                let partitionID = "t-store-01-matrix-\(caseName)-partition-\(targets.count)"
                let revisionIDsData = try JSONSerialization.data(
                    withJSONObject: [revision.id],
                    options: [.sortedKeys]
                )
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_partitions (
                            id, run_id, partition_key, input_revision_ids_json, disposition
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        partitionID, runID, "\(member.memberKey)#revision:\(index)",
                        String(decoding: revisionIDsData, as: UTF8.self),
                        CorpusAnalysisPartitionDisposition.succeeded.rawValue,
                    ]
                )
                targets.append(
                    CompletionSliceTarget(
                        runID: runID,
                        partitionID: partitionID,
                        memberKey: member.memberKey,
                        documentID: member.documentID,
                        revision: revision
                    ))
            }
        }
        return CompletionMatrixFixture(runID: runID, targets: targets)
    }

    private func insertFullSlice(
        _ db: Database,
        target: CompletionSliceTarget,
        id: String,
        digestDigit: String
    ) throws {
        try insertSlice(
            db,
            id: id,
            partitionID: target.partitionID,
            ordinal: 0,
            charStart: 0,
            charEnd: target.revision.charCount,
            revisionCharCount: target.revision.charCount,
            textSHA256: String(repeating: digestDigit, count: 64),
            runID: target.runID,
            memberKey: target.memberKey,
            documentID: target.documentID,
            partIndex: target.revision.partIndex,
            revisionID: target.revision.id
        )
    }

    private func persistCorpusComplete(
        _ db: Database,
        runID: String,
        exclusionsDisclosed: Bool,
        partitionCount: Int = 1
    ) throws {
        let coverageJSON = try completeCoverageJSON(
            db,
            runID: runID,
            exclusionsDisclosed: exclusionsDisclosed,
            partitionCount: partitionCount
        )
        try db.execute(
            sql: """
                UPDATE corpus_analysis_runs
                SET status = ?, assurance_state = ?, coverage_json = ?
                WHERE id = ?
                """,
            arguments: [
                CorpusAnalysisRunStatus.persisted.rawValue,
                OutputAssuranceState.corpusComplete.rawValue,
                coverageJSON,
                runID,
            ]
        )
    }

    private func completeCoverageJSON(
        _ db: Database,
        runID: String,
        exclusionsDisclosed: Bool,
        partitionCount: Int
    ) throws -> String {
        let snapshotMemberCount = try XCTUnwrap(
            Int.fetchOne(
                db,
                sql: """
                    SELECT json_array_length(corpus_snapshot_json, '$.members')
                    FROM corpus_analysis_runs WHERE id = ?
                    """,
                arguments: [runID]
            )
        )
        let eligibleMemberCount = try XCTUnwrap(
            Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM corpus_analysis_runs AS run,
                         json_each(run.corpus_snapshot_json, '$.members') AS member
                    WHERE run.id = ?
                      AND json_extract(member.value, '$.disposition') = 'eligible'
                    """,
                arguments: [runID]
            )
        )
        let excludedMemberCount = try XCTUnwrap(
            Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM corpus_analysis_runs AS run,
                         json_each(run.corpus_snapshot_json, '$.members') AS member
                    WHERE run.id = ?
                      AND json_extract(member.value, '$.disposition') = 'excluded'
                    """,
                arguments: [runID]
            )
        )
        let coverage = CorpusAnalysisCoverage(
            schemaVersion: 37,
            snapshotMemberCount: snapshotMemberCount,
            eligibleMemberCount: eligibleMemberCount,
            excludedMemberCount: excludedMemberCount,
            excludedMembersDisclosed: exclusionsDisclosed,
            partitionCount: partitionCount,
            pendingPartitionCount: 0,
            succeededPartitionCount: partitionCount,
            failedPartitionCount: 0,
            cancelledPartitionCount: 0,
            excludedPartitionCount: 0,
            terminalPartitionCount: partitionCount,
            balanceErrorCount: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(coverage), as: UTF8.self)
    }

    private func assertNotCorpusComplete(
        _ db: Database,
        runID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let run = try XCTUnwrap(
            CorpusAnalysisRunRecord.fetchOne(db, key: runID), file: file, line: line)
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.planning.rawValue, file: file, line: line)
        XCTAssertNotEqual(
            run.assuranceState, OutputAssuranceState.corpusComplete.rawValue, file: file, line: line)
    }

    private func foreignKeyContracts(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        let groups = Dictionary(grouping: rows) { row in row["id"] as Int }
        return Set(
            groups.values.map { rows in
                let ordered = rows.sorted { lhs, rhs in
                    (lhs["seq"] as Int) < (rhs["seq"] as Int)
                }
                let sourceColumns = ordered.map { $0["from"] as String }.joined(separator: ",")
                let targetColumns = ordered.map { $0["to"] as String }.joined(separator: ",")
                let targetTable = ordered[0]["table"] as String
                let onDelete = ordered[0]["on_delete"] as String
                return "\(sourceColumns)->\(targetTable):\(targetColumns):\(onDelete)"
            })
    }

    private func uniqueIndexColumnSets(_ db: Database, table: String) throws -> Set<[String]> {
        let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
        var result = Set<[String]>()
        for index in indexes where (index["unique"] as Int) == 1 {
            let name = index["name"] as String
            let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                .sorted { lhs, rhs in (lhs["seqno"] as Int) < (rhs["seqno"] as Int) }
                .map { $0["name"] as String }
            result.insert(columns)
        }
        return result
    }

    private func supportedResult(sourceID: String) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "legacy-proposition-97",
            status: .supported,
            reasons: ["synthetic_legacy_support"],
            evidence: [
                SupportEvidence(
                    sourceID: sourceID,
                    sourceLabel: "S97",
                    locator: "Legacy-97.txt, part 13, characters 113–389",
                    retainedExcerpt: "Synthetic retained legacy evidence value 97.",
                    verifierName: "LegacyCorpusVerifier",
                    verifierVersion: "legacy-corpus-verifier/7"
                )
            ],
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

private struct CompletionRevisionSpec {
    let id: String
    let partIndex: Int
    let charCount: Int
}

private struct CompletionMemberSpec {
    let memberKey: String
    let documentID: String
    let revisions: [CompletionRevisionSpec]
}

private struct CompletionSliceTarget {
    let runID: String
    let partitionID: String
    let memberKey: String
    let documentID: String
    let revision: CompletionRevisionSpec
}

private struct CompletionMatrixFixture {
    let runID: String
    let targets: [CompletionSliceTarget]
}
