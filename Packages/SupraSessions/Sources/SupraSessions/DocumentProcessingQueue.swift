import Combine
import Foundation
import SupraCore
import SupraStore

/// Summary of an import that finished with per-file failures, for in-app display.
public struct DocumentImportFailureSummary: Sendable, Equatable, Identifiable {
    public let matterID: String
    public let importedCount: Int
    public let discoveredCount: Int
    public let failedCount: Int
    public let reasons: [String]

    public init(
        matterID: String,
        importedCount: Int,
        discoveredCount: Int,
        failedCount: Int,
        reasons: [String] = []
    ) {
        self.matterID = matterID
        self.importedCount = importedCount
        self.discoveredCount = discoveredCount
        self.failedCount = failedCount
        self.reasons = reasons
    }
    /// Stable per-outcome id so a dismissed banner stays dismissed but a new
    /// failing import re-shows one.
    public var id: String { "\(matterID)-\(discoveredCount)-\(importedCount)-\(failedCount)" }
}

/// Persisted relaunch work presented to the Documents tab.
public struct ResumableDocumentImport: Sendable, Equatable, Identifiable {
    public let jobID: String
    public let matterID: String
    public let totalCount: Int
    public let unfinishedCount: Int

    public var id: String { jobID }
    public var message: String {
        "Import interrupted — \(unfinishedCount) of \(totalCount) files not yet imported"
    }
}

/// App-wide document processing queue (plan §5.2–§5.6). Exactly one job runs at a
/// time; others queue FIFO. Jobs run import → indexing, report phase progress,
/// fire completion/failure notifications, and reconcile safely after an
/// interrupted quit (active jobs become paused and the user is asked to resume).
@MainActor
public final class DocumentProcessingQueue: ObservableObject {
    @Published public private(set) var activeJob: DocumentProcessingJobRecord?
    @Published public private(set) var queuedJobs: [DocumentProcessingJobRecord] = []
    /// Jobs paused by an interrupted quit, awaiting the user's resume decision.
    @Published public private(set) var resumableJobs: [DocumentProcessingJobRecord] = []
    @Published public private(set) var resumableImports: [ResumableDocumentImport] = []
    @Published public private(set) var lastError: String?
    /// The most recent import that completed with per-file failures, for in-app
    /// surfacing (the Documents tab shows a banner). Cleared on a later clean
    /// import of the same matter or via `clearImportFailure()`.
    @Published public private(set) var lastImportFailure: DocumentImportFailureSummary?

    private let store: SupraStore
    private let importService: DocumentImportService
    private let makeIndexingService: @Sendable () -> DocumentIndexingService
    /// The document classifier, or nil when classification is disabled (e.g. no
    /// runtime). Best-effort and main-actor isolated; never fails a job.
    private let classificationService: DocumentClassificationService?
    private let notifier: any DocumentNotifying

    /// In-memory source URLs for not-yet-run import jobs (originals are not
    /// persisted). A job whose sources are lost across a relaunch falls back to
    /// store-only reconciliation (re-indexing already-copied documents).
    private var pendingSources: [String: [URL]] = [:]
    private var runTask: Task<Void, Never>?

    public init(
        store: SupraStore,
        importService: DocumentImportService,
        makeIndexingService: @escaping @Sendable () -> DocumentIndexingService,
        classificationService: DocumentClassificationService? = nil,
        notifier: any DocumentNotifying = SystemDocumentNotifier()
    ) {
        self.store = store
        self.importService = importService
        self.makeIndexingService = makeIndexingService
        self.classificationService = classificationService
        self.notifier = notifier
    }

    deinit {
        // Stop the background pump if the queue is ever released, so a detached
        // runLoop can't keep running after its owner is gone.
        runTask?.cancel()
    }

