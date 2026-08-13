import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest
final class CorpusIntegrityMigrationTests: XCTestCase {
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
                try markPartitionSucceededWithCoherentAttempt(
                    db,
                    partitionID: exact.partitionID,
                    timestampMarker: 541
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
                "v073_create_case_file_review_projects"
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

    func testTSTORE02V072DoesNotExpandExactCorpusEnforcementIntoChronology() throws {
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
                "the exact-corpus integrity migration must not revoke chronology assurance"
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
                        id, run_id, partition_key, input_revision_ids_json
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    duplicatePartitionID,
                    target.runID,
                    "duplicate-part-index-89#revision:\(target.revisionID)",
                    "[\"\(target.revisionID)\"]",
                ]
            )
            try markPartitionSucceededWithCoherentAttempt(
                db,
                partitionID: duplicatePartitionID,
                timestampMarker: 1_991
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

    func testTSTORE01V072KeepsLinkedStrongExportAndFinalProofLifecycleAtomic() throws {
        // T-STORE-01 review finding expected RED: downgrading or deleting the run
        // disables/cascades the child-ledger guards without changing the linked
        // version, so the actual export gate remains corpus-complete after its
        // exact proof has become mutable or has disappeared.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic linked proof lifecycle 2053"
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let downgradeArtifact = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "downgrade-2053",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let deleteArtifact = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "delete-2063",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let downgradeRunID: String = try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "linked-downgrade-2053",
                digestDigit: "d",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-linked-downgrade-slice-2053",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "d", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 127,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [downgradeArtifact.version.id, target.runID]
            )
            return target.runID
        }
        let deleteRunID: String = try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "linked-delete-2063",
                digestDigit: "e",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-linked-delete-slice-2063",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "e", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 131,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [deleteArtifact.version.id, target.runID]
            )
            return target.runID
        }

        var downgradeError: Error?
        do {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET assurance_state = 'stale' WHERE id = ?",
                    arguments: [downgradeRunID]
                )
            }
        } catch {
            downgradeError = error
        }
        try queue.read { db in
            let run = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: downgradeRunID))
            let version = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: downgradeArtifact.version.id)
            )
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: downgradeArtifact.output.id)
            )
            if downgradeError != nil {
                XCTAssertEqual(run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: [downgradeRunID]
                    ),
                    1,
                    "a rejected downgrade must leave the exact proof ledger intact"
                )
            } else {
                XCTAssertEqual(run.assuranceState, OutputAssuranceState.stale.rawValue)
                XCTAssertEqual(
                    version.assuranceState,
                    OutputAssuranceState.stale.rawValue,
                    "an accepted run downgrade must atomically stale the linked export version"
                )
                XCTAssertNotEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertNotNil(version.staleReason)
                let assurance = version.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
                XCTAssertFalse(assurance.map(OutputAssurancePresentation.isExportEligible) ?? true)
                XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
                XCTAssertNotEqual(output.status, StructuredOutputStatus.complete.rawValue)
            }
        }

        var deleteError: Error?
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM corpus_analysis_runs WHERE id = ?",
                    arguments: [deleteRunID]
                )
            }
        } catch {
            deleteError = error
        }
        try queue.read { db in
            let version = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: deleteArtifact.version.id)
            )
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: deleteArtifact.output.id)
            )
            if deleteError != nil {
                XCTAssertNotNil(try CorpusAnalysisRunRecord.fetchOne(db, key: deleteRunID))
                XCTAssertEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: [deleteRunID]
                    ),
                    1,
                    "a rejected delete must leave the exact proof ledger intact"
                )
            } else {
                XCTAssertNil(try CorpusAnalysisRunRecord.fetchOne(db, key: deleteRunID))
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                        arguments: [deleteRunID]
                    ),
                    0
                )
                XCTAssertEqual(
                    version.assuranceState,
                    OutputAssuranceState.stale.rawValue,
                    "an accepted proof deletion must atomically stale the surviving export version"
                )
                XCTAssertNotEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertNotNil(version.staleReason)
                let assurance = version.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
                XCTAssertFalse(assurance.map(OutputAssurancePresentation.isExportEligible) ?? true)
                XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
                XCTAssertNotEqual(output.status, StructuredOutputStatus.complete.rawValue)
            }
        }
    }

    func testTSTORE01V072MakesOutputAttachmentOneTimeAndSemanticallyScoped() throws {
        // T-STORE-01 review finding expected RED: structured_output_version_id is
        // excluded from the finalized-root guard, so direct SQL can clear/relink
        // it or initially attach a cross-matter, wrong-output-type, or mismatched-
        // assurance version. Only nil-to-one compatible exhaustive version is valid.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matters = MattersRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic scoped attachment 2081")
        let foreignMatter = try matters.createMatter(name: "Synthetic foreign attachment 2083")
        let outputs = StructuredOutputRepository(writer: queue)
        let relinkInitial = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "relink-initial-2081",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let relinkReplacement = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "relink-replacement-2083",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let clearInitial = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "clear-initial-2087",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let crossMatter = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: foreignMatter.id,
            marker: "cross-matter-2089",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let wrongType = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "wrong-type-2099",
            outputType: .documentQA,
            assuranceState: .corpusComplete
        )
        let wrongAssurance = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "wrong-assurance-2111",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusIncomplete
        )

        let runIDs: [String: String] = try queue.write { db in
            func makeFinalRun(caseName: String, digit: String, partIndex: Int) throws -> String {
                let target = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: caseName,
                    digestDigit: digit,
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-attachment-\(caseName)-slice",
                    partitionID: target.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: digit, count: 64),
                    runID: target.runID,
                    memberKey: target.memberKey,
                    documentID: target.documentID,
                    partIndex: partIndex,
                    revisionID: target.revisionID
                )
                try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
                return target.runID
            }

            let relink = try makeFinalRun(
                caseName: "attachment-relink-2081", digit: "1", partIndex: 137
            )
            let clear = try makeFinalRun(
                caseName: "attachment-clear-2087", digit: "2", partIndex: 139
            )
            let cross = try makeFinalRun(
                caseName: "attachment-cross-2089", digit: "3", partIndex: 149
            )
            let type = try makeFinalRun(
                caseName: "attachment-type-2099", digit: "4", partIndex: 151
            )
            let assurance = try makeFinalRun(
                caseName: "attachment-assurance-2111", digit: "5", partIndex: 157
            )
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [relinkInitial.version.id, relink]
            )
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [clearInitial.version.id, clear]
            )
            return [
                "relink": relink,
                "clear": clear,
                "cross": cross,
                "type": type,
                "assurance": assurance,
            ]
        }
        let relinkRunID = try XCTUnwrap(runIDs["relink"])
        let clearRunID = try XCTUnwrap(runIDs["clear"])
        let crossRunID = try XCTUnwrap(runIDs["cross"])
        let typeRunID = try XCTUnwrap(runIDs["type"])
        let assuranceRunID = try XCTUnwrap(runIDs["assurance"])

        try queue.read { db in
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: relinkRunID)?.structuredOutputVersionID,
                relinkInitial.version.id,
                "the legitimate nil-to-compatible attachment must be present"
            )
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: clearRunID)?.structuredOutputVersionID,
                clearInitial.version.id,
                "the second legitimate nil-to-compatible attachment must be present"
            )
        }

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [relinkReplacement.version.id, relinkRunID]
                )
            },
            "a finalized run's first valid attachment must not be replaced"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = NULL WHERE id = ?",
                    arguments: [clearRunID]
                )
            },
            "a finalized run's first valid attachment must not be cleared"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [crossMatter.version.id, crossRunID]
                )
            },
            "a finalized run must not attach an export version from another matter"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [wrongType.version.id, typeRunID]
                )
            },
            "an exhaustive run must not attach a document-QA version"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [wrongAssurance.version.id, assuranceRunID]
                )
            },
            "the attached version assurance must equal the finalized run assurance"
        )

        try queue.read { db in
            let relink = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: relinkRunID))
            XCTAssertEqual(relink.structuredOutputVersionID, relinkInitial.version.id)
            XCTAssertNotEqual(relink.structuredOutputVersionID, relinkReplacement.version.id)
            let clear = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: clearRunID))
            XCTAssertEqual(clear.structuredOutputVersionID, clearInitial.version.id)
            XCTAssertNotNil(clear.structuredOutputVersionID)
            let cross = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: crossRunID))
            XCTAssertNil(cross.structuredOutputVersionID)
            XCTAssertNotEqual(cross.structuredOutputVersionID, crossMatter.version.id)
            let type = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: typeRunID))
            XCTAssertNil(type.structuredOutputVersionID)
            XCTAssertNotEqual(type.structuredOutputVersionID, wrongType.version.id)
            let assurance = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: assuranceRunID))
            XCTAssertNil(assurance.structuredOutputVersionID)
            XCTAssertNotEqual(assurance.structuredOutputVersionID, wrongAssurance.version.id)
        }
    }

    func testTSTORE01V072RequiresUniqueAttachmentAcrossRunAndInsertBoundaries() throws {
        // T-STORE-01 final audit expected RED: the update guard validates the
        // target version but does not prove that one version belongs to only one
        // run, and direct INSERT can bypass the update-only attachment guard.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic unique attachment boundary 2161"
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let sharedArtifact = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "shared-version-2161",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let wrongInsertArtifact = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "wrong-insert-type-2167",
            outputType: .documentQA,
            assuranceState: .corpusIncomplete
        )

        try queue.write { db in
            func makeFinalRun(caseName: String, digit: String, partIndex: Int) throws -> String {
                let target = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: caseName,
                    digestDigit: digit,
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-unique-\(caseName)-slice",
                    partitionID: target.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: digit, count: 64),
                    runID: target.runID,
                    memberKey: target.memberKey,
                    documentID: target.documentID,
                    partIndex: partIndex,
                    revisionID: target.revisionID
                )
                try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
                return target.runID
            }

            let ownerRunID = try makeFinalRun(
                caseName: "unique-owner-2161", digit: "b", partIndex: 191
            )
            let foreignRunID = try makeFinalRun(
                caseName: "unique-foreign-2163", digit: "c", partIndex: 193
            )
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [sharedArtifact.version.id, ownerRunID]
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [sharedArtifact.version.id, foreignRunID]
                ),
                "one output version must not ambiguously claim two exact proof roots"
            )
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: ownerRunID)?.structuredOutputVersionID,
                sharedArtifact.version.id
            )
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(db, key: foreignRunID)?.structuredOutputVersionID
            )

            let insertedRunID = "t-store-01-direct-attachment-run-2167"
            var insertError: Error?
            do {
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_runs (
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, model_lineage_json,
                            request_schema_version, request_digest, status,
                            assurance_state, structured_output_version_id,
                            created_at, completed_at
                        ) VALUES (?, ?, ?, 'exhaustive_list', ?, ?, ?, 2, ?, 2, ?,
                            'persisted', 'corpus_incomplete', ?, ?, ?)
                        """,
                    arguments: [
                        insertedRunID,
                        "t-store-01-direct-attachment-key-2167",
                        matter.id,
                        #"{"document_ids":["direct-attachment-document-2167"],"schema_version":37}"#,
                        #"{"schema_version":37,"members":[{"member_key":"direct-attachment-member-2167","document_id":"direct-attachment-document-2167","display_name":"Direct-attachment-2167.txt","revision_ids":["direct-attachment-revision-2167"],"index_state":"ready","disposition":"eligible"}]}"#,
                        "exact_revision_slice:characters=2167",
                        #"{"model_repository":"synthetic/direct-attachment","model_revision":"revision-2167","model_artifact_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}"#,
                        String(repeating: "e", count: 64),
                        wrongInsertArtifact.version.id,
                        Date(timeIntervalSince1970: 1_790_321_607),
                        Date(timeIntervalSince1970: 1_790_321_667),
                    ]
                )
            } catch {
                insertError = error
            }
            XCTAssertNotNil(
                insertError,
                "direct INSERT must enforce the same exhaustive output attachment contract"
            )
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(db, key: insertedRunID),
                "the wrong-type direct attachment must remain absent"
            )
            if insertError == nil {
                try db.execute(
                    sql: "DELETE FROM corpus_analysis_runs WHERE id = ?",
                    arguments: [insertedRunID]
                )
            }
        }
    }

    func testTSTORE01V072RejectsLegacyRunSharingAnExactRunsOutputVersion() throws {
        // T-STORE-01 proof-ownership audit expected RED: uniqueness guards are
        // scoped only to the run being attached when that run is exact v2. A
        // chronology/v1 row can therefore attach, or be inserted already
        // attached, to a version that already belongs to an exact proof root.
        // Proof-owned versions must reject every second owner irrespective of
        // the candidate run's legacy classification.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic legacy proof ownership 2191"
        )
        let owner = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "legacy-proof-owner-2191",
            digestDigit: "d",
            partIndex: 199
        )

        try queue.write { db in
            let legacy = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "legacy-proof-candidate-2197",
                digestDigit: "e",
                disposition: .pending
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET task_kind = 'chronology', request_schema_version = NULL,
                        request_digest = NULL, partition_strategy = 'per_document:2197',
                        partition_strategy_version = 1
                    WHERE id = ?
                    """,
                arguments: [legacy.runID]
            )
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET structured_output_version_id = ?
                        WHERE id = ?
                        """,
                    arguments: [owner.version.id, legacy.runID]
                ),
                "a legacy update must not become a second owner of an exact proof version"
            )
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(db, key: legacy.runID)?
                    .structuredOutputVersionID
            )

            let insertedLegacyID = "t-store-01-inserted-legacy-owner-2203"
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_runs (
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, status,
                            structured_output_version_id, created_at
                        ) VALUES (?, ?, ?, 'chronology', '{}', ?, 'per_revision:2203',
                            1, 'planning', ?, ?)
                        """,
                    arguments: [
                        insertedLegacyID,
                        "t-store-01-inserted-legacy-owner-key-2203",
                        matter.id,
                        #"{"schema_version":1,"members":[]}"#,
                        owner.version.id,
                        Date(timeIntervalSince1970: 1_790_322_003),
                    ]
                ),
                "a legacy insert must not arrive as a second owner of an exact proof version"
            )
            XCTAssertNil(try CorpusAnalysisRunRecord.fetchOne(db, key: insertedLegacyID))
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: owner.runID)?
                    .structuredOutputVersionID,
                owner.version.id
            )
        }
    }

    func testTSTORE01V072AtomicPublisherRequiresSourceSetToMatchFrozenCorpusLineage() throws {
        // T-STORE-01 publication-lineage audit expected RED: the atomic
        // publisher checks only source-set matter identity before binding an
        // exact run. A pending source set whose corpus_snapshot_hash names a
        // different frozen corpus can therefore be published as that run's
        // active proof. The field must equal the deterministic lineage hash
        // recomputed from the run's frozen snapshot and normalized slices; it
        // remains deliberately independent from the broader request digest.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic atomic source lineage 2213"
        )
        let runs: (
            invalid: (id: String, lineageHash: String, requestDigest: String),
            valid: (id: String, lineageHash: String, requestDigest: String)
        ) = try queue.write { db in
            func makeFinalRun(
                caseName: String,
                digestDigit: String,
                partIndex: Int
            ) throws -> String {
                let target = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: caseName,
                    digestDigit: digestDigit,
                    disposition: .succeeded
                )
                try insertSlice(
                    db,
                    id: "t-store-01-source-lineage-\(caseName)-slice",
                    partitionID: target.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: digestDigit, count: 64),
                    runID: target.runID,
                    memberKey: target.memberKey,
                    documentID: target.documentID,
                    partIndex: partIndex,
                    revisionID: target.revisionID
                )
                try persistCorpusComplete(
                    db,
                    runID: target.runID,
                    exclusionsDisclosed: true
                )
                return target.runID
            }
            let invalidID = try makeFinalRun(
                    caseName: "source-lineage-invalid-2213",
                    digestDigit: "1",
                    partIndex: 211
                )
            let validID = try makeFinalRun(
                    caseName: "source-lineage-valid-2219",
                    digestDigit: "2",
                    partIndex: 223
                )
            let invalidRun = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(db, key: invalidID)
            )
            let validRun = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(db, key: validID)
            )
            return (
                (
                    invalidID,
                    try frozenCorpusLineageHash(db, runID: invalidID),
                    try XCTUnwrap(invalidRun.requestDigest)
                ),
                (
                    validID,
                    try frozenCorpusLineageHash(db, runID: validID),
                    try XCTUnwrap(validRun.requestDigest)
                )
            )
        }
        XCTAssertNotEqual(runs.invalid.lineageHash, runs.invalid.requestDigest)
        XCTAssertNotEqual(runs.valid.lineageHash, runs.valid.requestDigest)

        let outputs = StructuredOutputRepository(writer: queue)
        let invalidOutput = StructuredOutputRecord(
            id: "t-store-01-source-lineage-invalid-output-2213",
            matterID: matter.id,
            title: "Synthetic mismatched source lineage 2213",
            outputType: StructuredOutputType.documentExhaustiveList.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_322_113),
            updatedAt: Date(timeIntervalSince1970: 1_790_322_113)
        )
        let invalidSourceSet = DocumentSourceSetRecord(
            id: "t-store-01-source-lineage-invalid-set-2213",
            matterID: matter.id,
            mode: DocumentSourceSetMode.exhaustive.rawValue,
            scopeJSON: #"{"document_ids":["synthetic-source-lineage-2213"]}"#,
            retrievalQuery: "Synthetic mismatched source lineage 2213",
            corpusSnapshotHash: runs.valid.lineageHash,
            createdAt: Date(timeIntervalSince1970: 1_790_322_117)
        )
        XCTAssertThrowsError(
            try outputs.createVersionWithSourceSetAtomically(
                structuredOutputID: invalidOutput.id,
                newOutput: invalidOutput,
                sourceSet: invalidSourceSet,
                outputSources: [],
                contentMarkdown: "# Mismatched source lineage\n\nFOREIGN-SOURCE-LINEAGE-2213 [S97].",
                verificationStatus: .allSupported,
                verificationVersion: "source-lineage-verifier/2213",
                verificationResults: [try supportedResult(sourceID: "source-lineage-source-2213")],
                verificationDimensions: supportedDimensions(),
                outputStatus: .complete,
                corpusAnalysisRunID: runs.invalid.id,
                promptBuilderVersion: "source-lineage-prompt/2213",
                assuranceState: .corpusComplete
            ),
            "an exact publication must reject a source set from another frozen corpus"
        )
        try queue.read { db in
            XCTAssertNil(try StructuredOutputRecord.fetchOne(db, key: invalidOutput.id))
            XCTAssertNil(try DocumentSourceSetRecord.fetchOne(db, key: invalidSourceSet.id))
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(db, key: runs.invalid.id)?
                    .structuredOutputVersionID
            )
        }

        let invalidModeOutput = StructuredOutputRecord(
            id: "t-store-01-source-lineage-mode-output-2217",
            matterID: matter.id,
            title: "Synthetic non-exhaustive source lineage 2217",
            outputType: StructuredOutputType.documentExhaustiveList.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_322_117),
            updatedAt: Date(timeIntervalSince1970: 1_790_322_117)
        )
        let invalidModeSourceSet = DocumentSourceSetRecord(
            id: "t-store-01-source-lineage-mode-set-2217",
            matterID: matter.id,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: #"{"document_ids":["synthetic-source-lineage-2217"]}"#,
            retrievalQuery: "Synthetic non-exhaustive source lineage 2217",
            corpusSnapshotHash: runs.valid.lineageHash,
            createdAt: Date(timeIntervalSince1970: 1_790_322_118)
        )
        XCTAssertThrowsError(
            try outputs.createVersionWithSourceSetAtomically(
                structuredOutputID: invalidModeOutput.id,
                newOutput: invalidModeOutput,
                sourceSet: invalidModeSourceSet,
                outputSources: [],
                contentMarkdown: "# Non-exhaustive source lineage\n\nWRONG-SOURCE-MODE-2217 [S97].",
                verificationStatus: .allSupported,
                verificationVersion: "source-lineage-verifier/2217",
                verificationResults: [try supportedResult(sourceID: "source-lineage-source-2217")],
                verificationDimensions: supportedDimensions(),
                outputStatus: .complete,
                corpusAnalysisRunID: runs.valid.id,
                promptBuilderVersion: "source-lineage-prompt/2217",
                assuranceState: .corpusComplete
            ),
            "an exact publication must use an exhaustive frozen source set"
        )
        try queue.read { db in
            XCTAssertNil(try StructuredOutputRecord.fetchOne(db, key: invalidModeOutput.id))
            XCTAssertNil(try DocumentSourceSetRecord.fetchOne(db, key: invalidModeSourceSet.id))
            XCTAssertNil(
                try CorpusAnalysisRunRecord.fetchOne(db, key: runs.valid.id)?
                    .structuredOutputVersionID
            )
        }

        let validOutput = StructuredOutputRecord(
            id: "t-store-01-source-lineage-valid-output-2219",
            matterID: matter.id,
            title: "Synthetic matching source lineage 2219",
            outputType: StructuredOutputType.documentExhaustiveList.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_322_119),
            updatedAt: Date(timeIntervalSince1970: 1_790_322_119)
        )
        let validSourceSet = DocumentSourceSetRecord(
            id: "t-store-01-source-lineage-valid-set-2219",
            matterID: matter.id,
            mode: DocumentSourceSetMode.exhaustive.rawValue,
            scopeJSON: #"{"document_ids":["synthetic-source-lineage-2219"]}"#,
            retrievalQuery: "Synthetic matching source lineage 2219",
            corpusSnapshotHash: runs.valid.lineageHash,
            createdAt: Date(timeIntervalSince1970: 1_790_322_127)
        )
        let validVersion = try outputs.createVersionWithSourceSetAtomically(
            structuredOutputID: validOutput.id,
            newOutput: validOutput,
            sourceSet: validSourceSet,
            outputSources: [],
            contentMarkdown: "# Matching source lineage\n\nMATCHING-SOURCE-LINEAGE-2219 [S97].",
            verificationStatus: .allSupported,
            verificationVersion: "source-lineage-verifier/2219",
            verificationResults: [try supportedResult(sourceID: "source-lineage-source-2219")],
            verificationDimensions: supportedDimensions(),
            outputStatus: .complete,
            corpusAnalysisRunID: runs.valid.id,
            promptBuilderVersion: "source-lineage-prompt/2219",
            assuranceState: .corpusComplete
        )
        XCTAssertEqual(validVersion.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        try queue.read { db in
            let storedSet = try XCTUnwrap(
                DocumentSourceSetRecord.fetchOne(db, key: validSourceSet.id)
            )
            XCTAssertEqual(storedSet.corpusSnapshotHash, runs.valid.lineageHash)
            XCTAssertEqual(storedSet.structuredOutputVersionID, validVersion.id)
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: runs.valid.id)?
                    .structuredOutputVersionID,
                validVersion.id
            )
            XCTAssertEqual(
                try StructuredOutputRecord.fetchOne(db, key: validOutput.id)?.activeVersionID,
                validVersion.id
            )
        }
        XCTAssertNotEqual(runs.invalid.lineageHash, invalidSourceSet.corpusSnapshotHash)
    }

    func testTSTORE01V072KeepsLinkedOutputAssuranceAndParentIdentityConsistent() throws {
        // T-STORE-01 output-projection audit expected RED: the exact-run guards
        // protect only the run-to-version link. Direct version/output updates can
        // still leave a corpus-complete public projection with NULL or mismatched
        // assurance, a foreign matter, or the document-QA output type.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matters = MattersRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic linked projection 2203")
        let foreignMatter = try matters.createMatter(name: "Foreign linked projection 2207")
        let nullFixture = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "null-assurance-2203",
            digestDigit: "1",
            partIndex: 203
        )
        let mismatchedFixture = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "mismatched-assurance-2207",
            digestDigit: "2",
            partIndex: 211
        )
        let parentFixture = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "parent-identity-2213",
            digestDigit: "3",
            partIndex: 223
        )

        var nullError: Error?
        do {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_output_versions SET assurance_state = NULL WHERE id = ?",
                    arguments: [nullFixture.version.id]
                )
            }
        } catch {
            nullError = error
        }
        try queue.read { db in
            let version = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: nullFixture.version.id)
            )
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: nullFixture.output.id)
            )
            if nullError != nil {
                XCTAssertEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
            } else {
                XCTAssertEqual(
                    version.assuranceState,
                    OutputAssuranceState.stale.rawValue,
                    "an accepted assurance change must atomically revoke the linked export"
                )
                XCTAssertNotNil(version.assuranceState)
                XCTAssertNotNil(version.staleReason)
                XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
                XCTAssertNotEqual(output.status, StructuredOutputStatus.complete.rawValue)
            }
        }

        var mismatchError: Error?
        do {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_output_versions SET assurance_state = ? WHERE id = ?",
                    arguments: [
                        OutputAssuranceState.propositionSupported.rawValue,
                        mismatchedFixture.version.id,
                    ]
                )
            }
        } catch {
            mismatchError = error
        }
        try queue.read { db in
            let version = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: mismatchedFixture.version.id)
            )
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: mismatchedFixture.output.id)
            )
            if mismatchError != nil {
                XCTAssertEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
                XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
            } else {
                XCTAssertEqual(
                    version.assuranceState,
                    OutputAssuranceState.stale.rawValue,
                    "an accepted mismatched strong state must atomically revoke the linked export"
                )
                XCTAssertNotEqual(
                    version.assuranceState,
                    OutputAssuranceState.propositionSupported.rawValue
                )
                XCTAssertNotNil(version.staleReason)
                XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
                XCTAssertNotEqual(output.status, StructuredOutputStatus.complete.rawValue)
            }
        }

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_outputs SET matter_id = ? WHERE id = ?",
                    arguments: [foreignMatter.id, parentFixture.output.id]
                )
            },
            "a linked exhaustive output must not move to a foreign matter"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_outputs SET output_type = ? WHERE id = ?",
                    arguments: [StructuredOutputType.documentQA.rawValue, parentFixture.output.id]
                )
            },
            "a linked exhaustive output must not change into a document-QA output"
        )
        try queue.read { db in
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: parentFixture.output.id)
            )
            XCTAssertEqual(output.matterID, matter.id)
            XCTAssertNotEqual(output.matterID, foreignMatter.id)
            XCTAssertEqual(output.outputType, StructuredOutputType.documentExhaustiveList.rawValue)
            XCTAssertNotEqual(output.outputType, StructuredOutputType.documentQA.rawValue)
            XCTAssertEqual(output.activeVersionID, parentFixture.version.id)
        }
    }

    func testTSTORE01V072MakesLinkedVersionIdentityContentAndVerificationAppendOnly() throws {
        // T-STORE-01 output-projection audit expected RED: a linked exact version
        // is still a mutable row. Its owner/index/parent identity, retained content,
        // and verification receipt can be rewritten in place without a new version.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic append-only linked version 2237"
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let emptyDecoy = try outputs.createOutput(
            matterID: matter.id,
            title: "Empty identity decoy 2239",
            outputType: .documentExhaustiveList
        )
        let parentDecoy = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "parent-decoy-2243",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let identity = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "identity-2243",
            digestDigit: "4",
            partIndex: 227
        )
        let content = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "content-2249",
            digestDigit: "5",
            partIndex: 229
        )
        let verification = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "verification-2251",
            digestDigit: "6",
            partIndex: 233
        )
        let persistedIdentityCreatedAt = try queue.read { db in
            try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: identity.version.id)
            ).createdAt
        }

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE structured_output_versions
                        SET structured_output_id = ?, version_index = 2243,
                            parent_version_id = ?, created_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        emptyDecoy.id,
                        parentDecoy.version.id,
                        Date(timeIntervalSince1970: 1_790_522_443),
                        identity.version.id,
                    ]
                )
            },
            "linked version identity must be append-only"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE structured_output_versions
                        SET content_markdown = '# FORGED-CONTENT-2249',
                            required_sections_json = '["FORGED-REQUIRED-2249"]',
                            present_sections_json = '["FORGED-PRESENT-2249"]',
                            missing_sections_json = '["FORGED-MISSING-2249"]',
                            repair_reason = 'FORGED-REPAIR-2249'
                        WHERE id = ?
                        """,
                    arguments: [content.version.id]
                )
            },
            "linked version content must be replaced by an appended version, not rewritten"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE structured_output_versions
                        SET verification_status = 'needs_review',
                            verification_version = 'forged-verifier/2251',
                            verification_json = '[]',
                            verification_dimensions_json = '{}',
                            verified_at = ?, prompt_builder_version = 'forged-prompt/2251'
                        WHERE id = ?
                        """,
                    arguments: [
                        Date(timeIntervalSince1970: 1_790_522_551),
                        verification.version.id,
                    ]
                )
            },
            "linked version verification evidence must be append-only"
        )

        try queue.read { db in
            let retainedIdentity = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: identity.version.id)
            )
            XCTAssertEqual(retainedIdentity.structuredOutputID, identity.output.id)
            XCTAssertNotEqual(retainedIdentity.structuredOutputID, emptyDecoy.id)
            XCTAssertEqual(retainedIdentity.versionIndex, identity.version.versionIndex)
            XCTAssertNotEqual(retainedIdentity.versionIndex, 2243)
            XCTAssertEqual(retainedIdentity.parentVersionID, identity.version.parentVersionID)
            XCTAssertNotEqual(retainedIdentity.parentVersionID, parentDecoy.version.id)
            XCTAssertEqual(retainedIdentity.createdAt, persistedIdentityCreatedAt)

            let retainedContent = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: content.version.id)
            )
            XCTAssertEqual(retainedContent.contentMarkdown, content.version.contentMarkdown)
            XCTAssertFalse(retainedContent.contentMarkdown.contains("FORGED-CONTENT-2249"))
            XCTAssertEqual(retainedContent.requiredSectionsJSON, content.version.requiredSectionsJSON)
            XCTAssertFalse(retainedContent.requiredSectionsJSON.contains("FORGED-REQUIRED-2249"))
            XCTAssertEqual(retainedContent.presentSectionsJSON, content.version.presentSectionsJSON)
            XCTAssertEqual(retainedContent.missingSectionsJSON, content.version.missingSectionsJSON)
            XCTAssertEqual(retainedContent.repairReason, content.version.repairReason)

            let retainedVerification = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: verification.version.id)
            )
            XCTAssertEqual(
                retainedVerification.verificationStatus,
                OutputVerificationStatus.allSupported.rawValue
            )
            XCTAssertNotEqual(
                retainedVerification.verificationStatus,
                OutputVerificationStatus.needsReview.rawValue
            )
            XCTAssertEqual(
                retainedVerification.verificationVersion,
                verification.version.verificationVersion
            )
            XCTAssertNotEqual(retainedVerification.verificationVersion, "forged-verifier/2251")
            XCTAssertEqual(retainedVerification.verificationJSON, verification.version.verificationJSON)
            XCTAssertNotEqual(retainedVerification.verificationJSON, "[]")
            XCTAssertEqual(
                retainedVerification.verificationDimensionsJSON,
                verification.version.verificationDimensionsJSON
            )
            XCTAssertNotEqual(retainedVerification.verificationDimensionsJSON, "{}")
            XCTAssertEqual(retainedVerification.verifiedAt, verification.version.verifiedAt)
            XCTAssertEqual(
                retainedVerification.promptBuilderVersion,
                verification.version.promptBuilderVersion
            )
            XCTAssertNotEqual(retainedVerification.promptBuilderVersion, "forged-prompt/2251")
        }
    }

    func testTSTORE01V072ProtectsLinkedGraphAndRequiresProofLinkedActiveVersion() throws {
        // T-STORE-01 output-graph audit expected RED: deleting a linked version
        // or its parent can clear the run's SET NULL foreign key and permit a
        // new proof link, while active_version_id can point at any unlinked
        // all-supported corpus-complete version. Only matter deletion may cascade.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic linked output graph 2267"
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let versionDelete = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "version-delete-2267",
            digestDigit: "7",
            partIndex: 239
        )
        let versionReplacement = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "version-replacement-2269",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let outputDelete = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "output-delete-2273",
            digestDigit: "8",
            partIndex: 241
        )
        let outputReplacement = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "output-replacement-2279",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM structured_output_versions WHERE id = ?",
                    arguments: [versionDelete.version.id]
                )
            },
            "a linked proof version cannot be deleted directly"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [versionReplacement.version.id, versionDelete.runID]
                )
            },
            "version deletion must not clear the link and permit replacement proof"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM structured_outputs WHERE id = ?",
                    arguments: [outputDelete.output.id]
                )
            },
            "a linked proof's parent output cannot be deleted directly"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                    arguments: [outputReplacement.version.id, outputDelete.runID]
                )
            },
            "parent deletion must not clear the link and permit replacement proof"
        )
        try queue.read { db in
            XCTAssertNotNil(
                try StructuredOutputVersionRecord.fetchOne(db, key: versionDelete.version.id)
            )
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: versionDelete.runID)?
                    .structuredOutputVersionID,
                versionDelete.version.id
            )
            XCTAssertNotEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: versionDelete.runID)?
                    .structuredOutputVersionID,
                versionReplacement.version.id
            )
            XCTAssertNotNil(try StructuredOutputRecord.fetchOne(db, key: outputDelete.output.id))
            XCTAssertNotNil(
                try StructuredOutputVersionRecord.fetchOne(db, key: outputDelete.version.id)
            )
            XCTAssertEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: outputDelete.runID)?
                    .structuredOutputVersionID,
                outputDelete.version.id
            )
            XCTAssertNotEqual(
                try CorpusAnalysisRunRecord.fetchOne(db, key: outputDelete.runID)?
                    .structuredOutputVersionID,
                outputReplacement.version.id
            )
        }

        let activeFixture = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "active-link-2281",
            digestDigit: "9",
            partIndex: 251
        )
        let unlinkedVersion = try outputs.createVersion(
            structuredOutputID: activeFixture.output.id,
            contentMarkdown: "# UNLINKED-ACTIVE-2281\n\nForeign active candidate [S97].",
            requiredSections: ["UNLINKED-ACTIVE-2281"],
            presentSections: ["UNLINKED-ACTIVE-2281"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "unlinked-active-verifier/2281",
            verificationResults: [try supportedResult(sourceID: "unlinked-active-source-2281")],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_522_881),
            promptBuilderVersion: "unlinked-active-prompt/2281",
            assuranceState: .corpusComplete,
            makeActive: false
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_outputs SET active_version_id = ? WHERE id = ?",
                    arguments: [unlinkedVersion.id, activeFixture.output.id]
                )
            },
            "an exhaustive output's active version must be linked to its exact proof run"
        )
        try queue.read { db in
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: activeFixture.output.id)
            )
            XCTAssertEqual(output.activeVersionID, activeFixture.version.id)
            XCTAssertNotEqual(output.activeVersionID, unlinkedVersion.id)
        }

        let prelinkedOutput = try outputs.createOutput(
            matterID: matter.id,
            title: "Synthetic prelinked activation 2287",
            outputType: .documentExhaustiveList
        )
        let prelinkedVersion = try outputs.createVersion(
            structuredOutputID: prelinkedOutput.id,
            contentMarkdown: "# PRELINKED-ACTIVE-2287\n\nIntended ordering control [S97].",
            requiredSections: ["PRELINKED-ACTIVE-2287"],
            presentSections: ["PRELINKED-ACTIVE-2287"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "prelinked-active-verifier/2287",
            verificationResults: [try supportedResult(sourceID: "prelinked-active-source-2287")],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_522_887),
            promptBuilderVersion: "prelinked-active-prompt/2287",
            assuranceState: .corpusComplete,
            makeActive: false
        )
        try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "prelinked-active-2287",
                digestDigit: "a",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-prelinked-active-slice-2287",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "a", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 257,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [prelinkedVersion.id, target.runID]
            )
            try db.execute(
                sql: """
                    UPDATE structured_outputs
                    SET active_version_id = ?, status = 'complete'
                    WHERE id = ?
                    """,
                arguments: [prelinkedVersion.id, prelinkedOutput.id]
            )
        }
        try queue.read { db in
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: prelinkedOutput.id)
            )
            XCTAssertEqual(output.activeVersionID, prelinkedVersion.id)
            XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
            XCTAssertFalse(
                output.activeVersionID?.contains("UNLINKED-ACTIVE-2281") ?? false
            )
        }
    }

    func testTSTORE01V072RevalidatesAttachmentWhenRunIsReclassifiedExact() throws {
        // T-STORE-01 classification-laundering audit expected RED: attachment
        // checks run only when structured_output_version_id changes. A chronology
        // run can first attach an incompatible output version, then change its
        // task/request/strategy identity into exact v2 without revalidating that
        // already-present attachment against the exact-output contract.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic classification laundering 2293"
        )
        let incompatible = try createSyntheticOutputVersion(
            repository: StructuredOutputRepository(writer: queue),
            matterID: matter.id,
            marker: "classification-incompatible-2293",
            outputType: .factChronologyTable,
            assuranceState: .corpusComplete
        )
        let candidateRunID: String = try queue.write { db in
            let candidate = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "classification-candidate-2297",
                digestDigit: "c",
                disposition: .succeeded
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET task_kind = 'chronology', request_schema_version = NULL,
                        request_digest = NULL, partition_strategy = 'per_document:2297',
                        partition_strategy_version = 1
                    WHERE id = ?
                    """,
                arguments: [candidate.runID]
            )
            try insertSlice(
                db,
                id: "t-store-01-classification-candidate-slice-2297",
                partitionID: candidate.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "c", count: 64),
                runID: candidate.runID,
                memberKey: candidate.memberKey,
                documentID: candidate.documentID,
                partIndex: 269,
                revisionID: candidate.revisionID
            )
            try persistCorpusComplete(db, runID: candidate.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [incompatible.version.id, candidate.runID]
            )
            return candidate.runID
        }

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET task_kind = 'exhaustive_list', request_schema_version = 2,
                            request_digest = ?, partition_strategy = 'exact_revision_slice:2297',
                            partition_strategy_version = 2
                        WHERE id = ?
                        """,
                    arguments: [String(repeating: "c", count: 64), candidateRunID]
                )
            },
            "becoming exact v2 must revalidate the already-attached output contract"
        )
        try queue.read { db in
            let candidate = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(db, key: candidateRunID)
            )
            XCTAssertEqual(candidate.structuredOutputVersionID, incompatible.version.id)
            XCTAssertEqual(candidate.taskKind, CorpusAnalysisTaskKind.chronology.rawValue)
            XCTAssertNotEqual(candidate.taskKind, CorpusAnalysisTaskKind.exhaustiveList.rawValue)
            XCTAssertNil(candidate.requestSchemaVersion)
            XCTAssertNotEqual(candidate.requestSchemaVersion, 2)
            XCTAssertNil(candidate.requestDigest)
            XCTAssertFalse(candidate.partitionStrategy.hasPrefix("exact_revision_slice"))
            XCTAssertNotEqual(candidate.partitionStrategyVersion, 2)
        }
    }

    func testTSTORE01V072RejectsWeakActiveVersionAssuranceLaundering() throws {
        // T-STORE-01 active-projection audit expected RED: selecting an unlinked
        // weak version is legitimate review behavior, but promoting that active
        // row to an export-eligible assurance state must re-run the exact-proof
        // check instead of bypassing the active-version trigger.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic active assurance laundering 2347"
        )
        let linked = try createLinkedExactOutputFixture(
            queue: queue,
            matterID: matter.id,
            marker: "active-assurance-owner-2347",
            digestDigit: "8",
            partIndex: 311
        )
        let outputs = StructuredOutputRepository(writer: queue)
        let weakVersion = try outputs.createVersion(
            structuredOutputID: linked.output.id,
            contentMarkdown: "# WEAK-ACTIVE-2347\n\nSupport-needs-review candidate [S97].",
            requiredSections: ["WEAK-ACTIVE-2347"],
            presentSections: ["WEAK-ACTIVE-2347"],
            missingSections: [],
            verificationStatus: .legacyUnverified,
            verificationVersion: "",
            verificationResults: [],
            assuranceState: .supportNeedsReview,
            makeActive: false
        )

        XCTAssertNoThrow(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_outputs SET active_version_id = ? WHERE id = ?",
                    arguments: [weakVersion.id, linked.output.id]
                )
            },
            "a weak active review candidate remains legal"
        )
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE structured_output_versions SET assurance_state = 'corpus_complete' WHERE id = ?",
                    arguments: [weakVersion.id]
                )
            },
            "an active unlinked version cannot gain export assurance in place"
        )
        try queue.read { db in
            let output = try XCTUnwrap(
                StructuredOutputRecord.fetchOne(db, key: linked.output.id)
            )
            let retained = try XCTUnwrap(
                StructuredOutputVersionRecord.fetchOne(db, key: weakVersion.id)
            )
            XCTAssertEqual(output.activeVersionID, weakVersion.id)
            XCTAssertEqual(
                retained.assuranceState,
                OutputAssuranceState.supportNeedsReview.rawValue
            )
            XCTAssertNotEqual(
                retained.assuranceState,
                OutputAssuranceState.corpusComplete.rawValue
            )
        }
    }

    func testTSTORE01V072KeepsPermanentMatterDeletionCascading() throws {
        // T-STORE-01 compatibility control: link immutability must not turn a
        // permanent matter deletion into an undeletable graph.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matters = MattersRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic cascade deletion 2179")
        let outputs = StructuredOutputRepository(writer: queue)
        let artifact = try createSyntheticOutputVersion(
            repository: outputs,
            matterID: matter.id,
            marker: "cascade-delete-2179",
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let runID: String = try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "cascade-delete-2179",
                digestDigit: "f",
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-cascade-delete-slice-2179",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "f", count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: 197,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [artifact.version.id, target.runID]
            )
            return target.runID
        }

        XCTAssertNoThrow(try matters.permanentlyDeleteMatter(id: matter.id))
        try queue.read { db in
            XCTAssertNil(try MatterRecord.fetchOne(db, key: matter.id))
            XCTAssertNil(try CorpusAnalysisRunRecord.fetchOne(db, key: runID))
            XCTAssertNil(try StructuredOutputVersionRecord.fetchOne(db, key: artifact.version.id))
            XCTAssertNil(try StructuredOutputRecord.fetchOne(db, key: artifact.output.id))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?",
                    arguments: [runID]
                ),
                0
            )
        }
    }

    func testTSTORE01V072FinalizationRequiresCoherentSucceededAttemptHistory() throws {
        // T-STORE-01 review finding expected RED: the completion trigger checks
        // only disposition, so direct SQL can mark pristine pending work succeeded
        // with zero attempts and fabricated findings, then persist corpus-complete.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic completion attempt proof 2129"
        )

        try queue.write { db in
            let fabricated = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "zero-attempt-success-2129",
                digestDigit: "6",
                disposition: .pending
            )
            try insertSlice(
                db,
                id: "t-store-01-zero-attempt-slice-2129",
                partitionID: fabricated.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "6", count: 64),
                runID: fabricated.runID,
                memberKey: fabricated.memberKey,
                documentID: fabricated.documentID,
                partIndex: 163,
                revisionID: fabricated.revisionID
            )
            let foreignFinding = #"[{"id":"foreign-zero-attempt-2129","value":"FOREIGN-ZERO-ATTEMPT-2129","evidence":[]}]"#
            var fabricatedMutationError: Error?
            do {
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_partitions
                        SET disposition = 'succeeded', findings_json = ?
                        WHERE id = ?
                        """,
                    arguments: [foreignFinding, fabricated.partitionID]
                )
            } catch {
                fabricatedMutationError = error
            }
            let fabricatedPartition = try XCTUnwrap(
                CorpusAnalysisPartitionRecord.fetchOne(db, key: fabricated.partitionID)
            )
            XCTAssertEqual(fabricatedPartition.attemptCount, 0)
            XCTAssertEqual(fabricatedPartition.attemptHistoryJSON, "[]")
            if fabricatedMutationError != nil {
                XCTAssertEqual(
                    fabricatedPartition.disposition,
                    CorpusAnalysisPartitionDisposition.pending.rawValue
                )
                XCTAssertNil(fabricatedPartition.findingsJSON)
                XCTAssertFalse(
                    fabricatedPartition.findingsJSON?.contains("FOREIGN-ZERO-ATTEMPT-2129") ?? false
                )
                try assertNotCorpusComplete(db, runID: fabricated.runID)
            } else {
                XCTAssertEqual(
                    fabricatedPartition.disposition,
                    CorpusAnalysisPartitionDisposition.succeeded.rawValue
                )
                XCTAssertTrue(
                    fabricatedPartition.findingsJSON?.contains("FOREIGN-ZERO-ATTEMPT-2129") == true
                )
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: fabricated.runID,
                        exclusionsDisclosed: true
                    ),
                    "zero-attempt succeeded state must not cross the export completion barrier"
                )
                try assertNotCorpusComplete(db, runID: fabricated.runID)
            }

            let coherent = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "coherent-attempt-success-2131",
                digestDigit: "7",
                disposition: .pending
            )
            try insertSlice(
                db,
                id: "t-store-01-coherent-attempt-slice-2131",
                partitionID: coherent.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "7", count: 64),
                runID: coherent.runID,
                memberKey: coherent.memberKey,
                documentID: coherent.documentID,
                partIndex: 167,
                revisionID: coherent.revisionID
            )
            let startedAt = Date(timeIntervalSince1970: 1_790_321_301)
            let completedAt = Date(timeIntervalSince1970: 1_790_321_397)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let historyJSON = String(decoding: try encoder.encode([
                CorpusAnalysisAttemptHistoryEntry(
                    attemptNumber: 1,
                    outcome: .succeeded,
                    retryable: false,
                    startedAt: startedAt,
                    completedAt: completedAt
                ),
            ]), as: UTF8.self)
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_partitions
                    SET attempt_count = 1, attempt_history_json = ?,
                        disposition = 'succeeded', findings_json = '[]',
                        started_at = ?, completed_at = ?
                    WHERE id = ?
                    """,
                arguments: [historyJSON, startedAt, completedAt, coherent.partitionID]
            )
            try persistCorpusComplete(db, runID: coherent.runID, exclusionsDisclosed: true)
            let coherentRun = try XCTUnwrap(
                CorpusAnalysisRunRecord.fetchOne(db, key: coherent.runID)
            )
            XCTAssertEqual(coherentRun.status, CorpusAnalysisRunStatus.persisted.rawValue)
            XCTAssertEqual(coherentRun.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
            XCTAssertNotEqual(coherentRun.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        }
    }

    func testTSTORE01V072ValidatesSucceededRowTimesAndFindingsShape() throws {
        // T-STORE-01 attempt-row audit expected RED: a structurally valid final
        // attempt currently launders non-date or reversed row timestamps and
        // NULL/object/scalar findings through exact-v2 success and finalization.
        // The new constraint must remain scoped away from chronology and v1.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic exact attempt row scalars 2309"
        )
        let orderedHistory =
            #"[{"attempt_number":1,"outcome":"succeeded","retryable":false,"started_at":8301.25,"completed_at":8307.75}]"#
        let invalidRows: [(
            caseName: String,
            digestDigit: String,
            partIndex: Int,
            rowAssignments: String,
            forbiddenMarker: String
        )] = [
            (
                "non-date-row-2309", "d", 271,
                "started_at = 'FOREIGN-NON-DATE-2309', completed_at = 8307.75, findings_json = '[]'",
                "FOREIGN-NON-DATE-2309"
            ),
            (
                "reversed-row-2311", "e", 277,
                "started_at = 8319.75, completed_at = 8311.25, findings_json = '[]'",
                "8319.75"
            ),
            (
                "null-findings-2317", "f", 281,
                "started_at = 8301.25, completed_at = 8307.75, findings_json = NULL",
                "NULL-FINDINGS-2317"
            ),
            (
                "object-findings-2321", "1", 283,
                "started_at = 8301.25, completed_at = 8307.75, findings_json = '{\"foreign\":\"FOREIGN-OBJECT-2321\"}'",
                "FOREIGN-OBJECT-2321"
            ),
            (
                "scalar-findings-2327", "2", 293,
                "started_at = 8301.25, completed_at = 8307.75, findings_json = '23272327'",
                "23272327"
            ),
            (
                "missing-evidence-findings-2329", "6", 299,
                "started_at = 8301.25, completed_at = 8307.75, findings_json = '[{\"id\":\"FOREIGN-MISSING-EVIDENCE-2329\",\"value\":\"claim\"}]'",
                "FOREIGN-MISSING-EVIDENCE-2329"
            ),
            (
                "malformed-evidence-findings-2331", "7", 301,
                "started_at = 8301.25, completed_at = 8307.75, findings_json = '[{\"id\":\"finding-2331\",\"value\":\"claim\",\"evidence\":[{\"document_id\":\"\",\"revision_id\":\"revision-2331\",\"locator_json\":\"FOREIGN-MALFORMED-EVIDENCE-2331\"}]}]'",
                "FOREIGN-MALFORMED-EVIDENCE-2331"
            ),
        ]

        try queue.write { db in
            for invalid in invalidRows {
                let target = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: invalid.caseName,
                    digestDigit: invalid.digestDigit,
                    disposition: .pending
                )
                try insertSlice(
                    db,
                    id: "t-store-01-\(invalid.caseName)-slice",
                    partitionID: target.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: invalid.digestDigit, count: 64),
                    runID: target.runID,
                    memberKey: target.memberKey,
                    documentID: target.documentID,
                    partIndex: invalid.partIndex,
                    revisionID: target.revisionID
                )

                var transitionError: Error?
                do {
                    try db.execute(
                        sql: """
                            UPDATE corpus_analysis_partitions
                            SET attempt_count = 1, attempt_history_json = ?,
                                disposition = 'succeeded', \(invalid.rowAssignments)
                            WHERE id = ?
                            """,
                        arguments: [orderedHistory, target.partitionID]
                    )
                } catch {
                    transitionError = error
                }
                if transitionError != nil {
                    let retained = try XCTUnwrap(
                        Row.fetchOne(
                            db,
                            sql: """
                                SELECT disposition, findings_json, CAST(started_at AS TEXT) AS started_text
                                FROM corpus_analysis_partitions WHERE id = ?
                                """,
                            arguments: [target.partitionID]
                        )
                    )
                    XCTAssertEqual(
                        retained["disposition"] as String,
                        CorpusAnalysisPartitionDisposition.pending.rawValue
                    )
                    XCTAssertNil(retained["findings_json"] as String?)
                    XCTAssertFalse(
                        (retained["started_text"] as String?)?.contains(invalid.forbiddenMarker)
                            ?? false
                    )
                } else {
                    XCTAssertThrowsError(
                        try persistCorpusComplete(
                            db,
                            runID: target.runID,
                            exclusionsDisclosed: true
                        ),
                        "\(invalid.caseName) must not cross the exact export barrier"
                    )
                }
                try assertNotCorpusComplete(db, runID: target.runID)
            }

            let valid = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "numeric-row-control-2333",
                digestDigit: "3",
                disposition: .pending
            )
            try insertSlice(
                db,
                id: "t-store-01-numeric-row-control-slice-2333",
                partitionID: valid.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "3", count: 64),
                runID: valid.runID,
                memberKey: valid.memberKey,
                documentID: valid.documentID,
                partIndex: 307,
                revisionID: valid.revisionID
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_partitions
                    SET attempt_count = 1, attempt_history_json = ?,
                        disposition = 'succeeded', findings_json = '[]',
                        started_at = 8301.25, completed_at = 8307.75
                    WHERE id = ?
                    """,
                arguments: [orderedHistory, valid.partitionID]
            )
            try persistCorpusComplete(db, runID: valid.runID, exclusionsDisclosed: true)
            let validRun = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: valid.runID))
            XCTAssertEqual(validRun.status, CorpusAnalysisRunStatus.persisted.rawValue)
            XCTAssertEqual(validRun.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
            let validTypes = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT typeof(started_at) AS started_type,
                               typeof(completed_at) AS completed_type,
                               started_at < completed_at AS ordered,
                               json_type(findings_json) AS findings_type
                        FROM corpus_analysis_partitions WHERE id = ?
                        """,
                    arguments: [valid.partitionID]
                )
            )
            XCTAssertEqual(validTypes["started_type"] as String, "real")
            XCTAssertEqual(validTypes["completed_type"] as String, "real")
            XCTAssertEqual(validTypes["ordered"] as Int, 1)
            XCTAssertEqual(validTypes["findings_type"] as String, "array")

            let chronology = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "chronology-row-control-2339",
                digestDigit: "4",
                disposition: .pending
            )
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET task_kind = 'chronology' WHERE id = ?",
                arguments: [chronology.runID]
            )
            XCTAssertNoThrow(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_partitions
                        SET attempt_count = 1, attempt_history_json = ?,
                            disposition = 'succeeded',
                            started_at = 'LEGACY-CHRONOLOGY-2339', completed_at = 8307.75,
                            findings_json = '{"legacy":"CHRONOLOGY-2339"}'
                        WHERE id = ?
                        """,
                    arguments: [orderedHistory, chronology.partitionID]
                )
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT disposition FROM corpus_analysis_partitions WHERE id = ?",
                    arguments: [chronology.partitionID]
                ),
                CorpusAnalysisPartitionDisposition.succeeded.rawValue
            )

            let v1 = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "v1-row-control-2341",
                digestDigit: "5",
                disposition: .pending
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET request_schema_version = 1,
                        partition_strategy = 'per_revision:2341',
                        partition_strategy_version = 1
                    WHERE id = ?
                    """,
                arguments: [v1.runID]
            )
            XCTAssertNoThrow(
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_partitions
                        SET attempt_count = 1, attempt_history_json = ?,
                            disposition = 'succeeded',
                            started_at = 8341.75, completed_at = 8341.25,
                            findings_json = NULL
                        WHERE id = ?
                        """,
                    arguments: [orderedHistory, v1.partitionID]
                )
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT disposition FROM corpus_analysis_partitions WHERE id = ?",
                    arguments: [v1.partitionID]
                ),
                CorpusAnalysisPartitionDisposition.succeeded.rawValue
            )
        }
    }

    func testTSTORE01V072RequiresEveryFindingReferenceToBelongToItsExactPartition() throws {
        // T-STORE-01 evidence-lineage audit expected RED: exact-v2 success
        // currently checks only the JSON shape of evidence references. It
        // accepts findings with no references and references to a foreign
        // document, revision, or locator. Every non-empty finding must instead
        // carry at least one primary/contrary reference that equals a frozen
        // slice in this exact partition; an empty top-level findings array is
        // still a valid no-findings result.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic exact finding lineage 2351"
        )
        let invalidCases = [
            "no-references-2351",
            "foreign-document-2357",
            "foreign-revision-2371",
            "foreign-locator-2377",
            "foreign-contrary-locator-2381",
        ]
        let digestDigits = ["6", "7", "8", "9", "a"]

        try queue.write { db in
            for (offset, caseName) in invalidCases.enumerated() {
                let target = try insertCompletionBarrierRun(
                    db,
                    matterID: matter.id,
                    caseName: caseName,
                    digestDigit: digestDigits[offset],
                    disposition: .pending
                )
                let partIndex = 311 + offset * 2
                let locator =
                    "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":0,\"char_end\":100}"
                try insertSlice(
                    db,
                    id: "t-store-01-\(caseName)-slice",
                    partitionID: target.partitionID,
                    ordinal: 0,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: digestDigits[offset], count: 64),
                    runID: target.runID,
                    memberKey: target.memberKey,
                    documentID: target.documentID,
                    partIndex: partIndex,
                    revisionID: target.revisionID
                )
                let validReference = findingReference(
                    documentID: target.documentID,
                    revisionID: target.revisionID,
                    locatorJSON: locator
                )
                let evidence: [[String: String]]
                let contraryEvidence: [[String: String]]
                switch caseName {
                case "no-references-2351":
                    evidence = []
                    contraryEvidence = []
                case "foreign-document-2357":
                    evidence = [findingReference(
                        documentID: "FOREIGN-DOCUMENT-2357",
                        revisionID: target.revisionID,
                        locatorJSON: locator
                    )]
                    contraryEvidence = []
                case "foreign-revision-2371":
                    evidence = [findingReference(
                        documentID: target.documentID,
                        revisionID: "FOREIGN-REVISION-2371",
                        locatorJSON: locator
                    )]
                    contraryEvidence = []
                case "foreign-locator-2377":
                    evidence = [findingReference(
                        documentID: target.documentID,
                        revisionID: target.revisionID,
                        locatorJSON:
                            "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":0,\"char_end\":99}"
                    )]
                    contraryEvidence = []
                default:
                    evidence = [validReference]
                    contraryEvidence = [findingReference(
                        documentID: target.documentID,
                        revisionID: target.revisionID,
                        locatorJSON:
                            "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":1,\"char_end\":100}"
                    )]
                }
                let findings = try findingsJSON(
                    marker: "FOREIGN-\(caseName.uppercased())",
                    evidence: evidence,
                    contraryEvidence: contraryEvidence
                )

                XCTAssertThrowsError(
                    try markPartitionSucceededWithFindings(
                        db,
                        partitionID: target.partitionID,
                        findingsJSON: findings,
                        timestampMarker: 350 + offset
                    ),
                    "\(caseName) must not become an exact-v2 succeeded checkpoint"
                )
                let retained = try XCTUnwrap(
                    CorpusAnalysisPartitionRecord.fetchOne(db, key: target.partitionID)
                )
                XCTAssertEqual(
                    retained.disposition,
                    CorpusAnalysisPartitionDisposition.pending.rawValue
                )
                XCTAssertNil(retained.findingsJSON)
                XCTAssertFalse(retained.findingsJSON?.contains(caseName.uppercased()) ?? false)
            }

            let empty = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "empty-top-level-control-2383",
                digestDigit: "b",
                disposition: .pending
            )
            try insertSlice(
                db,
                id: "t-store-01-empty-top-level-control-slice-2383",
                partitionID: empty.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "b", count: 64),
                runID: empty.runID,
                memberKey: empty.memberKey,
                documentID: empty.documentID,
                partIndex: 323,
                revisionID: empty.revisionID
            )
            XCTAssertNoThrow(
                try markPartitionSucceededWithFindings(
                    db,
                    partitionID: empty.partitionID,
                    findingsJSON: "[]",
                    timestampMarker: 383
                )
            )
            XCTAssertNoThrow(
                try persistCorpusComplete(db, runID: empty.runID, exclusionsDisclosed: true)
            )
            XCTAssertEqual(
                try CorpusAnalysisPartitionRecord.fetchOne(db, key: empty.partitionID)?.findingsJSON,
                "[]"
            )

            let contraryOnly = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "contrary-only-control-2389",
                digestDigit: "c",
                disposition: .pending
            )
            let contraryPartIndex = 331
            let contraryLocator =
                "{\"source_kind\":\"text\",\"part_index\":\(contraryPartIndex),\"char_start\":0,\"char_end\":100}"
            try insertSlice(
                db,
                id: "t-store-01-contrary-only-control-slice-2389",
                partitionID: contraryOnly.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "c", count: 64),
                runID: contraryOnly.runID,
                memberKey: contraryOnly.memberKey,
                documentID: contraryOnly.documentID,
                partIndex: contraryPartIndex,
                revisionID: contraryOnly.revisionID
            )
            let contraryOnlyFindings = try findingsJSON(
                marker: "CONTRARY-ONLY-CONTROL-2389",
                evidence: [],
                contraryEvidence: [findingReference(
                    documentID: contraryOnly.documentID,
                    revisionID: contraryOnly.revisionID,
                    locatorJSON: contraryLocator
                )]
            )
            XCTAssertNoThrow(
                try markPartitionSucceededWithFindings(
                    db,
                    partitionID: contraryOnly.partitionID,
                    findingsJSON: contraryOnlyFindings,
                    timestampMarker: 389
                )
            )
            XCTAssertNoThrow(
                try persistCorpusComplete(
                    db,
                    runID: contraryOnly.runID,
                    exclusionsDisclosed: true
                )
            )
            XCTAssertTrue(
                try CorpusAnalysisPartitionRecord.fetchOne(db, key: contraryOnly.partitionID)?
                    .findingsJSON?.contains("CONTRARY-ONLY-CONTROL-2389") == true
            )
        }
    }

    func testTSTORE01V072RejectsEmptyLocatorsAndFractionalPartIndices() throws {
        // T-STORE-01 review finding expected RED: SQLite accepts a NULL-valued
        // locator CHECK, so an empty/missing-field object and a REAL part_index
        // with no locator part can be inserted and can later finalize as exact.
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        let matter = try MattersRepository(writer: queue).createMatter(
            name: "Synthetic strict slice scalar proof 2141"
        )

        try queue.write { db in
            let insertionTarget = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "strict-slice-insert-2141",
                digestDigit: "8",
                disposition: .pending
            )
            let malformedLocators: [(id: String, ordinal: Int, locator: String)] = [
                ("t-store-01-empty-locator-slice-2141", 0, "{}"),
                (
                    "t-store-01-missing-range-locator-slice-2143",
                    1,
                    #"{"source_kind":"text"}"#
                ),
            ]
            for malformed in malformedLocators {
                var insertionError: Error?
                do {
                    try insertRawSlice(
                        db,
                        id: malformed.id,
                        runID: insertionTarget.runID,
                        partitionID: insertionTarget.partitionID,
                        ordinal: malformed.ordinal,
                        memberKey: insertionTarget.memberKey,
                        documentID: insertionTarget.documentID,
                        partIndex: 173,
                        revisionID: insertionTarget.revisionID,
                        charStart: 0,
                        charEnd: 100,
                        revisionCharCount: 100,
                        textSHA256: String(repeating: "8", count: 64),
                        locatorJSON: malformed.locator
                    )
                } catch {
                    insertionError = error
                }
                XCTAssertNotNil(
                    insertionError,
                    "locator \(malformed.id) must be rejected rather than passing a NULL CHECK"
                )
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE id = ?",
                        arguments: [malformed.id]
                    ),
                    0,
                    "the malformed locator row must be absent"
                )
                if insertionError == nil {
                    try db.execute(
                        sql: "DELETE FROM corpus_analysis_partition_slices WHERE id = ?",
                        arguments: [malformed.id]
                    )
                }
            }

            let fractionalID = "t-store-01-fractional-part-slice-2149"
            var fractionalInsertionError: Error?
            do {
                try insertRawSlice(
                    db,
                    id: fractionalID,
                    runID: insertionTarget.runID,
                    partitionID: insertionTarget.partitionID,
                    ordinal: 2,
                    memberKey: insertionTarget.memberKey,
                    documentID: insertionTarget.documentID,
                    partIndex: 179.5,
                    revisionID: insertionTarget.revisionID,
                    charStart: 0,
                    charEnd: 100,
                    revisionCharCount: 100,
                    textSHA256: String(repeating: "9", count: 64),
                    locatorJSON: #"{"source_kind":"text","char_start":0,"char_end":100}"#
                )
            } catch {
                fractionalInsertionError = error
            }
            XCTAssertNotNil(
                fractionalInsertionError,
                "INTEGER affinity must not accept a nonintegral part identity"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE id = ?",
                    arguments: [fractionalID]
                ),
                0,
                "the fractional part row must be absent"
            )
            if fractionalInsertionError == nil {
                try db.execute(
                    sql: "DELETE FROM corpus_analysis_partition_slices WHERE id = ?",
                    arguments: [fractionalID]
                )
            }

            let completionTarget = try insertCompletionBarrierRun(
                db,
                matterID: matter.id,
                caseName: "strict-slice-finalize-2153",
                digestDigit: "a",
                disposition: .succeeded
            )
            let completionSliceID = "t-store-01-strict-finalize-slice-2153"
            try insertSlice(
                db,
                id: completionSliceID,
                partitionID: completionTarget.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: "a", count: 64),
                runID: completionTarget.runID,
                memberKey: completionTarget.memberKey,
                documentID: completionTarget.documentID,
                partIndex: 181,
                revisionID: completionTarget.revisionID
            )
            var mutationError: Error?
            do {
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_partition_slices
                        SET locator_json = '{}', part_index = 181.5
                        WHERE id = ?
                        """,
                    arguments: [completionSliceID]
                )
            } catch {
                mutationError = error
            }
            if mutationError != nil {
                let retained = try XCTUnwrap(
                    Row.fetchOne(
                        db,
                        sql: "SELECT locator_json, typeof(part_index) AS part_type FROM corpus_analysis_partition_slices WHERE id = ?",
                        arguments: [completionSliceID]
                    )
                )
                XCTAssertNotEqual(retained["locator_json"] as String, "{}")
                XCTAssertEqual(retained["part_type"] as String, "integer")
            } else {
                XCTAssertThrowsError(
                    try persistCorpusComplete(
                        db,
                        runID: completionTarget.runID,
                        exclusionsDisclosed: true
                    ),
                    "a malformed locator/fractional part that reached storage must fail finalization"
                )
                try assertNotCorpusComplete(db, runID: completionTarget.runID)
            }
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

    private func insertRawSlice(
        _ db: Database,
        id: String,
        runID: String,
        partitionID: String,
        ordinal: Int,
        memberKey: String,
        documentID: String,
        partIndex: Double,
        revisionID: String,
        charStart: Int,
        charEnd: Int,
        revisionCharCount: Int,
        textSHA256: String,
        locatorJSON: String
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
                id, runID, partitionID, ordinal, memberKey, documentID,
                partIndex, revisionID, charStart, charEnd,
                revisionCharCount, textSHA256, locatorJSON,
            ]
        )
    }

    private func markPartitionSucceededWithCoherentAttempt(
        _ db: Database,
        partitionID: String,
        timestampMarker: Int
    ) throws {
        try markPartitionSucceededWithFindings(
            db,
            partitionID: partitionID,
            findingsJSON: "[]",
            timestampMarker: timestampMarker
        )
    }

    private func markPartitionSucceededWithFindings(
        _ db: Database,
        partitionID: String,
        findingsJSON: String,
        timestampMarker: Int
    ) throws {
        let startedAt = Date(
            timeIntervalSince1970: 1_790_400_000 + Double(timestampMarker)
        )
        let completedAt = Date(
            timeIntervalSince1970: 1_790_400_100 + Double(timestampMarker)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let historyJSON = String(decoding: try encoder.encode([
            CorpusAnalysisAttemptHistoryEntry(
                attemptNumber: 1,
                outcome: .succeeded,
                retryable: false,
                startedAt: startedAt,
                completedAt: completedAt
            ),
        ]), as: UTF8.self)
        try db.execute(
            sql: """
                UPDATE corpus_analysis_partitions
                SET attempt_count = 1, attempt_history_json = ?,
                    disposition = 'succeeded', findings_json = ?,
                    started_at = ?, completed_at = ?
                WHERE id = ?
                """,
            arguments: [historyJSON, findingsJSON, startedAt, completedAt, partitionID]
        )
    }

    private func findingReference(
        documentID: String,
        revisionID: String,
        locatorJSON: String
    ) -> [String: String] {
        [
            "document_id": documentID,
            "revision_id": revisionID,
            "locator_json": locatorJSON,
        ]
    }

    private func findingsJSON(
        marker: String,
        evidence: [[String: String]],
        contraryEvidence: [[String: String]]
    ) throws -> String {
        let finding: [String: Any] = [
            "id": "finding-\(marker)",
            "value": marker,
            "evidence": evidence,
            "contrary_evidence": contraryEvidence,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: [finding],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
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
        let startedAt = Date(timeIntervalSince1970: 1_790_000_513)
        let completedAt = Date(timeIntervalSince1970: 1_790_000_517)
        let succeeded = disposition == .succeeded
        let attemptHistoryJSON: String
        if succeeded {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            attemptHistoryJSON = String(decoding: try encoder.encode([
                CorpusAnalysisAttemptHistoryEntry(
                    attemptNumber: 1,
                    outcome: .succeeded,
                    retryable: false,
                    startedAt: startedAt,
                    completedAt: completedAt
                ),
            ]), as: UTF8.self)
        } else {
            attemptHistoryJSON = "[]"
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
                    id, run_id, partition_key, input_revision_ids_json,
                    attempt_count, attempt_history_json, disposition,
                    findings_json, started_at, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                partitionID, runID, "\(memberKey)#slice:0", "[\"\(revisionID)\"]",
                succeeded ? 1 : 0,
                attemptHistoryJSON,
                disposition.rawValue,
                succeeded ? "[]" : nil,
                succeeded ? startedAt : nil,
                succeeded ? completedAt : nil,
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
                let startedAt = Date(timeIntervalSince1970: 1_790_000_613 + Double(targets.count))
                let completedAt = Date(timeIntervalSince1970: 1_790_000_617 + Double(targets.count))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let attemptHistoryJSON = String(decoding: try encoder.encode([
                    CorpusAnalysisAttemptHistoryEntry(
                        attemptNumber: 1,
                        outcome: .succeeded,
                        retryable: false,
                        startedAt: startedAt,
                        completedAt: completedAt
                    ),
                ]), as: UTF8.self)
                let revisionIDsData = try JSONSerialization.data(
                    withJSONObject: [revision.id],
                    options: [.sortedKeys]
                )
                try db.execute(
                    sql: """
                        INSERT INTO corpus_analysis_partitions (
                            id, run_id, partition_key, input_revision_ids_json,
                            attempt_count, attempt_history_json, disposition,
                            findings_json, started_at, completed_at
                        ) VALUES (?, ?, ?, ?, 1, ?, ?, '[]', ?, ?)
                        """,
                    arguments: [
                        partitionID, runID, "\(member.memberKey)#revision:\(index)",
                        String(decoding: revisionIDsData, as: UTF8.self),
                        attemptHistoryJSON,
                        CorpusAnalysisPartitionDisposition.succeeded.rawValue,
                        startedAt,
                        completedAt,
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

    private func frozenCorpusLineageHash(_ db: Database, runID: String) throws -> String {
        let run = try XCTUnwrap(CorpusAnalysisRunRecord.fetchOne(db, key: runID))
        let snapshot = try JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(run.corpusSnapshotJSON.utf8)
        )
        let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
            arguments: [runID]
        )
        let partitionKeyByID = Dictionary(
            uniqueKeysWithValues: partitions.map { ($0.id, $0.partitionKey) }
        )
        let slices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partition_slices WHERE run_id = ?",
            arguments: [runID]
        ).map { slice -> StoreFrozenSliceLineageProbe in
            let locatorObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(slice.locatorJSON.utf8))
                    as? [String: Any]
            )
            let sourceKind = try XCTUnwrap(
                (locatorObject["source_kind"] as? String).flatMap(DocumentSourceKind.init(rawValue:))
            )
            return StoreFrozenSliceLineageProbe(
                partitionKey: try XCTUnwrap(partitionKeyByID[slice.partitionID]),
                ordinal: slice.ordinal,
                memberKey: slice.memberKey,
                documentID: slice.documentID,
                partIndex: slice.partIndex,
                revisionID: slice.revisionID,
                charStart: slice.charStart,
                charEnd: slice.charEnd,
                revisionCharCount: slice.revisionCharCount,
                textSHA256: slice.textSHA256,
                locator: StoreSourceLocatorProbe(
                    sourceKind: sourceKind,
                    pageIndex: locatorObject["page_index"] as? Int,
                    pageLabel: locatorObject["page_label"] as? String,
                    sheetName: locatorObject["sheet_name"] as? String,
                    cellRange: locatorObject["cell_range"] as? String,
                    emailPartPath: locatorObject["email_part_path"] as? String,
                    charStart: locatorObject["char_start"] as? Int,
                    charEnd: locatorObject["char_end"] as? Int,
                    boundingBoxesJSON: locatorObject["bounding_boxes_json"] as? String
                )
            )
        }
        let envelope = StoreFrozenCorpusLineageEnvelope(
            snapshot: CorpusAnalysisSnapshot(
                schemaVersion: snapshot.schemaVersion,
                members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
            ),
            slices: slices.sorted(by: StoreFrozenSliceLineageProbe.lessThan)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(envelope))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private func createSyntheticOutputVersion(
        repository: StructuredOutputRepository,
        matterID: String,
        marker: String,
        outputType: StructuredOutputType,
        assuranceState: OutputAssuranceState
    ) throws -> (output: StructuredOutputRecord, version: StructuredOutputVersionRecord) {
        let output = try repository.createOutput(
            matterID: matterID,
            title: "Synthetic attachment \(marker)",
            outputType: outputType
        )
        let exportEligible = OutputAssurancePresentation.isExportEligible(assuranceState)
        let version = try repository.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "# Synthetic attachment \(marker)\n\nNon-default value \(marker) [S97].",
            requiredSections: ["Non-default value \(marker)"],
            presentSections: ["Non-default value \(marker)"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "attachment-verifier/\(marker)",
            verificationResults: [try supportedResult(sourceID: "attachment-source-\(marker)")],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_300_000),
            promptBuilderVersion: "attachment-prompt/\(marker)",
            assuranceState: assuranceState,
            outputStatus: exportEligible ? .complete : .needsReview
        )
        return (output, version)
    }

    private func createLinkedExactOutputFixture(
        queue: DatabaseQueue,
        matterID: String,
        marker: String,
        digestDigit: String,
        partIndex: Int
    ) throws -> (
        output: StructuredOutputRecord,
        version: StructuredOutputVersionRecord,
        runID: String
    ) {
        let artifact = try createSyntheticOutputVersion(
            repository: StructuredOutputRepository(writer: queue),
            matterID: matterID,
            marker: marker,
            outputType: .documentExhaustiveList,
            assuranceState: .corpusComplete
        )
        let runID: String = try queue.write { db in
            let target = try insertCompletionBarrierRun(
                db,
                matterID: matterID,
                caseName: marker,
                digestDigit: digestDigit,
                disposition: .succeeded
            )
            try insertSlice(
                db,
                id: "t-store-01-linked-fixture-\(marker)-slice",
                partitionID: target.partitionID,
                ordinal: 0,
                charStart: 0,
                charEnd: 100,
                revisionCharCount: 100,
                textSHA256: String(repeating: digestDigit, count: 64),
                runID: target.runID,
                memberKey: target.memberKey,
                documentID: target.documentID,
                partIndex: partIndex,
                revisionID: target.revisionID
            )
            try persistCorpusComplete(db, runID: target.runID, exclusionsDisclosed: true)
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET structured_output_version_id = ? WHERE id = ?",
                arguments: [artifact.version.id, target.runID]
            )
            return target.runID
        }
        return (artifact.output, artifact.version, runID)
    }
}

