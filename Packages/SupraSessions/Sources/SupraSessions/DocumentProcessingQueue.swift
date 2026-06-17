import Combine
import Foundation
import SupraCore
import SupraStore

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
    @Published public private(set) var lastError: String?

    private let store: SupraStore
    private let importService: DocumentImportService
    private let makeIndexingService: @Sendable () -> DocumentIndexingService
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
        notifier: any DocumentNotifying = SystemDocumentNotifier()
    ) {
        self.store = store
        self.importService = importService
        self.makeIndexingService = makeIndexingService
        self.notifier = notifier
    }

    /// Relaunch reconciliation: any job left active is treated as interrupted and
    /// moved to paused for the user to resume (plan §5.4).
    public func bootstrap() {
        _ = try? store.documentJobs.reconcileInterruptedJobs()
        refresh()
    }

    public func refresh() {
        activeJob = try? store.documentJobs.fetchActiveJob()
        queuedJobs = (try? store.documentJobs.fetchQueuedJobs()) ?? []
        resumableJobs = (try? store.documentJobs.fetchPausedJobs()) ?? []
    }

    /// Enqueues an import job for the given source URLs.
    @discardableResult
    public func enqueueImport(matterID: String, sources: [URL], sourceRootDisplay: String? = nil) -> String? {
        guard !sources.isEmpty else { return nil }
        do {
            let batch = try store.documentJobs.createBatch(matterID: matterID, sourceRootDisplay: sourceRootDisplay)
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

    public func cancelQueuedJob(id: String) {
        try? store.documentJobs.cancelJob(id: id)
        pendingSources[id] = nil
        refresh()
    }

    /// Resumes a paused job. Sources from the original session are reused if still
    /// held; otherwise the job reconciles by re-indexing already-imported docs.
    public func resume(jobID: String) {
        try? store.documentJobs.resumeJob(id: jobID)
        // resumeJob sets it active; move it back to queued semantics by letting the
        // run loop pick it up. Mark as queued-for-run via pump.
        refresh()
        pump()
    }

    /// Pauses the active job at the current safe boundary (call on app quit).
    public func pauseActiveForQuit() {
        guard let active = try? store.documentJobs.fetchActiveJob() else { return }
        try? store.documentJobs.pauseJob(id: active.id)
        runTask?.cancel()
        refresh()
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
        var importReport: DocumentImportReport?
        do {
            if let sources = pendingSources[job.id], !sources.isEmpty {
                setPhase(job.id, .copyingHashing)
                let outcome = try await importService.importSources(
                    sources, matterID: job.matterID, batchID: job.importBatchID
                )
                importReport = outcome.report
                pendingSources[job.id] = nil
                try? store.documentJobs.updateJobProgress(
                    id: job.id, phase: .extractingText,
                    completedUnits: outcome.report.importedCount, totalUnits: outcome.report.discoveredCount
                )
            }

            setPhase(job.id, .semanticEmbedding)
            let indexer = makeIndexingService()
            _ = try await indexer.indexMatter(matterID: job.matterID)

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

    private func notifyCompletion(job: DocumentProcessingJobRecord, report: DocumentImportReport?) async {
        if let report, report.failedCount > 0 {
            await notifier.notify(
                title: "Import complete with issues",
                body: "Imported \(report.importedCount) of \(report.discoveredCount); \(report.failedCount) need attention."
            )
        } else if let report {
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
}
