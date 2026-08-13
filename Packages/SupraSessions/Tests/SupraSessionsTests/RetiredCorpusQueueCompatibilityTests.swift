import Foundation
import GRDB
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class RetiredCorpusQueueCompatibilityTests: XCTestCase {
    func testRetiredAdmissionIsTypedAndWritesNoQueueRow() throws {
        // T-REVIEW-RETIRE-JOB-01 expected RED: corpus submission has no typed
        // retired-capability admission result and still accepts guided-review work.
        let store = try makeStore(testName: "admission")
        let matter = try store.matters.createMatter(name: "Synthetic retired admission 713")
        let queue = makeQueue(store: store, recorder: CorpusRunKeyRecorder())
        let retiredPayload = makePayload(
            matterID: matter.id,
            runKey: "guided-review:fictional-admission-713"
        )

        XCTAssertThrowsError(
            try queue.submitCorpusAnalysis(
                matterID: matter.id,
                payload: retiredPayload,
                startImmediately: false
            )
        ) { error in
            XCTAssertEqual(error as? CorpusAnalysisQueueAdmissionError, .retiredCapability)
        }
        XCTAssertTrue(try store.documentJobs.fetchJobs(matterID: matter.id).isEmpty)

        let genericID = try queue.submitCorpusAnalysis(
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "retained-exhaustive:fictional-admission-719"
            ),
            startImmediately: false
        )
        let generic = try XCTUnwrap(store.documentJobs.fetchJob(id: genericID))
        XCTAssertEqual(generic.status, DocumentProcessingJobStatus.queued.rawValue)
        XCTAssertFalse(generic.payloadJSON?.contains("guided-review:") == true)
    }

    func testBootstrapLeavesQueuedRetiredJobByteIdenticalAndRunsGenericFollower() async throws {
        // T-REVIEW-RETIRE-JOB-01 expected RED: bootstrap activates the first
        // queued corpus job without excluding the retired guided-review identity.
        let store = try makeStore(testName: "queued-follower")
        let matter = try store.matters.createMatter(name: "Synthetic queued retirement 727")
        let retired = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:fictional-queued-727"
            )
        )
        let generic = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "retained-chronology:fictional-follower-733"
            )
        )
        let retiredBefore = try canonicalJob(
            try XCTUnwrap(store.documentJobs.fetchJob(id: retired.id))
        )
        let recorder = CorpusRunKeyRecorder()
        let queue = makeQueue(store: store, recorder: recorder)

        queue.bootstrap()
        await queue.waitUntilIdle()

        let retiredAfter = try XCTUnwrap(store.documentJobs.fetchJob(id: retired.id))
        let genericAfter = try XCTUnwrap(store.documentJobs.fetchJob(id: generic.id))
        XCTAssertEqual(try canonicalJob(retiredAfter), retiredBefore)
        let recordedRunKeys = await recorder.snapshot()
        XCTAssertEqual(recordedRunKeys, ["retained-chronology:fictional-follower-733"])
        XCTAssertEqual(genericAfter.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(genericAfter.phase, DocumentProcessingPhase.complete.rawValue)
        XCTAssertFalse(queue.hasPendingCorpusAnalysisWork)
    }

    func testPausedRetiredResumeIsRejectedWithoutMutationOrRunnerCall() async throws {
        // T-REVIEW-RETIRE-JOB-01 expected RED: resume blindly requeues every
        // paused corpus job, including a retired guided-review request.
        let store = try makeStore(testName: "paused-resume")
        let matter = try store.matters.createMatter(name: "Synthetic paused retirement 739")
        let job = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:fictional-paused-739"
            )
        )
        try store.documentJobs.pauseJob(id: job.id)
        let pausedBefore = try canonicalJob(try XCTUnwrap(store.documentJobs.fetchJob(id: job.id)))
        let recorder = CorpusRunKeyRecorder()
        let queue = makeQueue(store: store, recorder: recorder)

        XCTAssertEqual(queue.resumeCorpusAnalysis(jobID: job.id), .retiredCapability)
        await queue.waitUntilIdle()

        let pausedAfter = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        XCTAssertEqual(try canonicalJob(pausedAfter), pausedBefore)
        let recordedRunKeys = await recorder.snapshot()
        XCTAssertEqual(recordedRunKeys, [])
        XCTAssertEqual(pausedAfter.status, DocumentProcessingJobStatus.paused.rawValue)
    }

    func testHistoricalGuidedReviewJobIDIsRetiredEvenWhenPayloadRunKeyIsGeneric() throws {
        // T-REVIEW-RETIRE-JOB-01 wire proof for an older compatibility shape:
        // retirement matches the exact job-ID prefix as well as the current v2 runKey.
        let store = try makeStore(testName: "historical-job-id")
        let matter = try store.matters.createMatter(name: "Synthetic historical retirement 741")
        let genericPayload = makePayload(
            matterID: matter.id,
            runKey: "retained-exhaustive:historical-payload-743"
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(genericPayload), as: UTF8.self)
        let historical = DocumentProcessingJobRecord(
            id: "guided-review:historical-job-747",
            matterID: matter.id,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payloadJSON
        )
        try store.database.writer.write { db in try historical.insert(db) }
        let before = try canonicalJob(
            try XCTUnwrap(store.documentJobs.fetchJob(id: historical.id))
        )
        let queue = makeQueue(store: store, recorder: CorpusRunKeyRecorder())

        queue.bootstrap()

        let after = try XCTUnwrap(store.documentJobs.fetchJob(id: historical.id))
        XCTAssertEqual(try canonicalJob(after), before)
        XCTAssertFalse(queue.hasPendingCorpusAnalysisWork)
    }

    func testInterruptedRetiredActiveJobBecomesQuiescentWithoutExecution() async throws {
        // T-REVIEW-RETIRE-JOB-01 standing guard: existing relaunch reconciliation
        // must keep an interrupted retired active row quiescent while admission is removed.
        let store = try makeStore(testName: "interrupted-active")
        let matter = try store.matters.createMatter(name: "Synthetic active retirement 743")
        let queued = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:fictional-active-743"
            )
        )
        let active = try XCTUnwrap(store.documentJobs.activateNextJobIfIdle())
        XCTAssertEqual(active.id, queued.id)
        let activeBefore = try XCTUnwrap(store.documentJobs.fetchJob(id: active.id))
        let recorder = CorpusRunKeyRecorder()
        let queue = makeQueue(store: store, recorder: recorder)

        queue.bootstrap()
        await queue.waitUntilIdle()

        let reconciled = try XCTUnwrap(store.documentJobs.fetchJob(id: active.id))
        let recordedRunKeys = await recorder.snapshot()
        XCTAssertEqual(recordedRunKeys, [])
        XCTAssertEqual(reconciled.status, DocumentProcessingJobStatus.paused.rawValue)
        XCTAssertEqual(reconciled.phase, DocumentProcessingPhase.paused.rawValue)
        XCTAssertEqual(reconciled.startedAt, activeBefore.startedAt)
        XCTAssertNil(reconciled.completedAt)
        XCTAssertNil(reconciled.errorSummary)
    }

    func testFailedAndCompletedRetiredRowsRemainByteIdenticalAcrossBootstrap() async throws {
        // T-REVIEW-RETIRE-JOB-01 standing guard: terminal legacy rows are already
        // inert, and retirement must not rewrite them merely to make absence scans pass.
        let store = try makeStore(testName: "terminal-rows")
        let matter = try store.matters.createMatter(name: "Synthetic terminal retirement 751")

        let failedQueued = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:fictional-failed-751"
            )
        )
        _ = try store.documentJobs.activateNextJobIfIdle()
        XCTAssertTrue(
            try store.documentJobs.failActiveJob(
                id: failedQueued.id,
                errorSummary: "synthetic-retired-failure-757"
            )
        )

        let completedQueued = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:fictional-complete-761"
            )
        )
        _ = try store.documentJobs.activateNextJobIfIdle()
        XCTAssertTrue(try store.documentJobs.completeActiveJob(id: completedQueued.id))

        let failedBefore = try canonicalJob(
            try XCTUnwrap(store.documentJobs.fetchJob(id: failedQueued.id))
        )
        let completedBefore = try canonicalJob(
            try XCTUnwrap(store.documentJobs.fetchJob(id: completedQueued.id))
        )
        let recorder = CorpusRunKeyRecorder()
        let queue = makeQueue(store: store, recorder: recorder)

        queue.bootstrap()
        await queue.waitUntilIdle()

        XCTAssertEqual(
            try canonicalJob(try XCTUnwrap(store.documentJobs.fetchJob(id: failedQueued.id))),
            failedBefore
        )
        XCTAssertEqual(
            try canonicalJob(try XCTUnwrap(store.documentJobs.fetchJob(id: completedQueued.id))),
            completedBefore
        )
        let recordedRunKeys = await recorder.snapshot()
        XCTAssertEqual(recordedRunKeys, [])
    }

    func testTReviewRetireArtifact01BootstrapPreservesExistingExportsAndSharedModelBytes() async throws {
        // T-REVIEW-RETIRE-ARTIFACT-01 standing guard: the only legacy-job
        // reconciliation performed during retirement cannot become an export/model cleanup.
        let artifactRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RetiredCorpusArtifacts-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let exportRoot = artifactRoot.appendingPathComponent("Existing Review Exports", isDirectory: true)
        let modelRoot = artifactRoot.appendingPathComponent(
            "Models/shared-model-719/revision-7",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)

        let csvURL = exportRoot.appendingPathComponent("review-export-713.csv")
        let xlsxURL = exportRoot.appendingPathComponent("review-export-719.xlsx")
        let modelURL = modelRoot.appendingPathComponent("model-727.safetensors")
        let expectedArtifacts: [(URL, Data)] = [
            (csvURL, Data("CSV-EXISTING-713\ncell,NONDEFAULT-719\n".utf8)),
            (xlsxURL, Data([0x50, 0x4b, 0x03, 0x04, 0x07, 0x13, 0x19, 0x27])),
            (modelURL, Data("SHARED-MODEL-BYTES-727-REVISION-7".utf8)),
        ]
        for (url, bytes) in expectedArtifacts {
            try bytes.write(to: url, options: .withoutOverwriting)
        }

        let store = try makeStore(testName: "artifact-preservation")
        let matter = try store.matters.createMatter(name: "Synthetic artifact retirement 733")
        let queued = try persistJob(
            store: store,
            matterID: matter.id,
            payload: makePayload(
                matterID: matter.id,
                runKey: "guided-review:artifact-preservation-739"
            )
        )
        let active = try XCTUnwrap(store.documentJobs.activateNextJobIfIdle())
        XCTAssertEqual(active.id, queued.id)
        let recorder = CorpusRunKeyRecorder()
        let queue = makeQueue(store: store, recorder: recorder)

        queue.bootstrap()
        await queue.waitUntilIdle()

        let reconciled = try XCTUnwrap(store.documentJobs.fetchJob(id: active.id))
        XCTAssertEqual(reconciled.status, DocumentProcessingJobStatus.paused.rawValue)
        let recordedRunKeys = await recorder.snapshot()
        XCTAssertEqual(recordedRunKeys, [])
        for (url, expectedBytes) in expectedArtifacts {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: url), expectedBytes)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifactRoot.appendingPathComponent("DEFAULT-000").path
            )
        )
    }

    private func makePayload(matterID: String, runKey: String) -> CorpusAnalysisJobPayload {
        CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: "run-\(runKey)",
            requestDigest: String(repeating: "d", count: 64),
            task: .exhaustiveList(
                ExhaustiveListQueuedRequest(
                    taskSchemaVersion: 731,
                    promptBuilderVersion: "retirement-fixture-v7",
                    runKey: runKey,
                    matterID: matterID,
                    title: "Synthetic retained corpus task 769",
                    query: "List synthetic evidence values 773.",
                    characterBudget: 7_319,
                    maximumRetryCount: 1
                )
            ),
            pinnedModel: CorpusAnalysisPinnedModel(
                modelRepository: "synthetic/model-779",
                modelRevision: String(repeating: "a", count: 40),
                contentBindingAlgorithm: "synthetic-binding-v7",
                contentBindingSchemaVersion: 7,
                artifactFingerprintSHA256: String(repeating: "b", count: 64)
            )
        )
    }

    private func persistJob(
        store: SupraStore,
        matterID: String,
        payload: CorpusAnalysisJobPayload
    ) throws -> DocumentProcessingJobRecord {
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return try store.documentJobs.enqueueJob(
            matterID: matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payloadJSON
        )
    }

    private func canonicalJob(_ job: DocumentProcessingJobRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(job)
    }

    private func makeStore(testName: String) throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RetiredCorpusQueue-\(testName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeQueue(
        store: SupraStore,
        recorder: CorpusRunKeyRecorder
    ) -> DocumentProcessingQueue {
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "RetiredCorpusQueueStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store) },
            notifier: RetirementSilentNotifier(),
            corpusAnalysisRunner: { payload in
                if case .exhaustiveList(let request) = payload.task {
                    await recorder.record(request.runKey)
                }
            }
        )
    }
}

private actor CorpusRunKeyRecorder {
    private(set) var runKeys: [String] = []

    func record(_ runKey: String) {
        runKeys.append(runKey)
    }

    func snapshot() -> [String] {
        runKeys
    }
}

private struct RetirementSilentNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
