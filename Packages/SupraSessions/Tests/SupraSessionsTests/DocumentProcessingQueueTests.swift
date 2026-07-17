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

    func testTACC05BootstrapFinalizesOrphanedBatchWithLedgerBackedReportIdempotently() throws {
        // T-ACC-05 expected RED: bootstrap leaves the batch processing and has no ledger-backed report.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic interrupted import")
        let batch = try store.documentJobs.createBatch(matterID: matter.id)

        let admitted = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "Imported.txt"
        )
        _ = try store.documentJobs.markState(sourceID: admitted.id, state: .admitted)

        let rejected = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:1",
            sourceDisplayPath: "Rejected.lnk"
        )
        _ = try store.documentJobs.markState(
            sourceID: rejected.id,
            state: .rejected,
            rejectionCode: "synthetic_policy_rejection",
            reason: "Synthetic policy rejection"
        )

        let bookmark = Data("synthetic-resume-bookmark".utf8)
        let selected = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:2",
            sourceDisplayPath: "Never Started.txt",
            sourceBookmark: bookmark,
            state: .selected
        )
        let copying = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:3",
            sourceDisplayPath: "Copy Interrupted.txt",
            sourceBookmark: bookmark,
            state: .selected
        )
        _ = try store.documentJobs.markState(sourceID: copying.id, state: .copying)
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 4, importedCount: 1, failedCount: 1)

        let queue = makeQueue(store: store, notifier: RecordingNotifier())
        queue.bootstrap()

        let reconciled = try XCTUnwrap(store.documentJobs.fetchBatch(id: batch.id))
        XCTAssertEqual(reconciled.status, "interrupted")
        XCTAssertNotNil(reconciled.completedAt)
        XCTAssertEqual(reconciled.discoveredCount, 4)
        XCTAssertEqual(reconciled.importedCount, 1)
        XCTAssertEqual(reconciled.failedCount, 3)

        let rows = try store.documentJobs.fetchSources(batchID: batch.id)
        let selectedAfter = try XCTUnwrap(rows.first { $0.id == selected.id })
        let copyingAfter = try XCTUnwrap(rows.first { $0.id == copying.id })
        XCTAssertEqual(selectedAfter.state, DocumentImportSourceState.interrupted.rawValue)
        XCTAssertEqual(copyingAfter.state, DocumentImportSourceState.interrupted.rawValue)
        XCTAssertEqual(selectedAfter.reason, "Import interrupted before completion.")
        XCTAssertEqual(copyingAfter.reason, "Import interrupted before completion.")
        XCTAssertEqual(selectedAfter.sourceBookmark, bookmark, "resumable authorization must survive reconciliation")
        XCTAssertEqual(copyingAfter.sourceBookmark, bookmark, "interrupted is re-entrant, not terminal")
        XCTAssertEqual(try store.documentJobs.unfinishedSources(batchID: batch.id).map(\.id).sorted(), [copying.id, selected.id].sorted())

        let reportData = try XCTUnwrap(reconciled.reportJSON?.data(using: .utf8))
        let report = try JSONDecoder().decode(DocumentImportReport.self, from: reportData)
        XCTAssertEqual(
            Set(report.items.map(\.sourceDisplayPath)),
            Set(["Imported.txt", "Rejected.lnk", "Never Started.txt", "Copy Interrupted.txt"])
        )
        let rejectedItem = try XCTUnwrap(report.items.first { $0.sourceDisplayPath == "Rejected.lnk" })
        XCTAssertEqual(rejectedItem.disposition, DocumentImportSourceState.rejected.rawValue)
        XCTAssertEqual(rejectedItem.rejectionCode, "synthetic_policy_rejection")
        XCTAssertEqual(rejectedItem.reason, "Synthetic policy rejection")
        XCTAssertEqual(report.items.filter { $0.disposition == DocumentImportSourceState.interrupted.rawValue }.count, 2)

        let firstReport = reconciled.reportJSON
        let firstCompletedAt = reconciled.completedAt
        queue.bootstrap()
        let repeated = try XCTUnwrap(store.documentJobs.fetchBatch(id: batch.id))
        XCTAssertEqual(repeated.reportJSON, firstReport)
        XCTAssertEqual(repeated.completedAt, firstCompletedAt)
    }

    func testTOPS01ImportFailureSummarySurvivesTwoQueueRecreationsWithExactReasons() throws {
        // T-OPS-01 expected RED: lastImportFailure is process memory and bootstrap does not reconstruct it.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic durable failure summary")
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let rejected = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "Rejected.msg"
        )
        _ = try store.documentJobs.markState(
            sourceID: rejected.id,
            state: .rejected,
            rejectionCode: "synthetic_rejection",
            reason: "Synthetic rejected source"
        )
        _ = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:1",
            sourceDisplayPath: "Interrupted.txt",
            sourceBookmark: Data("synthetic-durable-bookmark".utf8),
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 2, importedCount: 0, failedCount: 1)

        let firstQueue = makeQueue(store: store, notifier: RecordingNotifier())
        firstQueue.bootstrap()
        let first = try XCTUnwrap(firstQueue.lastImportFailure)
        XCTAssertEqual(first.matterID, matter.id)
        XCTAssertEqual(first.discoveredCount, 2)
        XCTAssertEqual(first.importedCount, 0)
        XCTAssertEqual(first.failedCount, 2)
        let firstReasons = Mirror(reflecting: first).children.first { $0.label == "reasons" }?.value as? [String]
        XCTAssertEqual(firstReasons, ["Import interrupted before completion.", "Synthetic rejected source"])

        let secondQueue = makeQueue(store: store, notifier: RecordingNotifier())
        secondQueue.bootstrap()
        let second = try XCTUnwrap(secondQueue.lastImportFailure)
        XCTAssertEqual(second, first)
        let secondReasons = Mirror(reflecting: second).children.first { $0.label == "reasons" }?.value as? [String]
        XCTAssertEqual(secondReasons, firstReasons)
    }

    func testTACC06RelaunchResumeImportsNeverAdmittedSourceWithoutRepeatingSucceededRows() async throws {
        // T-ACC-06 expected RED: resume with empty pendingSources only reindexes existing documents.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic resumable import")
        let importer = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: storageRoot),
            ocr: nil
        )
        let prior = try await importer.importSources(
            [sourceRoot.appendingPathComponent("A/agreement.txt")],
            matterID: matter.id
        )
        XCTAssertEqual(prior.report.importedCount, 1)
        let existingDocument = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)

        let resumeURL = sourceRoot.appendingPathComponent("B/intake.txt")
        let bookmark = try resumeURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let succeeded = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "agreement.txt"
        )
        _ = try store.documentJobs.markState(
            sourceID: succeeded.id,
            state: .admitted,
            documentID: existingDocument.id,
            blobSHA256: existingDocument.blobID
        )
        let pending = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:1",
            sourceDisplayPath: "intake.txt",
            sourceBookmark: bookmark,
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 2, importedCount: 1, failedCount: 0)
        let job = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: batch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()

        let interruptedQueue = makeQueue(store: store, notifier: RecordingNotifier())
        interruptedQueue.bootstrap()
        XCTAssertEqual(interruptedQueue.resumableJobs.map(\.id), [job.id])

        // A second queue proves no in-memory pending URL survives into resume.
        let relaunched = makeQueue(store: store, notifier: RecordingNotifier())
        relaunched.bootstrap()
        relaunched.resume(jobID: job.id)
        await relaunched.waitUntilIdle()

        let documents = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents.filter { $0.id == existingDocument.id }.count, 1, "succeeded source must not repeat")
        XCTAssertEqual(documents.filter { $0.displayName == "intake.txt" }.count, 1)
        let pendingAfter = try XCTUnwrap(try store.documentJobs.fetchSources(batchID: batch.id).first { $0.id == pending.id })
        XCTAssertEqual(pendingAfter.state, DocumentImportSourceState.admitted.rawValue)
        XCTAssertNil(pendingAfter.sourceBookmark)
        let finalBatch = try XCTUnwrap(store.documentJobs.fetchBatch(id: batch.id))
        XCTAssertEqual(finalBatch.status, DocumentImportBatchStatus.complete.rawValue)
        XCTAssertNotNil(finalBatch.reportJSON)
        let summary = try store.documentJobs.sourcesSummary(batchID: batch.id)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.terminalCount, 2)
        XCTAssertEqual(summary.unfinishedCount, 0)
        XCTAssertEqual(summary.balanceErrorCount, 0)
    }

    func testTACC07UnresolvableBookmarkFailsExactlyWhileOtherSourcesFinish() async throws {
        // T-ACC-07 expected RED: no persisted-bookmark resume path records bookmark_unresolvable.
        try prepareSources()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic lost authorization")
        let validURL = sourceRoot.appendingPathComponent("B/intake.txt")
        let validBookmark = try validURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let invalid = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "Missing Authorization.txt",
            sourceBookmark: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            state: .selected
        )
        let valid = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:1",
            sourceDisplayPath: "intake.txt",
            sourceBookmark: validBookmark,
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 2, importedCount: 0, failedCount: 0)
        let job = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: batch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()

        let queue = makeQueue(store: store, notifier: RecordingNotifier())
        queue.bootstrap()
        queue.resume(jobID: job.id)
        await queue.waitUntilIdle()

        let rows = try store.documentJobs.fetchSources(batchID: batch.id)
        let invalidAfter = try XCTUnwrap(rows.first { $0.id == invalid.id })
        let validAfter = try XCTUnwrap(rows.first { $0.id == valid.id })
        XCTAssertEqual(invalidAfter.state, DocumentImportSourceState.failed.rawValue)
        XCTAssertEqual(invalidAfter.reason, "bookmark_unresolvable")
        XCTAssertNil(invalidAfter.sourceBookmark)
        XCTAssertEqual(validAfter.state, DocumentImportSourceState.admitted.rawValue)
        XCTAssertNil(validAfter.sourceBookmark)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).map(\.displayName), ["intake.txt"])
        XCTAssertEqual(try store.documentJobs.fetchBatch(id: batch.id)?.status, DocumentImportBatchStatus.completeWithFailures.rawValue)
        let summary = try store.documentJobs.sourcesSummary(batchID: batch.id)
        XCTAssertEqual(summary.terminalCount, 2)
        XCTAssertEqual(summary.unfinishedCount, 0)
        XCTAssertEqual(summary.balanceErrorCount, 0)
    }

    func testTACC10ResumePreservesTargetFolderAndFailsClosedWhenTargetWasDeleted() async throws {
        // T-ACC-10 expected RED: resume ignores the batch target because no copy-resume path exists.
        try prepareSources()
        let resumeURL = sourceRoot.appendingPathComponent("B/intake.txt")
        let bookmark = try resumeURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        let presentStore = try makeStore()
        let presentMatter = try presentStore.matters.createMatter(name: "Synthetic retained target")
        let presentFolder = try presentStore.documentLibrary.createFolder(matterID: presentMatter.id, name: "Folder B")
        let presentBatch = try presentStore.documentJobs.createBatch(
            matterID: presentMatter.id,
            targetFolderID: presentFolder.id,
            targetFolderRequested: true
        )
        _ = try presentStore.documentJobs.recordDiscovered(
            batchID: presentBatch.id,
            matterID: presentMatter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "intake.txt",
            sourceBookmark: bookmark,
            state: .selected
        )
        try presentStore.documentJobs.updateBatchProgress(id: presentBatch.id, discoveredCount: 1)
        let presentJob = try presentStore.documentJobs.enqueueJob(matterID: presentMatter.id, importBatchID: presentBatch.id)
        _ = try presentStore.documentJobs.activateNextJobIfIdle()
        let presentQueue = makeQueue(store: presentStore, notifier: RecordingNotifier())
        presentQueue.bootstrap()
        presentQueue.resume(jobID: presentJob.id)
        await presentQueue.waitUntilIdle()
        let imported = try XCTUnwrap(presentStore.documentLibrary.fetchDocuments(matterID: presentMatter.id).first)
        XCTAssertEqual(imported.folderID, presentFolder.id)

        let missingStore = try makeStore()
        let missingMatter = try missingStore.matters.createMatter(name: "Synthetic deleted target")
        let deletedFolder = try missingStore.documentLibrary.createFolder(matterID: missingMatter.id, name: "Deleted Folder B")
        let missingBatch = try missingStore.documentJobs.createBatch(
            matterID: missingMatter.id,
            targetFolderID: deletedFolder.id,
            targetFolderRequested: true
        )
        let missingSource = try missingStore.documentJobs.recordDiscovered(
            batchID: missingBatch.id,
            matterID: missingMatter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "intake.txt",
            sourceBookmark: bookmark,
            state: .selected
        )
        try missingStore.documentJobs.updateBatchProgress(id: missingBatch.id, discoveredCount: 1)
        let missingJob = try missingStore.documentJobs.enqueueJob(matterID: missingMatter.id, importBatchID: missingBatch.id)
        _ = try missingStore.documentJobs.activateNextJobIfIdle()
        try missingStore.documentLibrary.softDeleteFolder(id: deletedFolder.id)

        let missingQueue = makeQueue(store: missingStore, notifier: RecordingNotifier())
        missingQueue.bootstrap()
        missingQueue.resume(jobID: missingJob.id)
        await missingQueue.waitUntilIdle()
        XCTAssertTrue(try missingStore.documentLibrary.fetchDocuments(matterID: missingMatter.id).isEmpty)
        let missingAfter = try XCTUnwrap(try missingStore.documentJobs.fetchSources(batchID: missingBatch.id).first { $0.id == missingSource.id })
        XCTAssertEqual(missingAfter.state, DocumentImportSourceState.failed.rawValue)
        XCTAssertEqual(missingAfter.reason, "target_folder_unavailable")
        XCTAssertNil(missingAfter.sourceBookmark)
        XCTAssertEqual(try missingStore.documentJobs.fetchBatch(id: missingBatch.id)?.status, DocumentImportBatchStatus.completeWithFailures.rawValue)
    }

    func testTOPS02ResumeSummaryAndDiscardCancelEveryUnfinishedSource() throws {
        // T-OPS-02 expected RED: queue exposes neither a resume summary nor a discard operation.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic discard surface")
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        for index in 0..<5 {
            let source = try store.documentJobs.recordDiscovered(
                batchID: batch.id,
                matterID: matter.id,
                sourceKey: "selection:\(index)",
                sourceDisplayPath: "Source \(index).txt",
                sourceBookmark: index >= 3 ? Data("bookmark-\(index)".utf8) : nil,
                state: .selected
            )
            if index < 3 {
                _ = try store.documentJobs.markState(sourceID: source.id, state: .admitted)
            }
        }
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 5, importedCount: 3)
        let job = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: batch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()

        let queue = makeQueue(store: store, notifier: RecordingNotifier())
        queue.bootstrap()
        let resume = try XCTUnwrap(queue.resumableImports.first { $0.jobID == job.id })
        XCTAssertEqual(resume.matterID, matter.id)
        XCTAssertEqual(resume.totalCount, 5)
        XCTAssertEqual(resume.unfinishedCount, 2)
        XCTAssertEqual(resume.message, "Import interrupted — 2 of 5 files not yet imported")

        queue.discard(jobID: job.id)
        XCTAssertTrue(queue.resumableImports.isEmpty)
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job.id)?.status, DocumentProcessingJobStatus.cancelled.rawValue)
        XCTAssertEqual(try store.documentJobs.fetchBatch(id: batch.id)?.status, DocumentImportBatchStatus.cancelled.rawValue)
        let rows = try store.documentJobs.fetchSources(batchID: batch.id)
        XCTAssertEqual(rows.filter { $0.state == DocumentImportSourceState.admitted.rawValue }.count, 3)
        XCTAssertEqual(rows.filter { $0.state == DocumentImportSourceState.cancelled.rawValue }.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.sourceBookmark == nil })
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
