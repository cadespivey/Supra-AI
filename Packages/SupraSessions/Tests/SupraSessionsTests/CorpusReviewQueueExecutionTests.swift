import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class CorpusReviewQueueExecutionTests: XCTestCase {
    func testTQUEUE02BootstrapPumpsV2JobAndDoesNotRedispatchCompletedWork() async throws {
        // T-QUEUE-02 expected RED: bootstrap refreshes persisted jobs but never
        // starts the FIFO pump, leaving a reconstructible v2 job queued.
        let store = try makeStore(testName: "TQUEUE02")
        let fixture = try prepareFixture(store: store, caseName: "bootstrap", partCount: 1)
        let job = try enqueuePersistedJob(
            store: store,
            matterID: fixture.matterID,
            payload: fixture.payload
        )
        let recorder = PayloadRecorder()
        let runner = CorpusAnalysisQueueRunner(
            store: store,
            resolvePinnedModel: { pinnedModel, _ in pinnedModel },
            exhaustiveListGenerator: { _ in
                return #"{"schema_version":1,"items":[]}"#
            }
        )
        let queue = makeQueue(store: store) { received in
            await recorder.record(received)
            try await runner.run(received)
        }

        queue.bootstrap()
        await queue.waitUntilIdle()
        queue.bootstrap()
        await queue.waitUntilIdle()

        let received = await recorder.payloads
        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        XCTAssertEqual(received, [fixture.payload])
        XCTAssertEqual(
            received.count,
            1,
            "a later bootstrap must not redispatch a durably completed corpus job"
        )
        XCTAssertEqual(persisted.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(persisted.phase, DocumentProcessingPhase.complete.rawValue)
        XCTAssertFalse(queue.queuedJobs.contains { $0.id == job.id })
        let persistedRun = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(
                matterID: fixture.matterID,
                id: fixture.payload.runID
            )
        )
        XCTAssertEqual(persistedRun.status, CorpusAnalysisRunStatus.persisted.rawValue)
    }

    func testTQUEUE04ActiveCancelCancelsSwiftTaskBalancesRunAndDrainsFollower() async throws {
        // T-QUEUE-04 expected RED: the approved cancel(jobID:) API is absent and
        // the row-only legacy helper neither cancels active work nor preserves a
        // live FIFO pump for the next queued corpus job.
        let store = try makeStore(testName: "TQUEUE04")
        let active = try prepareFixture(store: store, caseName: "active-cancel", partCount: 4)
        let follower = try prepareFixture(store: store, caseName: "cancel-follower", partCount: 1)
        let activePartitions = try store.corpusAnalysis.fetchPartitions(
            matterID: active.matterID,
            runID: active.payload.runID
        )
        let followerPartitions = try store.corpusAnalysis.fetchPartitions(
            matterID: follower.matterID,
            runID: follower.payload.runID
        )
        XCTAssertEqual(activePartitions.count, 4, "wire proof requires a non-default four-part ledger")
        XCTAssertEqual(followerPartitions.count, 1)

        let probe = CancellationAndFollowerProbe(
            activePartitionIDs: Set(activePartitions.map(\.id)),
            followerPartitionIDs: Set(followerPartitions.map(\.id))
        )
        let runner = CorpusAnalysisQueueRunner(
            store: store,
            resolvePinnedModel: { pinnedModel, _ in pinnedModel },
            exhaustiveListGenerator: { input in
                try await probe.generate(input)
            }
        )
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }
        let activeJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: active.matterID,
            payload: active.payload
        ))
        try await waitUntilStarted(probe)
        let followerJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: follower.matterID,
            payload: follower.payload
        ))

        queue.cancel(jobID: activeJobID)
        await queue.waitUntilIdle()

        let cancellationObserved = await probe.cancellationObserved
        let followerGeneratedPartitionIDs = await probe.followerGeneratedPartitionIDs
        let persistedActiveJob = try XCTUnwrap(store.documentJobs.fetchJob(id: activeJobID))
        let persistedFollowerJob = try XCTUnwrap(store.documentJobs.fetchJob(id: followerJobID))
        let persistedRun = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(matterID: active.matterID, id: active.payload.runID)
        )
        let persistedFollowerRun = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(matterID: follower.matterID, id: follower.payload.runID)
        )
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: active.matterID,
            runID: active.payload.runID
        )

        XCTAssertTrue(cancellationObserved, "active cancellation must reach the runner Swift task")
        XCTAssertEqual(persistedActiveJob.status, DocumentProcessingJobStatus.cancelled.rawValue)
        XCTAssertEqual(persistedActiveJob.phase, DocumentProcessingPhase.cancelled.rawValue)
        XCTAssertEqual(persistedRun.status, CorpusAnalysisRunStatus.cancelled.rawValue)
        let coverage = try decodeCoverage(persistedRun)
        XCTAssertEqual(coverage.partitionCount, 4)
        XCTAssertEqual(coverage.pendingPartitionCount, 0)
        XCTAssertEqual(coverage.cancelledPartitionCount, 4)
        XCTAssertEqual(coverage.terminalPartitionCount, 4)
        XCTAssertEqual(coverage.balanceErrorCount, 0)
        XCTAssertTrue(partitions.allSatisfy {
            $0.disposition == CorpusAnalysisPartitionDisposition.cancelled.rawValue
        })
        XCTAssertEqual(
            Set(followerGeneratedPartitionIDs),
            Set(followerPartitions.map(\.id)),
            "the FIFO must run the follower through the production runner after active cancel"
        )
        XCTAssertEqual(persistedFollowerJob.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(persistedFollowerJob.phase, DocumentProcessingPhase.complete.rawValue)
        XCTAssertEqual(persistedFollowerRun.status, CorpusAnalysisRunStatus.persisted.rawValue)
    }

    func testTQUEUE05RelaunchResumesOnlyRemainingThreeOfFiveAndReportsTwoThroughFive() async throws {
        // T-QUEUE-05 expected RED: there is no production runner wired to the
        // queue, bootstrap does not pump, and the old probe merely rereads a
        // cancelled 2/5 ledger before incorrectly completing the job.
        let store = try makeStore(testName: "TQUEUE05")
        let fixture = try prepareFixture(store: store, caseName: "resume-two-of-five", partCount: 5)
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: fixture.matterID,
            runID: fixture.payload.runID
        )
        XCTAssertEqual(partitions.count, 5)
        for partition in partitions.prefix(2) {
            _ = try store.corpusAnalysis.beginAttempt(
                matterID: fixture.matterID,
                runID: fixture.payload.runID,
                partitionID: partition.id
            )
            try store.corpusAnalysis.completeAttemptSucceeded(
                matterID: fixture.matterID,
                runID: fixture.payload.runID,
                partitionID: partition.id,
                findingsJSON: "[]"
            )
        }
        let before = try store.corpusAnalysis.coverage(
            matterID: fixture.matterID,
            runID: fixture.payload.runID
        )
        XCTAssertEqual(before.succeededPartitionCount, 2)
        XCTAssertEqual(before.pendingPartitionCount, 3)

        let job = try enqueuePersistedJob(
            store: store,
            matterID: fixture.matterID,
            payload: fixture.payload
        )
        let probe = ResumeProbe()
        let runner = CorpusAnalysisQueueRunner(
            store: store,
            resolvePinnedModel: { pinnedModel, _ in pinnedModel },
            exhaustiveListGenerator: { input in
                await probe.recordGeneration(partitionID: input.partition.partitionID)
                return #"{"schema_version":1,"items":[]}"#
            },
            progressHandler: { runID, coverage in
                await probe.recordProgress(runID: runID, coverage: coverage)
            }
        )
        let relaunchedQueue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }

        relaunchedQueue.bootstrap()
        await relaunchedQueue.waitUntilIdle()

        let generatedPartitionIDs = await probe.generatedPartitionIDs
        let progress = await probe.progress
        let finalRun = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(matterID: fixture.matterID, id: fixture.payload.runID)
        )
        let finalCoverage = try decodeCoverage(finalRun)
        let persistedJob = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        let alreadySucceededIDs = Set(partitions.prefix(2).map(\.id))
        let originallyPendingIDs = Set(partitions.dropFirst(2).map(\.id))

        XCTAssertEqual(generatedPartitionIDs.count, 3, "only unfinished partitions may generate")
        XCTAssertEqual(Set(generatedPartitionIDs), originallyPendingIDs)
        XCTAssertTrue(alreadySucceededIDs.isDisjoint(with: generatedPartitionIDs))
        XCTAssertEqual(finalCoverage.partitionCount, 5)
        XCTAssertEqual(finalCoverage.succeededPartitionCount, 5)
        XCTAssertEqual(finalCoverage.pendingPartitionCount, 0)
        XCTAssertEqual(finalCoverage.terminalPartitionCount, 5)
        XCTAssertEqual(finalCoverage.balanceErrorCount, 0)
        XCTAssertEqual(finalRun.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(persistedJob.status, DocumentProcessingJobStatus.complete.rawValue)

        let thisRunProgress = progress
            .filter { $0.runID == fixture.payload.runID }
            .map { $0.coverage.succeededPartitionCount }
        XCTAssertEqual(thisRunProgress.first, 2, "relaunch must surface persisted 2/5 before resuming")
        XCTAssertEqual(thisRunProgress.last, 5)
        XCTAssertEqual(Array(Set(thisRunProgress)).sorted(), [2, 3, 4, 5])
    }

    private static let pinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/queue-execution-model",
        modelRevision: String(repeating: "e", count: 40),
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "c", count: 64)
    )

    private func prepareFixture(
        store: SupraStore,
        caseName: String,
        partCount: Int
    ) throws -> QueueExecutionFixture {
        let matter = try store.matters.createMatter(name: "Synthetic queue \(caseName)")
        let documentID = try insertDocument(
            store: store,
            matterID: matter.id,
            caseName: caseName,
            partCount: partCount
        )
        let request = ExhaustiveListQueuedRequest(
            taskSchemaVersion: ExhaustiveListTask.schemaVersion,
            promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
            runKey: "run-key-\(caseName)",
            matterID: matter.id,
            title: "Synthetic queue execution \(caseName)",
            query: "List each nondefault queue marker for \(caseName).",
            scope: CorpusAnalysisScope(schemaVersion: 7, documentIDs: [documentID]),
            characterBudget: 100,
            maximumRetryCount: 3
        )
        let payload = try CorpusAnalysisQueuePreparer(store: store).prepareExhaustiveList(
            request: request,
            pinnedModel: Self.pinnedModel
        )
        return QueueExecutionFixture(matterID: matter.id, payload: payload)
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        caseName: String,
        partCount: Int
    ) throws -> String {
        let partTexts = (1...partCount).map { index -> String in
            let prefix = "QUEUE-\(index)-"
            return prefix + String(repeating: "q", count: 80 - prefix.count)
        }
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "queue-execution-\(caseName)-\(UUID().uuidString)",
            byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
            originalExtension: "txt",
            managedRelativePath: "blobs/queue-execution-\(caseName).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: "\(caseName).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let parts = partTexts.enumerated().map { index, text in
            DocumentPagePartRecord(
                id: "\(caseName)-part-\(index)",
                documentID: document.id,
                partIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            )
        }
        let revisions = partTexts.enumerated().map { index, text in
            DocumentPartRevisionRecord(
                id: "\(caseName)-revision-\(index)",
                documentID: document.id,
                partIndex: index,
                derivationKey: "queue-execution-\(index)",
                origin: "synthetic_test",
                method: "plain-text",
                text: text,
                charCount: text.count
            )
        }
        let selections = revisions.map { revision in
            DocumentPartSelectionRecord(
                id: "\(caseName)-selection-\(revision.partIndex)",
                documentID: document.id,
                partIndex: revision.partIndex,
                selectedRevisionID: revision.id,
                selectionKey: "queue-execution-\(revision.partIndex)",
                selectedBy: "test",
                decisionJSON: #"{"rule":"queue-execution"}"#
            )
        }
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: parts,
            revisions: revisions,
            selections: selections
        )
        return document.id
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

    private func waitUntilStarted(_ probe: CancellationAndFollowerProbe) async throws {
        for _ in 0..<200 {
            if await probe.started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueExecutionTestError.runnerDidNotStart
    }

    private func decodeCoverage(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisCoverage {
        guard let coverageJSON = run.coverageJSON else {
            throw QueueExecutionTestError.missingCoverage(run.id)
        }
        return try JSONDecoder().decode(CorpusAnalysisCoverage.self, from: Data(coverageJSON.utf8))
    }
}

private struct QueueExecutionFixture {
    var matterID: String
    var payload: CorpusAnalysisJobPayload
}

private enum QueueExecutionTestError: Error {
    case missingCoverage(String)
    case runnerDidNotStart
    case unexpectedPartition(String)
}

private actor PayloadRecorder {
    private(set) var payloads: [CorpusAnalysisJobPayload] = []
    func record(_ payload: CorpusAnalysisJobPayload) { payloads.append(payload) }
}

private actor CancellationAndFollowerProbe {
    private let activePartitionIDs: Set<String>
    private let followerPartitionIDs: Set<String>
    private(set) var started = false
    private(set) var cancellationObserved = false
    private(set) var followerGeneratedPartitionIDs: [String] = []

    init(activePartitionIDs: Set<String>, followerPartitionIDs: Set<String>) {
        self.activePartitionIDs = activePartitionIDs
        self.followerPartitionIDs = followerPartitionIDs
    }

    func generate(_ input: ExhaustiveListGenerationInput) async throws -> String {
        let partitionID = input.partition.partitionID
        if followerPartitionIDs.contains(partitionID) {
            followerGeneratedPartitionIDs.append(partitionID)
            return #"{"schema_version":1,"items":[]}"#
        }
        guard activePartitionIDs.contains(partitionID) else {
            throw QueueExecutionTestError.unexpectedPartition(partitionID)
        }
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
        return #"{"schema_version":1,"items":[]}"#
    }
}

private struct RecordedQueueProgress: Sendable {
    var runID: String
    var coverage: CorpusAnalysisCoverage
}

private actor ResumeProbe {
    private(set) var generatedPartitionIDs: [String] = []
    private(set) var progress: [RecordedQueueProgress] = []

    func recordGeneration(partitionID: String) {
        generatedPartitionIDs.append(partitionID)
    }

    func recordProgress(runID: String, coverage: CorpusAnalysisCoverage) {
        progress.append(RecordedQueueProgress(runID: runID, coverage: coverage))
    }
}

private struct SilentExecutionNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
