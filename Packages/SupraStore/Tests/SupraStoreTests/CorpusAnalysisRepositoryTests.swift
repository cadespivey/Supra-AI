import Foundation
import SupraCore
@testable import SupraStore
import XCTest

final class CorpusAnalysisRepositoryTests: XCTestCase {
    func testTENG03LedgerBalancesSnapshotMembersAndIdempotentTerminalPartitions() throws {
        // T-ENG-03 expected RED: no corpus-analysis records or repository exist.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic balanced corpus")
        let snapshot = CorpusAnalysisSnapshot(members: [
            .init(
                memberKey: "document:one",
                documentID: "one",
                displayName: "one.txt",
                revisionIDs: ["revision-one"],
                indexState: "text_indexed",
                disposition: .eligible
            ),
            .init(
                memberKey: "document:two",
                documentID: "two",
                displayName: "two.txt",
                revisionIDs: ["revision-two"],
                indexState: "ready",
                disposition: .eligible
            ),
            .init(
                memberKey: "import-source:hidden",
                displayName: ".synthetic-hidden",
                disposition: .excluded,
                reason: "excluded_hidden"
            ),
        ])
        let run = try store.corpusAnalysis.createOrFetchRun(CorpusAnalysisRunRecord(
            id: "balanced-run",
            runKey: "balanced-key",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: #"{"document_ids":null,"schema_version":1}"#,
            corpusSnapshotJSON: try canonicalJSON(snapshot),
            partitionStrategy: "part_range",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        ))
        let partitions = [
            CorpusAnalysisPartitionRecord(
                id: "partition-one",
                runID: run.id,
                partitionKey: "document:one#part:0",
                inputRevisionIDsJSON: #"["revision-one"]"#
            ),
            CorpusAnalysisPartitionRecord(
                id: "partition-two",
                runID: run.id,
                partitionKey: "document:two#part:0",
                inputRevisionIDsJSON: #"["revision-two"]"#
            ),
        ]
        try store.corpusAnalysis.createPartitions(
            matterID: matter.id,
            runID: run.id,
            partitions: partitions
        )
        try store.corpusAnalysis.setDisposition(
            matterID: matter.id,
            runID: run.id,
            partitionID: "partition-one",
            disposition: .succeeded,
            findingsJSON: #"[{"id":"finding-one"}]"#
        )
        try store.corpusAnalysis.setDisposition(
            matterID: matter.id,
            runID: run.id,
            partitionID: "partition-two",
            disposition: .succeeded,
            findingsJSON: #"[{"id":"finding-two"}]"#
        )
        // Retry callback with the exact terminal payload is idempotent.
        try store.corpusAnalysis.setDisposition(
            matterID: matter.id,
            runID: run.id,
            partitionID: "partition-two",
            disposition: .succeeded,
            findingsJSON: #"[{"id":"finding-two"}]"#
        )

        let coverage = try store.corpusAnalysis.coverage(matterID: matter.id, runID: run.id)
        XCTAssertEqual(coverage.snapshotMemberCount, 3)
        XCTAssertEqual(coverage.eligibleMemberCount, 2)
        XCTAssertEqual(coverage.excludedMemberCount, 1)
        XCTAssertEqual(coverage.partitionCount, 2)
        XCTAssertEqual(coverage.succeededPartitionCount, 2)
        XCTAssertEqual(coverage.pendingPartitionCount, 0)
        XCTAssertEqual(coverage.terminalPartitionCount, 2)
        XCTAssertEqual(coverage.balanceErrorCount, 0)
        XCTAssertEqual(try store.corpusAnalysis.fetchPartitions(matterID: matter.id, runID: run.id).count, 2)
    }

    func testTENG04CorpusCompleteWriteRejectsAnyNonSucceededPartition() throws {
        // T-ENG-04 expected RED: no DB-backed corpus-complete guard exists.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic guarded corpus")
        let snapshot = CorpusAnalysisSnapshot(members: [
            .init(
                memberKey: "document:guarded",
                documentID: "guarded",
                displayName: "guarded.txt",
                revisionIDs: ["guarded-revision"],
                indexState: "ready",
                disposition: .eligible
            ),
        ])
        let run = try store.corpusAnalysis.createOrFetchRun(CorpusAnalysisRunRecord(
            id: "guarded-run",
            runKey: "guarded-key",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: #"{"document_ids":null,"schema_version":1}"#,
            corpusSnapshotJSON: try canonicalJSON(snapshot),
            partitionStrategy: "part_range",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        ))
        try store.corpusAnalysis.createPartitions(
            matterID: matter.id,
            runID: run.id,
            partitions: [CorpusAnalysisPartitionRecord(
                id: "guarded-partition",
                runID: run.id,
                partitionKey: "document:guarded#part:0",
                inputRevisionIDsJSON: #"["guarded-revision"]"#
            )]
        )
        try store.corpusAnalysis.setDisposition(
            matterID: matter.id,
            runID: run.id,
            partitionID: "guarded-partition",
            disposition: .failed,
            dispositionReason: "synthetic_mapper_failure",
            errorSummary: "synthetic mapper failure"
        )

        XCTAssertThrowsError(try store.corpusAnalysis.finalizeRun(
            matterID: matter.id,
            runID: run.id,
            assuranceState: .corpusComplete,
            assuranceReasons: [],
            exclusionsDisclosed: true
        )) { error in
            XCTAssertEqual(error as? CorpusAnalysisRepositoryError, .corpusCompleteRequiresAllSucceeded)
        }
        XCTAssertNotEqual(
            try store.corpusAnalysis.fetchRun(matterID: matter.id, id: run.id)?.status,
            CorpusAnalysisRunStatus.persisted.rawValue
        )

        let finalized = try store.corpusAnalysis.finalizeRun(
            matterID: matter.id,
            runID: run.id,
            assuranceState: .corpusIncomplete,
            assuranceReasons: ["One partition failed."],
            exclusionsDisclosed: true
        )
        XCTAssertEqual(finalized.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(finalized.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorpusAnalysisRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
