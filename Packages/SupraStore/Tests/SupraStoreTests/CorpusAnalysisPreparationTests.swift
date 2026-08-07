import CryptoKit
import Foundation
import SupraCore
@testable import SupraStore
import XCTest

final class CorpusAnalysisPreparationTests: XCTestCase {
    func testTSTORE05PreparedRunRollsBackRunPartitionsAndSlicesWhenLaterSliceFails() throws {
        // T-STORE-05 expected RED: preparation is currently split across run and
        // partition transactions, and there is no normalized slice record or one
        // atomic repository entry point. A later slice failure could therefore
        // leave runnable partial work behind.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic atomic corpus preparation")
        let text = "ATOMIC-PREPARE-RANGE-971-NONDEFAULT"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "atomic-prepare-blob-971",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/atomic-prepare-971.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "atomic-prepare-971.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "atomic-prepare-part-971",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "atomic-prepare-revision-971",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "atomic-prepare-971",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "atomic-prepare-selection-971",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "atomic-prepare-971",
            selectedBy: "test",
            decisionJSON: #"{"rule":"atomic-prepare"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )

        let runID = "atomic-prepare-run-971"
        let partitionID = "atomic-prepare-partition-971"
        let memberKey = "document:\(document.id)"
        let snapshot = CorpusAnalysisSnapshot(
            schemaVersion: 2,
            members: [CorpusAnalysisSnapshotMember(
                memberKey: memberKey,
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: [revision.id],
                indexState: document.indexStatus,
                disposition: .eligible
            )]
        )
        let run = CorpusAnalysisRunRecord(
            id: runID,
            runKey: "atomic-prepare-key-971",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":2}",
            corpusSnapshotJSON: try canonicalJSON(snapshot),
            partitionStrategy: "exact_revision_slice:characters=1971",
            partitionStrategyVersion: 2,
            modelLineageJSON: #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/atomic-prepare","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#,
            status: CorpusAnalysisRunStatus.planning.rawValue,
            requestSchemaVersion: 2,
            requestDigest: String(repeating: "9", count: 64)
        )
        let partition = CorpusAnalysisPartitionRecord(
            id: partitionID,
            runID: runID,
            partitionKey: "000000|\(memberKey)#revision:\(revision.id)#chars:0-\(text.count)",
            inputRevisionIDsJSON: try canonicalJSON([revision.id])
        )
        let valid = CorpusAnalysisPartitionSliceRecord(
            id: "atomic-prepare-slice-valid-971",
            runID: runID,
            partitionID: partitionID,
            ordinal: 0,
            memberKey: memberKey,
            documentID: document.id,
            partIndex: 0,
            revisionID: revision.id,
            charStart: 0,
            charEnd: text.count,
            revisionCharCount: text.count,
            textSHA256: sha256(text),
            locatorJSON: "{\"source_kind\":\"text\",\"char_start\":0,\"char_end\":\(text.count)}"
        )

        var nonPlanningRun = run
        nonPlanningRun.id = "atomic-prepare-nonplanning-run-971"
        nonPlanningRun.runKey = "atomic-prepare-nonplanning-key-971"
        nonPlanningRun.status = CorpusAnalysisRunStatus.running.rawValue
        var nonPlanningPartition = partition
        nonPlanningPartition.id = "atomic-prepare-nonplanning-partition-971"
        nonPlanningPartition.runID = nonPlanningRun.id
        var nonPlanningSlice = valid
        nonPlanningSlice.id = "atomic-prepare-nonplanning-slice-971"
        nonPlanningSlice.runID = nonPlanningRun.id
        nonPlanningSlice.partitionID = nonPlanningPartition.id
        XCTAssertThrowsError(
            try store.corpusAnalysis.createOrFetchPreparedRun(
                run: nonPlanningRun,
                partitions: [nonPlanningPartition],
                slices: [nonPlanningSlice]
            ),
            "atomic preparation must begin from a clean planning state"
        )
        XCTAssertNil(
            try store.corpusAnalysis.fetchRun(
                matterID: matter.id,
                id: nonPlanningRun.id
            )
        )

        // T-STORE-05 review finding expected RED: the atomic entry point checks
        // only the run's planning fields, so a caller can pre-mark a partition
        // succeeded and persist fabricated attempt/findings state without any
        // mapper execution. Preparation must accept only pristine pending work.
        let dirtyStartedAt = Date(timeIntervalSince1970: 1_790_097_131)
        let dirtyCompletedAt = Date(timeIntervalSince1970: 1_790_097_197)
        var dirtyRun = run
        dirtyRun.id = "atomic-prepare-dirty-run-971"
        dirtyRun.runKey = "atomic-prepare-dirty-key-971"
        var dirtyPartition = partition
        dirtyPartition.id = "atomic-prepare-dirty-partition-971"
        dirtyPartition.runID = dirtyRun.id
        dirtyPartition.attemptCount = 1
        dirtyPartition.attemptHistoryJSON = try canonicalJSON([
            CorpusAnalysisAttemptHistoryEntry(
                attemptNumber: 1,
                outcome: .succeeded,
                retryable: false,
                startedAt: dirtyStartedAt,
                completedAt: dirtyCompletedAt
            )
        ])
        dirtyPartition.disposition = CorpusAnalysisPartitionDisposition.succeeded.rawValue
        dirtyPartition.dispositionReason = "fabricated_preparation_success_971"
        dirtyPartition.findingsJSON = #"[{"finding_id":"fabricated-971"}]"#
        dirtyPartition.startedAt = dirtyStartedAt
        dirtyPartition.completedAt = dirtyCompletedAt
        var dirtySlice = valid
        dirtySlice.id = "atomic-prepare-dirty-slice-971"
        dirtySlice.runID = dirtyRun.id
        dirtySlice.partitionID = dirtyPartition.id

        XCTAssertThrowsError(
            try store.corpusAnalysis.createOrFetchPreparedRun(
                run: dirtyRun,
                partitions: [dirtyPartition],
                slices: [dirtySlice]
            ),
            "atomic preparation must reject precompleted partition lifecycle state"
        )
        XCTAssertNil(
            try store.corpusAnalysis.fetchRun(matterID: matter.id, id: dirtyRun.id),
            "the rejected dirty preparation must leave no run behind"
        )
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = ?",
                    arguments: [dirtyRun.id]
                ),
                0,
                "the rejected dirty preparation must leave no non-pending partition behind"
            )
        }

        // T-STORE-05 review finding expected RED: after a clean atomic prepare,
        // the legacy setDisposition API can mark v2 work succeeded with zero
        // attempts and arbitrary findings, bypassing the mapper checkpoint path.
        var lifecycleRun = run
        lifecycleRun.id = "atomic-prepare-zero-attempt-run-977"
        lifecycleRun.runKey = "atomic-prepare-zero-attempt-key-977"
        var lifecyclePartition = partition
        lifecyclePartition.id = "atomic-prepare-zero-attempt-partition-977"
        lifecyclePartition.runID = lifecycleRun.id
        var lifecycleSlice = valid
        lifecycleSlice.id = "atomic-prepare-zero-attempt-slice-977"
        lifecycleSlice.runID = lifecycleRun.id
        lifecycleSlice.partitionID = lifecyclePartition.id
        _ = try store.corpusAnalysis.createOrFetchPreparedRun(
            run: lifecycleRun,
            partitions: [lifecyclePartition],
            slices: [lifecycleSlice]
        )
        let foreignFinding =
            #"[{"id":"foreign-zero-attempt-977","value":"FOREIGN-ZERO-ATTEMPT-977","evidence":[]}]"#
        XCTAssertThrowsError(
            try store.corpusAnalysis.setDisposition(
                matterID: matter.id,
                runID: lifecycleRun.id,
                partitionID: lifecyclePartition.id,
                disposition: .succeeded,
                dispositionReason: "foreign_zero_attempt_success_977",
                findingsJSON: foreignFinding
            ),
            "v2 succeeded transitions must pass through a running attempt checkpoint"
        )
        let retainedLifecycle = try XCTUnwrap(
            store.corpusAnalysis.fetchPartitions(
                matterID: matter.id,
                runID: lifecycleRun.id
            ).first
        )
        XCTAssertEqual(retainedLifecycle.disposition, CorpusAnalysisPartitionDisposition.pending.rawValue)
        XCTAssertEqual(retainedLifecycle.attemptCount, 0)
        XCTAssertEqual(retainedLifecycle.attemptHistoryJSON, "[]")
        XCTAssertNil(retainedLifecycle.dispositionReason)
        XCTAssertNil(retainedLifecycle.findingsJSON)
        XCTAssertFalse(retainedLifecycle.findingsJSON?.contains("FOREIGN-ZERO-ATTEMPT-977") ?? false)

        var seedRun = run
        seedRun.id = "atomic-prepare-seed-run-971"
        seedRun.runKey = "atomic-prepare-seed-key-971"
        var seedPartition = partition
        seedPartition.id = "atomic-prepare-seed-partition-971"
        seedPartition.runID = seedRun.id
        var seedSlice = valid
        seedSlice.id = "atomic-prepare-global-slice-collision-971"
        seedSlice.runID = seedRun.id
        seedSlice.partitionID = seedPartition.id
        _ = try store.corpusAnalysis.createOrFetchPreparedRun(
            run: seedRun,
            partitions: [seedPartition],
            slices: [seedSlice]
        )

        var rollbackRun = run
        rollbackRun.id = "atomic-prepare-postwrite-rollback-run-971"
        rollbackRun.runKey = "atomic-prepare-postwrite-rollback-key-971"
        var rollbackPartition = partition
        rollbackPartition.id = "atomic-prepare-postwrite-rollback-partition-971"
        rollbackPartition.runID = rollbackRun.id
        var collidingSlice = valid
        collidingSlice.id = seedSlice.id
        collidingSlice.runID = rollbackRun.id
        collidingSlice.partitionID = rollbackPartition.id
        XCTAssertThrowsError(
            try store.corpusAnalysis.createOrFetchPreparedRun(
                run: rollbackRun,
                partitions: [rollbackPartition],
                slices: [collidingSlice]
            )
        )
        XCTAssertNil(
            try store.corpusAnalysis.fetchRun(
                matterID: matter.id,
                id: rollbackRun.id
            )
        )
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = ?",
                    arguments: [rollbackRun.id]
                ),
                0,
                "a database failure after run/partition inserts must roll back the whole preparation"
            )
        }

        var changedLedgerRun = seedRun
        changedLedgerRun.id = "atomic-prepare-changed-ledger-run-971"
        let split = text.count / 2
        let splitIndex = text.index(text.startIndex, offsetBy: split)
        let left = String(text[..<splitIndex])
        let right = String(text[splitIndex...])
        let changedPartition = CorpusAnalysisPartitionRecord(
            id: "atomic-prepare-changed-ledger-partition-971",
            runID: changedLedgerRun.id,
            partitionKey: "000000|\(memberKey)#revision:\(revision.id)#chars:0-\(split)|chars:\(split)-\(text.count)",
            inputRevisionIDsJSON: try canonicalJSON([revision.id])
        )
        let changedSlices = [
            CorpusAnalysisPartitionSliceRecord(
                id: "atomic-prepare-changed-ledger-left-971",
                runID: changedLedgerRun.id,
                partitionID: changedPartition.id,
                ordinal: 0,
                memberKey: memberKey,
                documentID: document.id,
                partIndex: 0,
                revisionID: revision.id,
                charStart: 0,
                charEnd: split,
                revisionCharCount: text.count,
                textSHA256: sha256(left),
                locatorJSON: "{\"source_kind\":\"text\",\"char_start\":0,\"char_end\":\(split)}"
            ),
            CorpusAnalysisPartitionSliceRecord(
                id: "atomic-prepare-changed-ledger-right-971",
                runID: changedLedgerRun.id,
                partitionID: changedPartition.id,
                ordinal: 1,
                memberKey: memberKey,
                documentID: document.id,
                partIndex: 0,
                revisionID: revision.id,
                charStart: split,
                charEnd: text.count,
                revisionCharCount: text.count,
                textSHA256: sha256(right),
                locatorJSON: "{\"source_kind\":\"text\",\"char_start\":\(split),\"char_end\":\(text.count)}"
            ),
        ]
        XCTAssertThrowsError(
            try store.corpusAnalysis.createOrFetchPreparedRun(
                run: changedLedgerRun,
                partitions: [changedPartition],
                slices: changedSlices
            ),
            "an exact retry must compare the proposed semantic ledger to the stored ledger"
        )

        var duplicateOrdinal = valid
        duplicateOrdinal.id = "atomic-prepare-slice-invalid-duplicate-ordinal-971"
        duplicateOrdinal.charStart = 1
        duplicateOrdinal.textSHA256 = sha256(String(text.dropFirst()))
        duplicateOrdinal.locatorJSON =
            "{\"source_kind\":\"text\",\"char_start\":1,\"char_end\":\(text.count)}"

        XCTAssertThrowsError(
            try store.corpusAnalysis.createOrFetchPreparedRun(
                run: run,
                partitions: [partition],
                slices: [valid, duplicateOrdinal]
            )
        )
        XCTAssertNil(try store.corpusAnalysis.fetchRun(matterID: matter.id, id: runID))
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = ?",
                    arguments: [runID]
                ),
                0
            )
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

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusAnalysisPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
