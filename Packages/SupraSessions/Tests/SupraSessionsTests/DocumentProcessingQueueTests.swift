import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentProcessingQueueTests: XCTestCase {
    private var sourceRoot = URL(fileURLWithPath: "/tmp")
    private var storageRoot = URL(fileURLWithPath: "/tmp")

    private func prepareSources() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QueueTests-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = base.appendingPathComponent("src", isDirectory: true)
        storageRoot = base.appendingPathComponent("store", isDirectory: true)
        try write("A/agreement.txt", "Service agreement with an indemnification clause.")
        try write("B/intake.txt", "Intake notes about the wire transfer.")
    }

    func testQueueRunsJobsFIFOSingleActiveAndNotifiesCompletion() async throws {
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let notifier = RecordingNotifier()
        let queue = makeQueue(store: store, notifier: notifier)

        let job1 = try XCTUnwrap(queue.enqueueImport(matterID: matter.id, sources: [sourceRoot.appendingPathComponent("A")]))
        let job2 = try XCTUnwrap(queue.enqueueImport(matterID: matter.id, sources: [sourceRoot.appendingPathComponent("B")]))

        await queue.waitUntilIdle()

        XCTAssertEqual(try store.documentJobs.fetchJob(id: job1)?.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job2)?.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertNil(try store.documentJobs.fetchActiveJob())
        XCTAssertTrue(try store.documentJobs.fetchQueuedJobs().isEmpty)

        // Documents from both jobs imported and indexed.
        let docs = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        XCTAssertEqual(docs.count, 2)
        XCTAssertTrue(docs.allSatisfy { $0.status == MatterDocumentStatus.ready.rawValue })
        for doc in docs {
            XCTAssertFalse(try store.documentIndex.fetchChunks(documentID: doc.id).isEmpty)
        }

        // A completion notification fired per job.
        XCTAssertGreaterThanOrEqual(notifier.messages.count, 2)
    }

    func testInterruptedActiveJobBecomesResumableOnBootstrap() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")

        // Simulate a job that was active when the app quit.
        let job = try store.documentJobs.enqueueJob(matterID: matter.id)
        _ = try store.documentJobs.activateNextJobIfIdle()
        XCTAssertEqual(try store.documentJobs.fetchActiveJob()?.id, job.id)

        let queue = makeQueue(store: store, notifier: RecordingNotifier())
        queue.bootstrap()

        XCTAssertNil(try store.documentJobs.fetchActiveJob())
        XCTAssertEqual(queue.resumableJobs.map(\.id), [job.id])
    }

    func testCancelQueuedJob() async throws {
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let queue = makeQueue(store: store, notifier: RecordingNotifier())

        // Enqueue two; cancel the second before it runs by cancelling immediately.
        let job1 = try XCTUnwrap(queue.enqueueImport(matterID: matter.id, sources: [sourceRoot.appendingPathComponent("A")]))
        let job2 = try XCTUnwrap(queue.enqueueImport(matterID: matter.id, sources: [sourceRoot.appendingPathComponent("B")]))
        queue.cancelQueuedJob(id: job2)
        await queue.waitUntilIdle()

        XCTAssertEqual(try store.documentJobs.fetchJob(id: job1)?.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job2)?.status, DocumentProcessingJobStatus.cancelled.rawValue)
    }

    // MARK: - Helpers

    private func makeQueue(store: SupraStore, notifier: RecordingNotifier) -> DocumentProcessingQueue {
        let storage = DocumentStorage(root: storageRoot)
        let importService = DocumentImportService(store: store, storage: storage, ocr: nil)
        return DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: notifier
        )
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = sourceRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private final class RecordingNotifier: DocumentNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    var messages: [String] { lock.withLock { _messages } }

    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {
        lock.withLock { _messages.append("\(title): \(body)") }
    }
}