    /// Relaunch reconciliation: any job left active is treated as interrupted and
    /// moved to paused for the user to resume (plan §5.4).
    public func bootstrap() {
        do {
            _ = try store.documentJobs.reconcileOrphanedBatches()
            _ = try store.documentJobs.reconcileInterruptedJobs()
            lastImportFailure = try restoredImportFailure()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    public func refresh() {
        activeJob = try? store.documentJobs.fetchActiveJob()
        queuedJobs = (try? store.documentJobs.fetchQueuedJobs()) ?? []
        resumableJobs = (try? store.documentJobs.fetchPausedJobs()) ?? []
        resumableImports = resumableJobs.compactMap { job in
            guard let batchID = job.importBatchID,
                  let summary = try? store.documentJobs.sourcesSummary(batchID: batchID),
                  summary.totalCount > 0,
                  summary.unfinishedCount > 0 else { return nil }
            return ResumableDocumentImport(
                jobID: job.id,
                matterID: job.matterID,
                totalCount: summary.totalCount,
                unfinishedCount: summary.unfinishedCount
            )
        }
    }

    /// Enqueues an import job for the given source URLs.
    @discardableResult
    public func enqueueImport(matterID: String, sources: [URL], sourceRootDisplay: String? = nil, targetFolderID: String? = nil) -> String? {
        guard !sources.isEmpty else { return nil }
        do {
            let batch = try store.documentJobs.createBatch(
                matterID: matterID,
                sourceRootDisplay: sourceRootDisplay,
                targetFolderID: targetFolderID,
                targetFolderRequested: targetFolderID != nil
            )
            let job = try store.documentJobs.enqueueJob(matterID: matterID, importBatchID: batch.id)
            pendingSources[job.id] = sources
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "document_import_started", actor: "user",
                summary: "Queued import of \(sources.count) item(s)", relatedTable: "document_processing_jobs", relatedID: job.id
            )
            refresh()
            pump()
            return job.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Enqueues a re-index job for a matter (no new import).
    @discardableResult
    public func enqueueReindex(matterID: String) -> String? {
        do {
            let job = try store.documentJobs.enqueueJob(matterID: matterID)
            refresh()
            pump()
            return job.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Enqueues a classification-only job for a matter's pending documents. No-ops
    /// (returns nil, creates no job) when classification is disabled, when no document
    /// is eligible for classification, or when a job is already queued/active/paused for
    /// the matter (which will classify as its final phase) — so it is safe to call
    /// speculatively (e.g. when a model finishes loading or the Documents tab appears).
    @discardableResult
    public func enqueueClassify(matterID: String) -> String? {
        guard classificationService != nil else { return nil }
        let documents = (try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []
        guard documents.contains(where: DocumentClassificationService.needsClassification) else { return nil }
        let existing = (try? store.documentJobs.fetchJobs(matterID: matterID)) ?? []
        let hasPendingJob = existing.contains { job in
            job.status == DocumentProcessingJobStatus.queued.rawValue
                || job.status == DocumentProcessingJobStatus.active.rawValue
                || job.status == DocumentProcessingJobStatus.paused.rawValue
        }
        guard !hasPendingJob else { return nil }
        do {
            let job = try store.documentJobs.enqueueJob(
                matterID: matterID, kind: DocumentProcessingJobKind.classify.rawValue
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "document_classification_started", actor: "user",
                summary: "Queued classification of pending documents",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
            refresh()
            pump()
            return job.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Enqueues a reprocess job that re-extracts the named documents from their managed
    /// blobs (a targeted retry). The targets are persisted in `payload_json` so the job
    /// survives a relaunch. No-ops when `documentIDs` is empty.
    @discardableResult
    public func enqueueReprocess(matterID: String, documentIDs: [String]) -> String? {
        guard !documentIDs.isEmpty else { return nil }
        do {
            let payloadJSON = String(
                data: try JSONEncoder().encode(ReprocessPayload(documentIDs: documentIDs)),
                encoding: .utf8
            )
            let job = try store.documentJobs.enqueueJob(
                matterID: matterID,
                kind: DocumentProcessingJobKind.reprocess.rawValue,
                payloadJSON: payloadJSON
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "document_reprocess_started", actor: "user",
                summary: "Queued re-extraction of \(documentIDs.count) document(s)",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
            refresh()
            pump()
            return job.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func cancelQueuedJob(id: String) {
        try? store.documentJobs.cancelJob(id: id)
        pendingSources[id] = nil
        refresh()
    }

    /// Resumes a paused job. Sources from the original session are reused if still
    /// held; otherwise the job reconciles by re-indexing already-imported docs.
    public func resume(jobID: String) {
        // Re-queue rather than force-active so the single-active scheduler promotes
        // it only when no other job is running.
        try? store.documentJobs.requeueJob(id: jobID)
        refresh()
        pump()
    }

    /// Discards a paused post-v059 import without touching rows that already
    /// succeeded. Legacy paused jobs without a ledger retain the job-only cancel
    /// behavior.
    public func discard(jobID: String) {
        do {
            if let job = try store.documentJobs.fetchJob(id: jobID),
               job.status == DocumentProcessingJobStatus.paused.rawValue,
               let batchID = job.importBatchID,
               !(try store.documentJobs.fetchSources(batchID: batchID)).isEmpty {
                _ = try importService.discardBatch(batchID: batchID, matterID: job.matterID)
            }
            try store.documentJobs.cancelJob(id: jobID)
            pendingSources[jobID] = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Awaits the current run loop until the queue is idle. Useful for tests and
    /// for a deterministic shutdown.
    public func waitUntilIdle() async {
        while let task = runTask {
            await task.value
        }
    }

    // MARK: - Run loop

    private func pump() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        defer { runTask = nil }
        while let job = try? store.documentJobs.activateNextJobIfIdle() {
            // Avoid re-running a job we already finished in this loop.
            if job.status == DocumentProcessingJobStatus.complete.rawValue
                || job.status == DocumentProcessingJobStatus.failed.rawValue
                || job.status == DocumentProcessingJobStatus.cancelled.rawValue {
                break
            }
            await run(job)
            refresh()
            if Task.isCancelled { break }
        }
    }

    private func run(_ job: DocumentProcessingJobRecord) async {
        refresh()
        switch DocumentProcessingJobKind(rawValue: job.kind) ?? .process {
        case .process: await runImportOrReindex(job)
        case .classify: await runClassify(job)
        case .reprocess: await runReprocess(job)
        }
    }

    /// The legacy import-or-reindex path: import (if sources are held) → index →
    /// classify → complete, then fire a completion/failure notification.
    private func runImportOrReindex(_ job: DocumentProcessingJobRecord) async {
        var importReport: DocumentImportReport?
        do {
            if let sources = pendingSources[job.id], !sources.isEmpty {
                setPhase(job.id, .copyingHashing)
                let targetFolderID = try job.importBatchID.flatMap {
                    try store.documentJobs.fetchBatch(id: $0)?.targetFolderID
                }
                let outcome = try await importService.importSources(
                    sources, matterID: job.matterID,
                    targetFolderID: targetFolderID, batchID: job.importBatchID
                )
                importReport = outcome.report
                pendingSources[job.id] = nil
                try? store.documentJobs.updateJobProgress(
                    id: job.id, phase: .extractingText,
                    completedUnits: outcome.report.importedCount, totalUnits: outcome.report.discoveredCount
                )
            } else if let batchID = job.importBatchID,
                      !(try store.documentJobs.fetchSources(batchID: batchID)).isEmpty {
                setPhase(job.id, .copyingHashing)
                let outcome = try await importService.resumeBatch(batchID: batchID, matterID: job.matterID)
                importReport = outcome.report
                try? store.documentJobs.updateJobProgress(
                    id: job.id,
                    phase: .extractingText,
                    completedUnits: outcome.report.importedCount,
                    totalUnits: outcome.report.discoveredCount
                )
            }

            setPhase(job.id, .semanticEmbedding)
            let indexer = makeIndexingService()
            _ = try await indexer.indexMatter(matterID: job.matterID)

            // Suggest a taxonomy category for each new document (best-effort; a
            // classification failure or missing model never fails the job).
            if let classificationService {
                setPhase(job.id, .classifying)
                _ = await classificationService.classifyMatter(matterID: job.matterID)
            }

            try? store.documentJobs.updateJobProgress(id: job.id, phase: .finalizingReport)
            try? store.documentJobs.completeJob(id: job.id)
            await notifyCompletion(job: job, report: importReport)
        } catch {
            lastError = error.localizedDescription
            try? store.documentJobs.failJob(id: job.id, errorSummary: error.localizedDescription)
            _ = try? store.auditEvents.recordEvent(
                matterID: job.matterID, eventType: "document_job_failed", actor: "system",
                summary: "Processing job failed: \(error.localizedDescription)",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
            await notifier.notify(title: "Document processing failed", body: error.localizedDescription)
        }
    }

    /// A classification-only job: runs just the classify phase over the matter's pending
    /// documents. It must NOT fire a completion/failure notification — it is a background
    /// touch-up, not a user-initiated import whose finish the user is waiting on.
    private func runClassify(_ job: DocumentProcessingJobRecord) async {
        do {
            setPhase(job.id, .classifying)
            if let classificationService {
                _ = await classificationService.classifyMatter(matterID: job.matterID)
            }
            try store.documentJobs.completeJob(id: job.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
            try? store.documentJobs.failJob(id: job.id, errorSummary: error.localizedDescription)
            _ = try? store.auditEvents.recordEvent(
                matterID: job.matterID, eventType: "document_job_failed", actor: "system",
                summary: "Classification job failed: \(error.localizedDescription)",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
        }
    }

    /// A reprocess job: re-extracts each target named in `payload_json` from its managed
    /// blob, then re-indexes and re-classifies the matter. A single document's failure is
    /// collected (and audited) without failing the whole job; a completion notification
    /// fires ONLY when one or more targets could not be re-extracted. A missing/malformed
    /// payload fails the job with a clear summary.
    private func runReprocess(_ job: DocumentProcessingJobRecord) async {
        guard let json = job.payloadJSON,
              let payload = try? JSONDecoder().decode(ReprocessPayload.self, from: Data(json.utf8)) else {
            let message = "The reprocess job payload was missing or malformed."
            lastError = message
            try? store.documentJobs.failJob(id: job.id, errorSummary: message)
            _ = try? store.auditEvents.recordEvent(
                matterID: job.matterID, eventType: "document_job_failed", actor: "system",
                summary: "Reprocess job failed: \(message)",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
            return
        }
        do {
            setPhase(job.id, .extractingText)
            var failedTargets = 0
            for documentID in payload.documentIDs {
                do {
                    try await importService.reprocessDocument(documentID: documentID)
                } catch {
                    failedTargets += 1
                    _ = try? store.auditEvents.recordEvent(
                        matterID: job.matterID, eventType: "document_reprocess_failed", actor: "system",
                        summary: "Could not reprocess a document: \(error.localizedDescription)",
                        relatedTable: "matter_documents", relatedID: documentID
                    )
                }
            }

            setPhase(job.id, .semanticEmbedding)
            _ = try await makeIndexingService().indexMatter(matterID: job.matterID)

            if let classificationService {
                setPhase(job.id, .classifying)
                _ = await classificationService.classifyMatter(matterID: job.matterID)
            }

            try store.documentJobs.completeJob(id: job.id)
            refresh()
            if failedTargets > 0 {
                await notifier.notify(
                    title: "Reprocessing complete with issues",
                    body: "\(failedTargets) document(s) could not be re-extracted."
                )
            }
        } catch {
            lastError = error.localizedDescription
            try? store.documentJobs.failJob(id: job.id, errorSummary: error.localizedDescription)
            _ = try? store.auditEvents.recordEvent(
                matterID: job.matterID, eventType: "document_job_failed", actor: "system",
                summary: "Reprocess job failed: \(error.localizedDescription)",
                relatedTable: "document_processing_jobs", relatedID: job.id
            )
            await notifier.notify(title: "Document processing failed", body: error.localizedDescription)
        }
    }

    /// Clears the in-app import-failure banner (called when the user dismisses it).
    public func clearImportFailure() { lastImportFailure = nil }

    private func notifyCompletion(job: DocumentProcessingJobRecord, report: DocumentImportReport?) async {
        if let report, report.failedCount > 0 {
            lastImportFailure = DocumentImportFailureSummary(
                matterID: job.matterID,
                importedCount: report.importedCount,
                discoveredCount: report.discoveredCount,
                failedCount: report.failedCount,
                reasons: Self.failureReasons(from: report)
            )
            await notifier.notify(
                title: "Import complete with issues",
                body: "Imported \(report.importedCount) of \(report.discoveredCount); \(report.failedCount) need attention."
            )
        } else if let report {
            if lastImportFailure?.matterID == job.matterID { lastImportFailure = nil }
            await notifier.notify(
                title: "Import complete",
                body: "Imported and indexed \(report.importedCount) document(s)."
            )
        } else {
            await notifier.notify(title: "Indexing complete", body: "Documents are ready for search and Q&A.")
        }
    }

    private func setPhase(_ jobID: String, _ phase: DocumentProcessingPhase) {
        try? store.documentJobs.updateJobProgress(id: jobID, phase: phase)
        refresh()
    }

    private func restoredImportFailure() throws -> DocumentImportFailureSummary? {
        guard let batch = try store.documentJobs.fetchLatestImportFailureBatch() else { return nil }
        let report = batch.reportJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(DocumentImportReport.self, from: $0) }
        return DocumentImportFailureSummary(
            matterID: batch.matterID,
            importedCount: batch.importedCount,
            discoveredCount: batch.discoveredCount,
            failedCount: batch.failedCount,
            reasons: report.map { Self.failureReasons(from: $0) } ?? []
        )
    }

    private static func failureReasons(from report: DocumentImportReport) -> [String] {
        Array(Set(report.items.compactMap(\.reason))).sorted()
    }
}

/// The `payload_json` shape for a reprocess job: the target document ids to
/// re-extract from their managed blobs.
private struct ReprocessPayload: Codable {
    var documentIDs: [String]
}
