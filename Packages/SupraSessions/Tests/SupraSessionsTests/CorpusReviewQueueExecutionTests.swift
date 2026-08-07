import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
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
        let versionID = try XCTUnwrap(
            persistedRun.structuredOutputVersionID,
            "the production runner must execute the prepared task through output publication"
        )
        let version = try XCTUnwrap(store.structuredOutputs.fetchVersion(id: versionID))
        XCTAssertNotNil(
            try store.documentSources.fetchSourceSet(structuredOutputVersionID: version.id),
            "the published version must retain its exhaustive source set"
        )
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
        queue.bootstrap()
        let activeJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: active.matterID,
            payload: active.payload
        ))
        try await waitUntilStarted(probe)
        queue.bootstrap()
        XCTAssertEqual(
            try store.documentJobs.fetchJob(id: activeJobID)?.status,
            DocumentProcessingJobStatus.active.rawValue,
            "repeated bootstrap must not reconcile this process's live job as interrupted"
        )
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

    func testTQUEUE04LiveCancellationWaitsForConfirmedRuntimeQuiescenceBeforeReturning() async throws {
        // T-QUEUE-04 expected RED: CorpusAnalysisQueueRunner.live starts
        // cancelGeneration in an unowned Task and returns CancellationError
        // without awaiting its reply. The queue can therefore advance its FIFO
        // before the XPC model actor confirms that the old generation unwound.
        let store = try makeStore(testName: "TQUEUE04-LIVE-QUIESCENCE")
        let runtime = LiveQuiescenceRuntimeStub()
        let liveModel = try installLiveContentBoundModel(store: store)
        let fixture = try prepareFixture(
            store: store,
            caseName: "live-cancel-quiescence",
            partCount: 1,
            pinnedModel: liveModel.pinnedModel
        )
        let library = ModelLibrary(
            store: store,
            runtimeClient: runtime,
            managedModelRoots: [liveModel.managedRoot]
        )
        library.refresh()
        let runner = CorpusAnalysisQueueRunner.live(
            store: store,
            modelLibrary: library,
            runtimeClient: runtime
        )
        let completion = LiveRunnerCompletionProbe()
        let runnerTask = Task {
            let outcome: LiveRunnerOutcome
            do {
                try await runner.run(fixture.payload)
                outcome = .succeeded
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await completion.record(outcome)
            return outcome
        }

        try await waitUntilLiveGenerationStarted(runtime)
        runnerTask.cancel()
        try await waitUntilLiveCancellationRequested(runtime)
        let returnedBeforeQuiescence = try await runnerReturnedWithinObservationWindow(completion)

        await runtime.confirmQuiescence()
        let outcome = await runnerTask.value
        try await waitUntilLiveCancellationResponseReturned(runtime)

        XCTAssertFalse(
            returnedBeforeQuiescence,
            "the live runner, and therefore its FIFO owner, must remain suspended until cancelGeneration confirms XPC quiescence"
        )
        XCTAssertEqual(outcome, .cancelled)
    }

    func testTQUEUE06SoftDeleteCancellationWinsActiveRunnerSuccess() async throws {
        // T-QUEUE-06 success expected RED: softDeleteMatter changes the active row
        // to cancelled, but runCorpusAnalysis later completes it unconditionally.
        try await assertSoftDeleteCancellationWins(
            outcome: .success,
            testName: "TQUEUE06-success",
            caseName: "deleted-active-success"
        )
    }

    func testTQUEUE06SoftDeleteCancellationWinsActiveRunnerFailure() async throws {
        // T-QUEUE-06 failure expected RED: softDeleteMatter changes the active row
        // to cancelled, but runCorpusAnalysis later fails it unconditionally.
        try await assertSoftDeleteCancellationWins(
            outcome: .failure,
            testName: "TQUEUE06-failure",
            caseName: "deleted-active-failure"
        )
    }

    private func assertSoftDeleteCancellationWins(
        outcome: SyntheticRunnerOutcome,
        testName: String,
        caseName: String
    ) async throws {
        let store = try makeStore(testName: testName)
        let fixture = try prepareFixture(store: store, caseName: caseName, partCount: 1)
        let gate = DeletionRaceRunnerGate()
        let queue = makeQueue(store: store) { _ in
            await gate.waitForRelease()
            if outcome == .failure {
                throw QueueExecutionTestError.syntheticRunnerFailure
            }
        }
        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: fixture.matterID,
            payload: fixture.payload
        ))
        await gate.waitUntilStarted()
        XCTAssertEqual(
            try store.documentJobs.fetchJob(id: jobID)?.status,
            DocumentProcessingJobStatus.active.rawValue,
            "the fixture must delete a genuinely active runner"
        )

        try store.matters.softDeleteMatter(id: fixture.matterID)
        XCTAssertNil(try store.matters.fetchMatter(id: fixture.matterID))
        XCTAssertEqual(
            try store.documentJobs.fetchJob(id: jobID)?.status,
            DocumentProcessingJobStatus.cancelled.rawValue,
            "matter deletion must establish cancellation before runner \(outcome.rawValue) returns"
        )
        await gate.release()
        await queue.waitUntilIdle()

        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        XCTAssertEqual(
            persisted.status,
            DocumentProcessingJobStatus.cancelled.rawValue,
            "a late runner \(outcome.rawValue) must not resurrect a deletion-cancelled job"
        )
        if outcome == .failure {
            XCTAssertNil(
                persisted.errorSummary,
                "a rejected late failure must not overwrite the deletion cancellation with an error"
            )
        }
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
        _ = try store.corpusAnalysis.updateStatus(
            matterID: fixture.matterID,
            runID: fixture.payload.runID,
            to: .running
        )
        let orphanedPartition = partitions[2]
        _ = try store.corpusAnalysis.beginAttempt(
            matterID: fixture.matterID,
            runID: fixture.payload.runID,
            partitionID: orphanedPartition.id
        )
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

        let resumedOrphan = try XCTUnwrap(
            store.corpusAnalysis.fetchPartitions(
                matterID: fixture.matterID,
                runID: fixture.payload.runID
            ).first { $0.id == orphanedPartition.id }
        )
        let attemptHistory = try JSONDecoder().decode(
            [CorpusAnalysisAttemptHistoryEntry].self,
            from: Data(resumedOrphan.attemptHistoryJSON.utf8)
        )
        XCTAssertEqual(attemptHistory.count, 2)
        XCTAssertEqual(attemptHistory[0].outcome, .failed)
        XCTAssertEqual(attemptHistory[0].retryable, true)
        XCTAssertEqual(attemptHistory[1].outcome, .succeeded)

        let finalVersionID = try XCTUnwrap(finalRun.structuredOutputVersionID)
        let finalVersion = try XCTUnwrap(
            store.structuredOutputs.fetchVersion(id: finalVersionID)
        )
        let generationID = try XCTUnwrap(finalVersion.generationSessionID)
        let generation = try XCTUnwrap(
            store.generation.fetchGenerationSession(generationID: generationID)
        )
        for index in 1...5 {
            XCTAssertTrue(
                generation.prompt.contains("QUEUE-\(index)-"),
                "resume audit lineage must reconstruct every frozen partition prompt, including prior checkpoints"
            )
        }
    }

    private static let pinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/queue-execution-model",
        modelRevision: String(repeating: "e", count: 40),
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "c", count: 64)
    )

    private static let livePinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "mlx-community/Release-Smoke-4bit",
        modelRevision: String(repeating: "a", count: 40),
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"
    )

    private func prepareFixture(
        store: SupraStore,
        caseName: String,
        partCount: Int,
        pinnedModel: CorpusAnalysisPinnedModel = CorpusReviewQueueExecutionTests.pinnedModel
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
            pinnedModel: pinnedModel
        )
        return QueueExecutionFixture(matterID: matter.id, payload: payload)
    }

    private func installLiveContentBoundModel(
        store: SupraStore
    ) throws -> LiveContentBoundModelFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusReviewLiveModel-\(UUID().uuidString)",
            isDirectory: true
        )
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let modelDirectory = managedRoot.appendingPathComponent(
            "release-smoke",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data("protected-release-weight-canary".utf8),
        ]
        for (relativePath, data) in payloads {
            try data.write(to: modelDirectory.appendingPathComponent(relativePath))
        }
        let manifest = ModelArtifactManifest(
            repositoryID: Self.livePinnedModel.modelRepository,
            revision: Self.livePinnedModel.modelRevision,
            files: payloads.map { relativePath, data in
                ModelArtifactManifest.File(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(data)
                )
            }
        )
        try ManagedModelStorage.writeManifest(
            manifest,
            to: ManagedModelStorage.manifestURL(in: modelDirectory)
        )
        try store.models.upsertModel(ModelRecord(
            id: "88888888-8888-4888-8888-888888888888",
            displayName: "Synthetic live cancellation model",
            path: modelDirectory.path,
            bookmarkData: nil
        ))
        return LiveContentBoundModelFixture(
            managedRoot: managedRoot,
            pinnedModel: Self.livePinnedModel
        )
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

    private func waitUntilLiveGenerationStarted(
        _ runtime: LiveQuiescenceRuntimeStub
    ) async throws {
        for _ in 0..<200 {
            if await runtime.generationStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueExecutionTestError.liveGenerationDidNotStart
    }

    private func waitUntilLiveCancellationRequested(
        _ runtime: LiveQuiescenceRuntimeStub
    ) async throws {
        for _ in 0..<200 {
            if await runtime.cancellationRequested { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueExecutionTestError.liveCancellationWasNotRequested
    }

    private func runnerReturnedWithinObservationWindow(
        _ completion: LiveRunnerCompletionProbe
    ) async throws -> Bool {
        for _ in 0..<100 {
            if await completion.outcome != nil { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await completion.outcome != nil
    }

    private func waitUntilLiveCancellationResponseReturned(
        _ runtime: LiveQuiescenceRuntimeStub
    ) async throws {
        for _ in 0..<200 {
            if await runtime.cancellationResponseReturned { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueExecutionTestError.liveCancellationResponseDidNotReturn
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

private struct LiveContentBoundModelFixture {
    var managedRoot: URL
    var pinnedModel: CorpusAnalysisPinnedModel
}

private enum QueueExecutionTestError: Error {
    case missingCoverage(String)
    case runnerDidNotStart
    case liveGenerationDidNotStart
    case liveCancellationWasNotRequested
    case liveCancellationResponseDidNotReturn
    case syntheticRunnerFailure
    case unexpectedPartition(String)
}

private enum LiveRunnerOutcome: Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

private actor LiveRunnerCompletionProbe {
    private(set) var outcome: LiveRunnerOutcome?

    func record(_ outcome: LiveRunnerOutcome) {
        self.outcome = outcome
    }
}

private enum SyntheticRunnerOutcome: String, Sendable {
    case success
    case failure
}

private actor DeletionRaceRunnerGate {
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
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

private final class LiveQuiescenceRuntimeStub: RuntimeClientProtocol, @unchecked Sendable {
    private let state = LiveQuiescenceRuntimeState()

    var generationStarted: Bool {
        get async { await state.generationStarted }
    }

    var cancellationRequested: Bool {
        get async { await state.cancellationRequested }
    }

    var cancellationResponseReturned: Bool {
        get async { await state.cancellationResponseReturned }
    }

    func confirmQuiescence() async {
        await state.confirmQuiescence()
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        await state.recordLoadedModel(request.modelID)
        return LoadModelResponse(
            status: .loaded,
            modelID: request.modelID,
            verifiedModelSHA256: request.contentBinding?.fingerprintSHA256
        )
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { [state] continuation in
            Task {
                await state.installGeneration(request, continuation: continuation)
            }
        }
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        await state.beginCancellation(generationID)
        await state.recordCancellationResponseReturned()
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        await state.recordLoadedModel(nil)
        return UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: await state.loadedModelID)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        let snapshot = await state.statusSnapshot()
        return RuntimeStatus(
            state: snapshot.generationID == nil ? .modelLoaded : .generating,
            loadedModelID: snapshot.modelID,
            activeGenerationID: snapshot.generationID,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}

private actor LiveQuiescenceRuntimeState {
    private(set) var loadedModelID: ModelID?
    private(set) var generationStarted = false
    private(set) var cancellationRequested = false
    private(set) var cancellationResponseReturned = false
    private var activeGenerationID: GenerationID?
    private var generationContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private var quiescenceConfirmed = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    func recordLoadedModel(_ modelID: ModelID?) {
        loadedModelID = modelID
    }

    func installGeneration(
        _ request: GenerateRequest,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        activeGenerationID = request.generationID
        generationContinuation = continuation
        generationStarted = true
        continuation.yield(GenerationEvent(
            generationID: request.generationID,
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            type: .generationStarted
        ))
    }

    func beginCancellation(_ generationID: GenerationID) async {
        cancellationRequested = true
        if activeGenerationID == generationID {
            // Simulate the local stream ending as soon as its consuming Swift
            // task is cancelled. The independent cancellation reply remains
            // blocked until the test confirms model-actor quiescence.
            generationContinuation?.finish()
            generationContinuation = nil
        }
        guard !quiescenceConfirmed else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    func confirmQuiescence() {
        quiescenceConfirmed = true
        activeGenerationID = nil
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func recordCancellationResponseReturned() {
        cancellationResponseReturned = true
    }

    func statusSnapshot() -> (modelID: ModelID?, generationID: GenerationID?) {
        (loadedModelID, activeGenerationID)
    }
}

private struct SilentExecutionNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
