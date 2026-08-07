import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Behavioral REDs use today's run-id payload so their assertion failures can
/// be observed separately from the missing v2 compile contract.
@MainActor
final class CorpusReviewQueueExecutionTests: XCTestCase {
    func testTQUEUE02BootstrapAutoPumpsPersistedCorpusJobExactlyOnceWhenRunnerExists() async throws {
        // T-QUEUE-02 expected RED: bootstrap refreshes persisted jobs but never
        // starts the FIFO pump, leaving the job queued and runner calls at zero.
        let store = try makeStore(testName: "TQUEUE02")
        let matter = try store.matters.createMatter(name: "Synthetic bootstrap corpus")
        let payload = CorpusAnalysisJobPayload(runID: "run-bootstrap-exactly-once")
        let job = try enqueuePersistedJob(store: store, matterID: matter.id, payload: payload)
        let recorder = ExistingPayloadRecorder()
        let queue = makeQueue(store: store) { received in
            await recorder.record(received)
        }

        queue.bootstrap()
        await queue.waitUntilIdle()

        let received = await recorder.payloads
        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        XCTAssertEqual(received, [payload])
        XCTAssertEqual(received.count, 1, "bootstrap must run one persisted job exactly once")
        XCTAssertEqual(persisted.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(persisted.phase, DocumentProcessingPhase.complete.rawValue)
        XCTAssertFalse(queue.queuedJobs.contains { $0.id == job.id })
    }

    func testTQUEUE04ActiveCancellationReachesSwiftTaskAndBalancesCorpusLedger() async throws {
        // T-QUEUE-04 expected RED: cancelQueuedJob changes only the job row; it
        // does not cancel the active Swift task or balance the linked corpus run.
        // The approved cancel(jobID:) API may retain this method as its legacy alias.
        let store = try makeStore(testName: "TQUEUE04")
        let matter = try store.matters.createMatter(name: "Synthetic active cancellation")
        let run = try makeCancelledProgressLedger(
            store: store,
            matterID: matter.id,
            runID: "run-active-cancel-ledger",
            succeededCount: 0,
            partitionCount: 4,
            cancelBeforeReturn: false
        )
        let probe = ExistingCancellationProbe()
        let queue = makeQueue(store: store) { _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                await probe.markCancellationObserved()
                throw CancellationError()
            }
        }

        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(matterID: matter.id, runID: run.id))
        try await waitUntilStarted(probe)
        queue.cancelQueuedJob(id: jobID)
        await queue.waitUntilIdle()

