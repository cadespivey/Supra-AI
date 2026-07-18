import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class CorpusAnalysisQueueTests: XCTestCase {
    func testM6W1CorpusAnalysisJobUsesNondefaultKindAndDurableRunPayload() async throws {
        // M6-W1 expected RED: the corpus_analysis job kind, payload, and queue route do not exist.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic queued corpus")
        let recorder = CorpusPayloadRecorder()
        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("CorpusQueueStorage-\(UUID().uuidString)", isDirectory: true))
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store) },
            notifier: SilentCorpusNotifier(),
            corpusAnalysisRunner: { payload in await recorder.record(payload) }
        )

        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: matter.id,
            runID: "nondefault-corpus-run"
        ))
        await queue.waitUntilIdle()

        let payloads = await recorder.payloads
        XCTAssertEqual(payloads, [CorpusAnalysisJobPayload(runID: "nondefault-corpus-run")])
        let job = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        XCTAssertEqual(job.kind, DocumentProcessingJobKind.corpusAnalysis.rawValue)
        XCTAssertNotEqual(job.kind, DocumentProcessingJobKind.process.rawValue)
        XCTAssertEqual(job.phase, DocumentProcessingPhase.complete.rawValue)
        XCTAssertEqual(job.status, DocumentProcessingJobStatus.complete.rawValue)
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorpusQueueStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}

private actor CorpusPayloadRecorder {
    private(set) var payloads: [CorpusAnalysisJobPayload] = []

    func record(_ payload: CorpusAnalysisJobPayload) {
        payloads.append(payload)
    }
}

private struct SilentCorpusNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
