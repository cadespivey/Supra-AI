import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Compile-contract REDs are isolated here so the queue's existing behavioral
/// failures can be observed independently from the missing v2 payload symbols.
@MainActor
final class CorpusReviewQueueContractTests: XCTestCase {
    func testTQUEUE01V2PayloadCodableRoundTripPreservesFrozenRequestAndPinnedModel() throws {
        // T-QUEUE-01 expected RED: CorpusAnalysisJobPayload persists only run_id;
        // the v2 schema, reconstructible task, request digest, and pinned model
        // identity do not exist.
        let payload = makePayload(runID: "run-nondefault-queue-01")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload)
        let decoded = try JSONDecoder().decode(CorpusAnalysisJobPayload.self, from: encoded)
        let request = try queuedRequest(from: decoded)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.runID, "run-nondefault-queue-01")
        XCTAssertEqual(decoded.requestDigest, Self.requestDigest)
        XCTAssertEqual(decoded.pinnedModel, Self.pinnedModel)
        XCTAssertEqual(request.runKey, "run-key-nondefault-queue")
        XCTAssertEqual(request.matterID, "matter-nondefault-queue")
        XCTAssertEqual(request.title, "Synthetic privilege review matrix")
        XCTAssertEqual(request.query, "List every nondefault privilege indicator and its exact source.")
        XCTAssertEqual(request.scope.schemaVersion, 7)
        XCTAssertEqual(request.scope.documentIDs, ["document-zeta", "document-alpha"])
        XCTAssertEqual(request.characterBudget, 31_337)
        XCTAssertEqual(request.maximumRetryCount, 4)
        XCTAssertTrue(json.contains("\"schema_version\":2"))
        XCTAssertTrue(json.contains("\"character_budget\":31337"))
        XCTAssertFalse(
            json.contains("\"character_budget\":24000"),
            "the exact task must contain the non-default budget, not the old default"
        )
        XCTAssertFalse(
            json.contains("evaluation_expected_item_keys"),
            "evaluation-only answer keys must not enter a production queue payload"
        )
    }

    func testTQUEUE03MissingAndWrongPinnedModelsFailClosedWithoutFallback() async throws {
        // T-QUEUE-03 expected RED: the payload carries no pinned model and
        // CorpusAnalysisQueueError.pinnedModelUnavailable does not exist, so a
        // runner cannot preserve the exact artifact failure across the FIFO.
        let store = try makeStore(testName: "TQUEUE03")
        let matter = try store.matters.createMatter(name: "Synthetic pinned-model failures")
        let missingPayload = makePayload(runID: "run-model-missing", matterID: matter.id)
        let wrongPayload = makePayload(runID: "run-model-wrong", matterID: matter.id)
        let probe = PinnedModelProbe(availableByRunID: [
            wrongPayload.runID: DocumentGenerationModelLineage(
                modelRepository: "synthetic/alternate-model-must-not-run",
                modelRevision: "alternate-revision-must-not-run"
            )
        ])
        let queue = makeQueue(store: store) { payload in
            try await probe.run(payload)
        }

        let missingJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: matter.id,
            payload: missingPayload
        ))
        let wrongJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: matter.id,
            payload: wrongPayload
        ))
        await queue.waitUntilIdle()

        let attempted = await probe.attemptedPayloads
        let generationCalls = await probe.generationCalls
        let expectedError = CorpusAnalysisQueueError.pinnedModelUnavailable(
            repository: Self.pinnedModel.modelRepository,
            revision: Self.pinnedModel.modelRevision
        ).localizedDescription
        let missingJob = try XCTUnwrap(store.documentJobs.fetchJob(id: missingJobID))
        let wrongJob = try XCTUnwrap(store.documentJobs.fetchJob(id: wrongJobID))

        XCTAssertEqual(attempted, [missingPayload, wrongPayload])
        XCTAssertEqual(attempted.count, 2, "each job receives one pinned-artifact check")
        XCTAssertEqual(generationCalls, 0, "missing and wrong artifacts must not generate")
        XCTAssertTrue(expectedError.contains(Self.pinnedModel.modelRepository))
        XCTAssertTrue(expectedError.contains(Self.pinnedModel.modelRevision))
        XCTAssertEqual(missingJob.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertEqual(wrongJob.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertEqual(missingJob.errorSummary, expectedError)
        XCTAssertEqual(wrongJob.errorSummary, expectedError)
        XCTAssertFalse(wrongJob.errorSummary?.contains("alternate-model-must-not-run") == true)
    }

    func testTQUEUE04ApprovedActiveCancellationEntryPointCancelsPersistedJob() throws {
        // T-QUEUE-04 expected RED: cancel(jobID:) is absent; only the queued-row
        // helper exists, with no approved entry point for active corpus work.
        let store = try makeStore(testName: "TQUEUE04API")
        let matter = try store.matters.createMatter(name: "Synthetic cancellation API")
        let job = try store.documentJobs.enqueueJob(
            matterID: matter.id,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: #"{"run_id":"run-cancel-api-nondefault"}"#
        )
        let queue = makeQueue(store: store) { _ in }

        queue.cancel(jobID: job.id)

        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        XCTAssertEqual(persisted.status, DocumentProcessingJobStatus.cancelled.rawValue)
        XCTAssertEqual(persisted.phase, DocumentProcessingPhase.cancelled.rawValue)
    }

    private static let requestDigest = String(repeating: "9", count: 64)
    private static let pinnedModel = DocumentGenerationModelLineage(
        modelRepository: "synthetic/legal-review-model-nondefault",
        modelRevision: "revision-9f4a-nondefault"
    )

    private func makePayload(
        runID: String,
        matterID: String = "matter-nondefault-queue"
    ) -> CorpusAnalysisJobPayload {
        CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: runID,
            requestDigest: Self.requestDigest,
            task: .exhaustiveList(ExhaustiveListQueuedRequest(
                runKey: "run-key-nondefault-queue",
                matterID: matterID,
                title: "Synthetic privilege review matrix",
                query: "List every nondefault privilege indicator and its exact source.",
                scope: CorpusAnalysisScope(
                    schemaVersion: 7,
                    documentIDs: ["document-zeta", "document-alpha"]
                ),
                characterBudget: 31_337,
                maximumRetryCount: 4
            )),
            pinnedModel: Self.pinnedModel
        )
    }

    private func queuedRequest(
        from payload: CorpusAnalysisJobPayload
    ) throws -> ExhaustiveListQueuedRequest {
        if case .exhaustiveList(let request) = payload.task { return request }
        throw QueueContractTestError.unexpectedTask
    }

    private func makeStore(testName: String) throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusReviewQueueContract-\(testName)-\(UUID().uuidString)",
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
                "CorpusReviewQueueContractStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store) },
            notifier: SilentContractNotifier(),
            corpusAnalysisRunner: runner
        )
    }
}

private enum QueueContractTestError: Error {
    case unexpectedTask
}

private actor PinnedModelProbe {
    private let availableByRunID: [String: DocumentGenerationModelLineage]
    private(set) var attemptedPayloads: [CorpusAnalysisJobPayload] = []
    private(set) var generationCalls = 0

    init(availableByRunID: [String: DocumentGenerationModelLineage]) {
        self.availableByRunID = availableByRunID
    }

    func run(_ payload: CorpusAnalysisJobPayload) throws {
        attemptedPayloads.append(payload)
        guard availableByRunID[payload.runID] == payload.pinnedModel else {
            throw CorpusAnalysisQueueError.pinnedModelUnavailable(
                repository: payload.pinnedModel.modelRepository,
                revision: payload.pinnedModel.modelRevision
            )
        }
        generationCalls += 1
    }
}

private struct SilentContractNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