        let cancellationObserved = await probe.cancellationObserved
        let persistedJob = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        let persistedRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: run.id))
        let partitions = try store.corpusAnalysis.fetchPartitions(matterID: matter.id, runID: run.id)

        XCTAssertTrue(cancellationObserved, "active cancellation must reach the runner Swift task")
        XCTAssertEqual(persistedJob.status, DocumentProcessingJobStatus.cancelled.rawValue)
        XCTAssertEqual(persistedJob.phase, DocumentProcessingPhase.cancelled.rawValue)
        XCTAssertEqual(persistedRun.status, CorpusAnalysisRunStatus.cancelled.rawValue)
        let coverage = persistedRun.coverageJSON.flatMap { json in
            try? JSONDecoder().decode(CorpusAnalysisCoverage.self, from: Data(json.utf8))
        }
        XCTAssertNotNil(coverage, "active cancellation must persist a balanced coverage ledger")
        XCTAssertEqual(coverage?.partitionCount, 4)
        XCTAssertEqual(coverage?.pendingPartitionCount, 0)
        XCTAssertEqual(coverage?.cancelledPartitionCount, 4)
        XCTAssertEqual(coverage?.terminalPartitionCount, 4)
        XCTAssertEqual(coverage?.balanceErrorCount, 0)
        XCTAssertTrue(partitions.allSatisfy {
            $0.disposition == CorpusAnalysisPartitionDisposition.cancelled.rawValue
        })
    }

    func testTQUEUE05RelaunchRunnerSurfacesPersistedTwoOfFiveCoverage() async throws {
        // T-QUEUE-05 expected RED: bootstrap never invokes the runner, so the
        // persisted 2/5 coverage ledger is not reconstructed after relaunch.
        let store = try makeStore(testName: "TQUEUE05")
        let matter = try store.matters.createMatter(name: "Synthetic progress relaunch")
        let run = try makeCancelledProgressLedger(
            store: store,
            matterID: matter.id,
            runID: "run-progress-two-of-five",
            succeededCount: 2,
            partitionCount: 5,
            cancelBeforeReturn: true
        )
        let payload = CorpusAnalysisJobPayload(runID: run.id)
        let job = try enqueuePersistedJob(store: store, matterID: matter.id, payload: payload)
        let recorder = ExistingProgressRecorder()
        let relaunchedQueue = makeQueue(store: store) { received in
            let persisted = try Self.requiredRun(
                store: store,
                matterID: matter.id,
                runID: received.runID
            )
            await recorder.record(payload: received, coverage: try Self.decodeCoverage(persisted))
        }

        relaunchedQueue.bootstrap()
        await relaunchedQueue.waitUntilIdle()

        let recordedCoverage = await recorder.coverage
        let surfaced = try XCTUnwrap(recordedCoverage)
        let receivedPayloads = await recorder.payloads
        let persistedJob = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        XCTAssertEqual(receivedPayloads, [payload])
        XCTAssertEqual(surfaced.partitionCount, 5)
        XCTAssertEqual(surfaced.succeededPartitionCount, 2)
        XCTAssertEqual(surfaced.cancelledPartitionCount, 3)
        XCTAssertEqual(surfaced.terminalPartitionCount, 5)
        XCTAssertEqual(surfaced.balanceErrorCount, 0)
        XCTAssertEqual(persistedJob.status, DocumentProcessingJobStatus.complete.rawValue)
    }

    private func makeCancelledProgressLedger(
        store: SupraStore,
        matterID: String,
        runID: String,
        succeededCount: Int,
        partitionCount: Int,
        cancelBeforeReturn: Bool
    ) throws -> CorpusAnalysisRunRecord {
        let revisionIDs = (1...partitionCount).map { "revision-nondefault-\($0)" }
        let snapshot = CorpusAnalysisSnapshot(members: [.init(
            memberKey: "document:synthetic-ledger",
            documentID: "synthetic-ledger-document",
            displayName: "Synthetic Ledger.txt",
            revisionIDs: revisionIDs,
            indexState: DocumentIndexStatus.textIndexed.rawValue,
            disposition: .eligible
        )])
        let proposed = CorpusAnalysisRunRecord(
            id: runID,
            runKey: "run-key-\(runID)",
            matterID: matterID,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: try canonicalJSON(CorpusAnalysisScope.wholeMatter),
            corpusSnapshotJSON: try canonicalJSON(snapshot),
            partitionStrategy: "part_range:characters=31337",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        )
        let run = try store.corpusAnalysis.createOrFetchRun(proposed)
        let partitions = revisionIDs.enumerated().map { index, revisionID in
            CorpusAnalysisPartitionRecord(
                id: "partition-\(runID)-\(index)",
                runID: run.id,
                partitionKey: String(format: "partition:%04d", index),
                inputRevisionIDsJSON: #"["\#(revisionID)"]"#
            )
        }
        try store.corpusAnalysis.createPartitions(
            matterID: matterID,
            runID: run.id,
            partitions: partitions
        )
        _ = try store.corpusAnalysis.updateStatus(matterID: matterID, runID: run.id, to: .running)
        for partition in partitions.prefix(succeededCount) {
            _ = try store.corpusAnalysis.beginAttempt(
                matterID: matterID,
                runID: run.id,
                partitionID: partition.id
            )
            try store.corpusAnalysis.completeAttemptSucceeded(
                matterID: matterID,
                runID: run.id,
                partitionID: partition.id,
                findingsJSON: "[]"
            )
        }
        if cancelBeforeReturn {
            return try store.corpusAnalysis.cancelRun(matterID: matterID, runID: run.id)
        }
        return run
    }

    private func enqueuePersistedJob(
        store: SupraStore,
        matterID: String,
        payload: CorpusAnalysisJobPayload
    ) throws -> DocumentProcessingJobRecord {
        let data = try JSONEncoder().encode(payload)
        return try store.documentJobs.enqueueJob(
            matterID: matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: String(decoding: data, as: UTF8.self)
        )
    }

    private func makeStore(testName: String) throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusReviewQueueExecution-\(testName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeQueue(
        store: SupraStore,
        runner: @escaping @Sendable (CorpusAnalysisJobPayload) async throws -> Void
    ) -> DocumentProcessingQueue {
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "CorpusReviewQueueExecutionStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store) },
            notifier: SilentExecutionNotifier(),
            corpusAnalysisRunner: runner
        )
    }

    private func waitUntilStarted(_ probe: ExistingCancellationProbe) async throws {
        for _ in 0..<200 {
            if await probe.started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueExecutionTestError.runnerDidNotStart
    }

    nonisolated private static func requiredRun(
        store: SupraStore,
        matterID: String,
        runID: String
    ) throws -> CorpusAnalysisRunRecord {
        if let run = try store.corpusAnalysis.fetchRun(matterID: matterID, id: runID) {
            return run
        }
        throw QueueExecutionTestError.missingRun(runID)
    }

    nonisolated private static func decodeCoverage(
        _ run: CorpusAnalysisRunRecord
    ) throws -> CorpusAnalysisCoverage {
        guard let coverageJSON = run.coverageJSON else {
            throw QueueExecutionTestError.missingCoverage(run.id)
        }
        return try JSONDecoder().decode(
            CorpusAnalysisCoverage.self,
            from: Data(coverageJSON.utf8)
        )
    }

    private func decodeCoverage(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisCoverage {
        try Self.decodeCoverage(run)
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private enum QueueExecutionTestError: Error {
    case missingCoverage(String)
    case missingRun(String)
    case runnerDidNotStart
}

private actor ExistingPayloadRecorder {
    private(set) var payloads: [CorpusAnalysisJobPayload] = []
    func record(_ payload: CorpusAnalysisJobPayload) { payloads.append(payload) }
}

private actor ExistingCancellationProbe {
    private(set) var started = false
    private(set) var cancellationObserved = false
    func markStarted() { started = true }
    func markCancellationObserved() { cancellationObserved = true }
}

private actor ExistingProgressRecorder {
    private(set) var coverage: CorpusAnalysisCoverage?
    private(set) var payloads: [CorpusAnalysisJobPayload] = []

    func record(payload: CorpusAnalysisJobPayload, coverage: CorpusAnalysisCoverage) {
        payloads.append(payload)
        self.coverage = coverage
    }
}

private struct SilentExecutionNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