private struct StoreSourceLocatorProbe: Codable, Sendable {
    var sourceKind: DocumentSourceKind
    var pageIndex: Int?
    var pageLabel: String?
    var sheetName: String?
    var cellRange: String?
    var emailPartPath: String?
    var charStart: Int?
    var charEnd: Int?
    var boundingBoxesJSON: String?
}

private struct StoreFrozenSliceLineageProbe: Codable, Sendable {
    var partitionKey: String
    var ordinal: Int
    var memberKey: String
    var documentID: String
    var partIndex: Int
    var revisionID: String
    var charStart: Int
    var charEnd: Int
    var revisionCharCount: Int
    var textSHA256: String
    var locator: StoreSourceLocatorProbe

    static func lessThan(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.partitionKey != rhs.partitionKey { return lhs.partitionKey < rhs.partitionKey }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        if lhs.memberKey != rhs.memberKey { return lhs.memberKey < rhs.memberKey }
        if lhs.documentID != rhs.documentID { return lhs.documentID < rhs.documentID }
        if lhs.partIndex != rhs.partIndex { return lhs.partIndex < rhs.partIndex }
        if lhs.revisionID != rhs.revisionID { return lhs.revisionID < rhs.revisionID }
        if lhs.charStart != rhs.charStart { return lhs.charStart < rhs.charStart }
        if lhs.charEnd != rhs.charEnd { return lhs.charEnd < rhs.charEnd }
        return lhs.textSHA256 < rhs.textSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case partitionKey = "partition_key"
        case ordinal
        case memberKey = "member_key"
        case documentID = "document_id"
        case partIndex = "part_index"
        case revisionID = "revision_id"
        case charStart = "char_start"
        case charEnd = "char_end"
        case revisionCharCount = "revision_char_count"
        case textSHA256 = "text_sha256"
        case locator
    }
}

private struct StoreFrozenCorpusLineageEnvelope: Codable, Sendable {
    var schemaVersion = 2
    var snapshot: CorpusAnalysisSnapshot
    var slices: [StoreFrozenSliceLineageProbe]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshot
        case slices
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
