import Combine
import Foundation
import SupraCore
import SupraStore

/// Actionable per-file detail retained from a completed import report.
public struct DocumentImportFailureDetail: Sendable, Equatable {
    public let displayName: String
    public let sourceDisplayPath: String
    public let disposition: String
    public let rejectionCode: String?
    public let reason: String?

    public init(
        displayName: String,
        sourceDisplayPath: String,
        disposition: String,
        rejectionCode: String? = nil,
        reason: String? = nil
    ) {
        self.displayName = displayName
        self.sourceDisplayPath = sourceDisplayPath
        self.disposition = disposition
        self.rejectionCode = rejectionCode
        self.reason = reason
    }
}

/// Summary of an import that finished with per-file failures, for in-app display.
public struct DocumentImportFailureSummary: Sendable, Equatable, Identifiable {
    public let matterID: String
    public let importedCount: Int
    public let discoveredCount: Int
    public let failedCount: Int
    public let reasons: [String]
    public let details: [DocumentImportFailureDetail]

    public init(
        matterID: String,
        importedCount: Int,
        discoveredCount: Int,
        failedCount: Int,
        reasons: [String] = [],
        details: [DocumentImportFailureDetail] = []
    ) {
        self.matterID = matterID
        self.importedCount = importedCount
        self.discoveredCount = discoveredCount
        self.failedCount = failedCount
        self.reasons = reasons
        self.details = details
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

/// Typed result for a corpus submission that targets a capability removed from
/// the product. Callers can distinguish retirement from storage or validation
/// failures without relying on display text.
public enum CorpusAnalysisQueueAdmissionError: Error, LocalizedError, Equatable, Sendable {
    case retiredCapability

    public var errorDescription: String? {
        switch self {
        case .retiredCapability:
            "This corpus-analysis capability has been retired."
        }
    }
}

/// Typed, mutation-aware result for an attempted corpus-job resume.
public enum CorpusAnalysisQueueResumeResult: Equatable, Sendable {
    case resumed
    case retiredCapability
    case unavailable
}

/// Compatibility policy for durable work left by older app versions after its
/// originating capability was retired. The current persisted identity is the exhaustive request run key;
/// an older job-ID shape is also recognized. No generic corpus-analysis task is
/// classified by words such as "review" alone.
enum RetiredCorpusAnalysisPolicy {
    static let identityPrefix = "guided-review:"

    static func isRetired(_ payload: CorpusAnalysisJobPayload) -> Bool {
        guard payload.schemaVersion == 2,
              case .exhaustiveList(let request) = payload.task else { return false }
        return request.runKey.hasPrefix(identityPrefix)
    }

    static func isRetired(_ job: DocumentProcessingJobRecord) -> Bool {
        guard job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue else { return false }
        if job.id.hasPrefix(identityPrefix) { return true }
        guard let payloadJSON = job.payloadJSON,
              let payload = try? JSONDecoder().decode(
                  CorpusAnalysisJobPayload.self,
                  from: Data(payloadJSON.utf8)
              ) else { return false }
        return isRetired(payload)
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
    /// Active corpus job that has received a cooperative pause request and is
    /// finishing its current partition before the durable job becomes paused.
    @Published public private(set) var pausingCorpusJobID: String?
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
    private let corpusAnalysisRunner: (@Sendable (CorpusAnalysisJobPayload) async throws -> Void)?
    private let corpusAnalysisPauseRequester: (@Sendable (String) -> Void)?

    /// Fast-path URLs for jobs that run in this process. Durable selected-source
    /// rows and bookmarks are written before enqueue returns, so these are never
    /// the sole source authority for FIFO-queued imports.
    private var pendingSources: [String: [URL]] = [:]
    private var runTask: Task<Void, Never>?
    private var activeCorpusTask: Task<Void, Error>?
    private var activeCorpusJobID: String?
    private var hasBootstrapped = false

    public init(
        store: SupraStore,
        importService: DocumentImportService,
        makeIndexingService: @escaping @Sendable () -> DocumentIndexingService,
        classificationService: DocumentClassificationService? = nil,
        notifier: any DocumentNotifying = SystemDocumentNotifier(),
        corpusAnalysisRunner: (@Sendable (CorpusAnalysisJobPayload) async throws -> Void)? = nil,
        corpusAnalysisPauseRequester: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.importService = importService
        self.makeIndexingService = makeIndexingService
        self.classificationService = classificationService
        self.notifier = notifier
        self.corpusAnalysisRunner = corpusAnalysisRunner
        self.corpusAnalysisPauseRequester = corpusAnalysisPauseRequester
    }

    deinit {
        // Stop the background pump if the queue is ever released, so a detached
        // runLoop can't keep running after its owner is gone.
        activeCorpusTask?.cancel()
        runTask?.cancel()
    }

    /// Relaunch reconciliation: any job left active is treated as interrupted and
    /// moved to paused for the user to resume (plan §5.4).
    public func bootstrap() {
        if !hasBootstrapped {
            hasBootstrapped = true
            do {
                _ = try store.documentJobs.reconcileOrphanedBatches()
                _ = try store.documentJobs.reconcileInterruptedJobs()
                try reconcileQueuedImportsAfterRelaunch()
                lastImportFailure = try restoredImportFailure()
            } catch {
                lastError = error.localizedDescription
            }
        }
        refresh()
        if queuedJobs.contains(where: {
            $0.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue
        }) {
            pump()
        }
    }

    public func refresh() {
        let persistedActive = try? store.documentJobs.fetchActiveJob()
        activeJob = persistedActive.flatMap {
            RetiredCorpusAnalysisPolicy.isRetired($0) ? nil : $0
        }
        queuedJobs = ((try? store.documentJobs.fetchQueuedJobs()) ?? []).filter {
            !RetiredCorpusAnalysisPolicy.isRetired($0)
        }
        resumableJobs = ((try? store.documentJobs.fetchPausedJobs()) ?? []).filter {
            !RetiredCorpusAnalysisPolicy.isRetired($0)
        }
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

    /// True only for corpus work that can currently own the shared chat runtime.
    /// Paused interrupted work remains user-controlled and does not suppress the
    /// ordinary startup load until the user resumes it.
    public var hasPendingCorpusAnalysisWork: Bool {
        activeJob?.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue
            || queuedJobs.contains { $0.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue }
    }

    /// Enqueues an import job for the given source URLs.
    @discardableResult
    public func enqueueImport(matterID: String, sources: [URL], sourceRootDisplay: String? = nil, targetFolderID: String? = nil) -> String? {
        guard !sources.isEmpty else { return nil }
        do {
            let selections = sources.enumerated().map { selectionIndex, source in
                DocumentJobRepository.SelectedImportSource(
                    sourceKey: "selection:\(selectionIndex)",
                    sourceDisplayPath: source.lastPathComponent,
                    sourceBookmark: selectedSourceBookmark(for: source)
                )
            }
            let result = try store.documentJobs.enqueueImportAtomically(
                matterID: matterID,
                sourceRootDisplay: sourceRootDisplay,
                targetFolderID: targetFolderID,
                targetFolderRequested: targetFolderID != nil,
                selections: selections
            )
            let job = result.job
            pendingSources[job.id] = sources
            lastError = nil
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

    /// Atomically persists a newly planned exact corpus ledger and the one FIFO
    /// job allowed to execute it. Reusing the same prepared value is idempotent:
    /// its stable run and job identities let Store return the original job.
    @discardableResult
    public func enqueueCorpusAnalysis(
        prepared submission: PreparedCorpusAnalysisSubmission,
        approvedScopeReceipt: CorpusAnalysisSnapshot,
        startImmediately: Bool = true
    ) throws -> (runID: String, jobID: String)? {
        do {
            guard !submission.jobID.hasPrefix(RetiredCorpusAnalysisPolicy.identityPrefix),
                  !RetiredCorpusAnalysisPolicy.isRetired(submission.payload) else {
                throw CorpusAnalysisQueueAdmissionError.retiredCapability
            }
            let payloadJSON = String(
                decoding: try JSONEncoder().encode(submission.payload),
                as: UTF8.self
            )
            let proposedJob = DocumentProcessingJobRecord(
                id: submission.jobID,
                matterID: submission.run.matterID,
                kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
                payloadJSON: payloadJSON
            )
            let job = try store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: submission.run,
                partitions: submission.partitions,
                slices: submission.slices,
                job: proposedJob,
                approvedScopeReceipt: approvedScopeReceipt
            )
            refresh()
            if startImmediately { pump() }
            return (runID: submission.run.id, jobID: job.id)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Enqueues a fully reconstructible corpus-analysis request whose exact inputs
    /// were already persisted. The typed overload makes retirement and storage
    /// failure distinguishable to new callers.
    @discardableResult
    public func submitCorpusAnalysis(
        matterID: String,
        payload: CorpusAnalysisJobPayload,
        startImmediately: Bool = true
    ) throws -> String {
        guard !RetiredCorpusAnalysisPolicy.isRetired(payload) else {
            throw CorpusAnalysisQueueAdmissionError.retiredCapability
        }
        let payloadJSON = String(
            decoding: try JSONEncoder().encode(payload),
            as: UTF8.self
        )
        let job = try store.documentJobs.enqueueJob(
            matterID: matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payloadJSON
        )
        refresh()
        if startImmediately { pump() }
        return job.id
    }

    /// Source-compatible wrapper for retained callers. New code should use the
    /// throwing overload above so a retired request is never collapsed into nil.
    @discardableResult
    public func enqueueCorpusAnalysis(
        matterID: String,
        payload: CorpusAnalysisJobPayload
    ) -> String? {
        do {
            return try submitCorpusAnalysis(
                matterID: matterID,
                payload: payload,
                startImmediately: true
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Applies a correction through the import service's immutable-lineage path.
    /// The service's composed reindex enqueuer schedules the follow-up work.
    public func updateExtractedText(
        documentID: String,
        partID: String,
        text: String,
        author: String,
        reason: String
    ) throws {
        try importService.updateExtractedText(
            documentID: documentID,
            partID: partID,
            text: text,
            author: author,
            reason: reason
        )
    }

    public func cancelQueuedJob(id: String) {
        if (try? store.documentJobs.cancelQueuedJob(id: id)) == true {
            pendingSources[id] = nil
        }
        refresh()
    }

    /// Cancels owned active corpus work without cancelling the FIFO pump. The row
    /// becomes cancelled only after the runner acknowledges cancellation and the
    /// corpus engine atomically balances its frozen partition ledger.
    @discardableResult
    public func cancel(jobID: String) -> Bool {
        if activeCorpusJobID == jobID, let activeCorpusTask {
            activeCorpusTask.cancel()
            return true
        }
        do {
            let cancelled = try store.corpusAnalysis.cancelQueuedOrPausedCorpusAnalysis(
                jobID: jobID
            )
            if cancelled {
                pendingSources[jobID] = nil
            }
            refresh()
            return cancelled
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
    }

    /// Requests a cooperative Review pause. The active mapper is not cancelled:
    /// its current partition checkpoints normally, then the runner stops before
    /// beginning the next partition and this job moves to the existing paused state.
    public func pause(jobID: String) {
        guard activeCorpusJobID == jobID,
              pausingCorpusJobID != jobID,
              let corpusAnalysisPauseRequester,
              let job = try? store.documentJobs.fetchJob(id: jobID),
              !RetiredCorpusAnalysisPolicy.isRetired(job),
              let json = job.payloadJSON,
              let payload = try? JSONDecoder().decode(
                  CorpusAnalysisJobPayload.self,
                  from: Data(json.utf8)
              ) else { return }
        pausingCorpusJobID = jobID
        corpusAnalysisPauseRequester(payload.runID)
    }

    /// Resumes a paused job. Sources from the original session are reused if still
    /// held; otherwise the job reconciles by re-indexing already-imported docs.
    public func resume(jobID: String) {
        if let job = try? store.documentJobs.fetchJob(id: jobID),
           job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue {
            _ = resumeCorpusAnalysis(jobID: jobID)
            return
        }
        // Re-queue rather than force-active so the single-active scheduler promotes
        // it only when no other job is running.
        try? store.documentJobs.requeueJob(id: jobID)
        refresh()
        pump()
    }

    /// Re-enters a retained paused corpus job without making legacy Review work
    /// runnable. A retired result performs no write and does not start the pump.
    @discardableResult
    public func resumeCorpusAnalysis(jobID: String) -> CorpusAnalysisQueueResumeResult {
        do {
            guard let job = try store.documentJobs.fetchJob(id: jobID),
                  job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue,
                  job.status == DocumentProcessingJobStatus.paused.rawValue else {
                return .unavailable
            }
            guard !RetiredCorpusAnalysisPolicy.isRetired(job) else {
                return .retiredCapability
            }
            try store.documentJobs.requeueJob(id: jobID)
            refresh()
            pump()
            return .resumed
        } catch {
            lastError = error.localizedDescription
            refresh()
            return .unavailable
        }
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

    /// Queued imports survive a quit differently from the one job that was
    /// active: orphan-batch reconciliation makes their persisted selections
    /// interrupted, then this step pauses the queued job so the existing Resume
    /// UI owns re-entry. Pre-v059/bug-window jobs with no source authority can
    /// never resume and fail explicitly instead of blocking FIFO forever.
    private func reconcileQueuedImportsAfterRelaunch() throws {
        for job in try store.documentJobs.fetchQueuedJobs() {
            guard let batchID = job.importBatchID,
                  let batch = try store.documentJobs.fetchBatch(id: batchID),
                  batch.status == DocumentImportBatchStatus.interrupted.rawValue else { continue }
            let sources = try store.documentJobs.fetchSources(batchID: batchID)
            if sources.isEmpty {
                try store.documentJobs.failJob(
                    id: job.id,
                    errorSummary: "source_authorization_unavailable"
                )
            } else if sources.contains(where: { !$0.isTerminal }) {
                try store.documentJobs.pauseJob(id: job.id)
            }
        }
    }

    private func selectedSourceBookmark(for source: URL) -> Data? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let options: URL.BookmarkCreationOptions = scoped
            ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            : []
        return try? source.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func runLoop() async {
        defer { runTask = nil }
        while let job = try? activateNextEligibleJobIfIdle() {
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

    /// Chooses an eligible FIFO row before activation. This preserves an inert
    /// retired head row byte-for-byte while allowing unrelated work behind it to
    /// acquire the one active slot.
    private func activateNextEligibleJobIfIdle() throws -> DocumentProcessingJobRecord? {
        if let active = try store.documentJobs.fetchActiveJob() {
            return RetiredCorpusAnalysisPolicy.isRetired(active) ? nil : active
        }
        for queued in try store.documentJobs.fetchQueuedJobs() {
            guard !RetiredCorpusAnalysisPolicy.isRetired(queued) else { continue }
            if let activated = try store.documentJobs.activateQueuedJobIfIdle(id: queued.id) {
                return activated
            }
            if let active = try store.documentJobs.fetchActiveJob() {
                return RetiredCorpusAnalysisPolicy.isRetired(active) ? nil : active
            }
        }
        return nil
    }

    private func run(_ job: DocumentProcessingJobRecord) async {
        refresh()
        switch DocumentProcessingJobKind(rawValue: job.kind) ?? .process {
        case .process: await runImportOrReindex(job)
        case .classify: await runClassify(job)
        case .reprocess: await runReprocess(job)
        case .corpusAnalysis: await runCorpusAnalysis(job)
        }
    }

    private func runCorpusAnalysis(_ job: DocumentProcessingJobRecord) async {
        guard let json = job.payloadJSON,
              let payload = try? JSONDecoder().decode(CorpusAnalysisJobPayload.self, from: Data(json.utf8)),
              let corpusAnalysisRunner else {
            let message = "The corpus-analysis runner or job payload is unavailable."
            lastError = message
            try? store.documentJobs.failJob(id: job.id, errorSummary: message)
            return
        }
        guard payload.schemaVersion == 2,
              case .exhaustiveList(let request) = payload.task,
              request.matterID == job.matterID else {
            let message = "The corpus-analysis job is not a coherent reconstructible v2 request."
            lastError = message
            try? store.documentJobs.failJob(id: job.id, errorSummary: message)
            return
        }
        do {
            setPhase(job.id, .analyzingCorpus)
            let task = Task {
                try await corpusAnalysisRunner(payload)
            }
            activeCorpusJobID = job.id
            activeCorpusTask = task
            defer {
                if activeCorpusJobID == job.id {
                    activeCorpusJobID = nil
                    activeCorpusTask = nil
                }
                if pausingCorpusJobID == job.id {
                    pausingCorpusJobID = nil
                }
            }
            try await task.value
            _ = try store.documentJobs.completeActiveJob(id: job.id)
            refresh()
        } catch CorpusAnalysisQueueRunnerError.paused {
            try? store.documentJobs.pauseJob(id: job.id)
            refresh()
        } catch is CancellationError {
            _ = try? store.documentJobs.cancelActiveJob(id: job.id)
            refresh()
        } catch {
            let failed = (try? store.documentJobs.failActiveJob(
                id: job.id,
                errorSummary: error.localizedDescription
            )) == true
            if failed {
                lastError = error.localizedDescription
                _ = try? store.auditEvents.recordEvent(
                    matterID: job.matterID,
                    eventType: "corpus_analysis_failed",
                    actor: "system",
                    summary: "Corpus analysis failed: \(error.localizedDescription)",
                    relatedTable: "document_processing_jobs",
                    relatedID: job.id
                )
            }
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
                reasons: Self.failureReasons(from: report),
                details: Self.failureDetails(from: report)
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
            reasons: report.map { Self.failureReasons(from: $0) } ?? [],
            details: report.map { Self.failureDetails(from: $0) } ?? []
        )
    }

    private static func failureReasons(from report: DocumentImportReport) -> [String] {
        Array(Set(report.items.compactMap(\.reason))).sorted()
    }

    private static func failureDetails(from report: DocumentImportReport) -> [DocumentImportFailureDetail] {
        let failedDispositions: Set<String> = [
            DocumentImportDisposition.extractionFailed.rawValue,
            DocumentImportDisposition.unsupported.rawValue,
            DocumentImportDisposition.ocrFailed.rawValue,
            DocumentImportSourceState.rejected.rawValue,
            DocumentImportSourceState.unsupportedByPolicy.rawValue,
            DocumentImportSourceState.failed.rawValue,
            DocumentImportSourceState.cancelled.rawValue,
            DocumentImportSourceState.interrupted.rawValue,
        ]
        return report.items
            .filter { failedDispositions.contains($0.disposition) }
            .map {
                DocumentImportFailureDetail(
                    displayName: $0.displayName,
                    sourceDisplayPath: $0.sourceDisplayPath,
                    disposition: $0.disposition,
                    rejectionCode: $0.rejectionCode,
                    reason: $0.reason
                )
            }
            .sorted {
                if $0.sourceDisplayPath != $1.sourceDisplayPath {
                    return $0.sourceDisplayPath < $1.sourceDisplayPath
                }
                return $0.displayName < $1.displayName
            }
    }
}

/// The `payload_json` shape for a reprocess job: the target document ids to
/// re-extract from their managed blobs.
private struct ReprocessPayload: Codable {
    var documentIDs: [String]
}
