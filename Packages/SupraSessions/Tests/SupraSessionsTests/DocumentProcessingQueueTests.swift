import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeInterface
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

    // MARK: - Classification jobs (re-trigger / retry)

    func testEnqueueClassifyNoOpsWhenNothingPending() async throws {
        // Expected RED: compile error — `enqueueClassify` is not a member of DocumentProcessingQueue.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        // Import one document, then mark it classified so nothing is eligible for classification.
        _ = try await importService.importSources([sourceRoot.appendingPathComponent("A")], matterID: matter.id)
        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        try store.documentLibrary.updateClassification(documentID: doc.id, classificationMetadataJSON: #"{"primary_tag":"contracts_and_agreements"}"#)

        let queue = makeQueue(store: store, notifier: RecordingNotifier(), classificationService: try makeClassificationService(store: store))

        XCTAssertNil(queue.enqueueClassify(matterID: matter.id), "no eligible document → no classify job")
        XCTAssertTrue(try store.documentJobs.fetchJobs(matterID: matter.id).isEmpty, "enqueueClassify must not create a job when nothing is pending")
    }

    func testEnqueueClassifyDedupesAgainstQueuedJob() async throws {
        // Expected RED: compile error — `enqueueClassify` is not a member of DocumentProcessingQueue.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        // An eligible (extracted, unclassified) document so the ONLY reason to no-op is dedup.
        _ = try await importService.importSources([sourceRoot.appendingPathComponent("A")], matterID: matter.id)
        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertNil(doc.classificationMetadataJSON, "precondition: the document still needs classification")

        // A job already queued for the matter (enqueued straight to the store, unpumped).
        _ = try store.documentJobs.enqueueJob(matterID: matter.id)

        let queue = makeQueue(store: store, notifier: RecordingNotifier(), classificationService: try makeClassificationService(store: store))

        XCTAssertNil(queue.enqueueClassify(matterID: matter.id), "an existing queued job must suppress a duplicate classify job")
        XCTAssertEqual(try store.documentJobs.fetchJobs(matterID: matter.id).count, 1, "no second job row should be created")
    }

    func testClassifyJobClassifiesPendingDocsWithoutNotification() async throws {
        // Expected RED: compile error — `enqueueClassify` is not a member of DocumentProcessingQueue.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        // Two extracted-but-unclassified documents, each well over the 40-char classification floor.
        try write("C/master-agreement.txt", "Master services agreement with indemnification and limitation-of-liability provisions.")
        try write("C/strategy-memo.txt", "Litigation strategy memorandum analyzing damages exposure and the settlement posture.")
        _ = try await importService.importSources([sourceRoot.appendingPathComponent("C")], matterID: matter.id)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).count, 2)

        // A classifier scripted to return a valid taxonomy JSON (a NON-default tag) for every generation.
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: #"{"primary_tag":"contracts_and_agreements","confidence":0.91}"#),
                .event(request, 3, .generationCompleted, metrics: RuntimeMetrics(generatedTokenCount: 12))
            ])
        }
        let notifier = RecordingNotifier()
        let queue = makeQueue(store: store, notifier: notifier, classificationService: try makeClassificationService(store: store, stub: stub))

        let jobID = try XCTUnwrap(queue.enqueueClassify(matterID: matter.id))
        await queue.waitUntilIdle()

        // Every pending document is now classified with the scripted (non-default) tag.
        for doc in try store.documentLibrary.fetchDocuments(matterID: matter.id) {
            let json = try XCTUnwrap(doc.classificationMetadataJSON, "\(doc.displayName) should be classified by the classify job")
            let decoded = try JSONDecoder().decode(DocumentClassification.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.primaryCategory, .contractsAndAgreements, "stored tag must reflect the model output, not a default")
        }
        // The classify job completes, but a classify job runs ONLY the classify phase and must
        // NOT fire a completion/failure notification (observed via the notifier spy).
        XCTAssertEqual(try store.documentJobs.fetchJob(id: jobID)?.status, DocumentProcessingJobStatus.complete.rawValue)
        XCTAssertTrue(notifier.messages.isEmpty, "a classify job must not invoke the completion notifier")
    }

    // MARK: - Reprocess jobs (re-extract from the managed blob)

    func testReprocessJobPersistsTargetsAndSurvivesRelaunch() async throws {
        // Expected RED: compile error — `DocumentProcessingJobKind` and the
        // `enqueueJob(matterID:kind:payloadJSON:)` overload / `payload_json` column do not exist yet.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        _ = try await importService.importSources(
            [sourceRoot.appendingPathComponent("A"), sourceRoot.appendingPathComponent("B")],
            matterID: matter.id
        )
        var docs = try store.documentLibrary.fetchDocuments(matterID: matter.id).sorted { $0.displayName < $1.displayName }
        XCTAssertEqual(docs.count, 2)
        // Force both to .failed; their managed blobs remain valid and re-extractable.
        for doc in docs {
            try store.documentLibrary.updateExtraction(
                documentID: doc.id, status: .failed, extractionStatus: .failed,
                method: "failed", checksum: nil, pagePartCount: 0
            )
        }

        // A reprocess job whose targets live in payload_json, enqueued straight to the store as
        // it would exist just before a crash, then marked active (mid-flight when the app quit).
        let ids = docs.map(\.id)
        let payload = "{\"documentIDs\":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"
        let job = try store.documentJobs.enqueueJob(
            matterID: matter.id,
            kind: DocumentProcessingJobKind.reprocess.rawValue,
            payloadJSON: payload
        )
        _ = try store.documentJobs.activateNextJobIfIdle()
        XCTAssertEqual(try store.documentJobs.fetchActiveJob()?.id, job.id)

        // Relaunch: a brand-new queue over the same store, holding no in-memory job state.
        let relaunched = makeQueue(store: store, notifier: RecordingNotifier())
        relaunched.bootstrap()   // interrupted active job → paused
        XCTAssertEqual(relaunched.resumableJobs.map(\.id), [job.id])
        relaunched.resume(jobID: job.id)
        await relaunched.waitUntilIdle()

        // The persisted payload ALONE drove reprocessing: both docs re-extracted from their blobs.
        docs = try store.documentLibrary.fetchDocuments(matterID: matter.id).sorted { $0.displayName < $1.displayName }
        XCTAssertEqual(docs.count, 2)
        for doc in docs {
            XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.extracted.rawValue, "\(doc.displayName) should re-extract from its blob after relaunch")
        }
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job.id)?.status, DocumentProcessingJobStatus.complete.rawValue)
    }

    func testEnqueueReprocessWritesTargetsToPayloadAndReextracts() async throws {
        // Expected RED: compile error — `enqueueReprocess` is not a member of DocumentProcessingQueue,
        // and `DocumentProcessingJobRecord` has no `kind` / `payloadJSON`.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        _ = try await importService.importSources(
            [sourceRoot.appendingPathComponent("A"), sourceRoot.appendingPathComponent("B")],
            matterID: matter.id
        )
        var docs = try store.documentLibrary.fetchDocuments(matterID: matter.id).sorted { $0.displayName < $1.displayName }
        XCTAssertEqual(docs.count, 2)
        for doc in docs {
            try store.documentLibrary.updateExtraction(
                documentID: doc.id, status: .failed, extractionStatus: .failed,
                method: "failed", checksum: nil, pagePartCount: 0
            )
        }
        let ids = docs.map(\.id)

        let queue = makeQueue(store: store, notifier: RecordingNotifier())
        let jobID = try XCTUnwrap(queue.enqueueReprocess(matterID: matter.id, documentIDs: ids))

        // The targets are persisted in payload_json before the job runs (read synchronously,
        // before the pump has a chance to run).
        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        XCTAssertEqual(persisted.kind, DocumentProcessingJobKind.reprocess.rawValue)
        let persistedPayload = try XCTUnwrap(persisted.payloadJSON)
        for id in ids { XCTAssertTrue(persistedPayload.contains(id), "payload should carry target \(id)") }

        await queue.waitUntilIdle()

        // Both targets re-extracted from their (valid) blobs.
        docs = try store.documentLibrary.fetchDocuments(matterID: matter.id).sorted { $0.displayName < $1.displayName }
        for doc in docs {
            XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.extracted.rawValue, "\(doc.displayName) should be re-extracted")
        }
        XCTAssertEqual(try store.documentJobs.fetchJob(id: jobID)?.status, DocumentProcessingJobStatus.complete.rawValue)
    }

    // MARK: - Classifier minimum-text guard (standing guard)

    func testClassifyDocumentSkipsUnderMinimumTextLength() async throws {
        // Standing guard (per §2): classifyDocument already refuses documents with < 40 chars of
        // extractable text, leaving them unclassified for a later OCR/edit pass. This pins that
        // floor so a regression can't start classifying near-empty documents. Green from day one.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let importService = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        try write("Short/tiny.txt", "Too short.")   // 10 chars < the 40-char classification floor
        _ = try await importService.importSources([sourceRoot.appendingPathComponent("Short/tiny.txt")], matterID: matter.id)
        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.extracted.rawValue, "precondition: extracted, only too short to classify")

        let service = try makeClassificationService(store: store)
        let classified = await service.classifyDocument(doc, modelID: ModelID())

        XCTAssertFalse(classified, "a sub-40-char document must be skipped, not classified")
        XCTAssertNil(try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id)).classificationMetadataJSON, "skipped document stays unclassified")
        let skips = try store.auditEvents.fetchEvents(relatedTable: "matter_documents", relatedID: doc.id, eventType: "document_classification_skipped")
        XCTAssertFalse(skips.isEmpty, "the skip must be recorded as an audit event")
    }

    // MARK: - Helpers

    private func makeQueue(
        store: SupraStore,
        notifier: RecordingNotifier,
        classificationService: DocumentClassificationService? = nil
    ) -> DocumentProcessingQueue {
        let storage = DocumentStorage(root: storageRoot)
        let importService = DocumentImportService(store: store, storage: storage, ocr: nil)
        return DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            classificationService: classificationService,
            notifier: notifier
        )
    }

    /// A classifier backed by an in-store `ModelLibrary` + `StubRuntimeClient`. A single
    /// registered non-managed (`/tmp`) model resolves for every role and "loads" through the
    /// stub, so the classifier runs end-to-end in tests; pass a scripted stub to drive real
    /// model output (otherwise the default stub is never reached — the min-text guard fires first).
    private func makeClassificationService(
        store: SupraStore,
        stub: StubRuntimeClient = StubRuntimeClient()
    ) throws -> DocumentClassificationService {
        let library = ModelLibrary(store: store, runtimeClient: stub)
        _ = try library.addModel(displayName: "Local Task Model", path: "/tmp/task-model", bookmarkData: nil)
        library.refresh()
        return DocumentClassificationService(store: store, modelLibrary: library, runtimeClient: stub, role: .drafting)
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
