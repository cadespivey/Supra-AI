import Foundation
import GRDB
import SupraCore

/// Owns import batches and the app-wide document processing job queue
/// (Milestone 3). Enforces a single active job with FIFO queue positions and
/// supports relaunch reconciliation of interrupted jobs.
public final class DocumentJobRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Import batches

    @discardableResult
    public func createBatch(
        matterID: String,
        sourceRootDisplay: String? = nil,
        targetFolderID: String? = nil,
        targetFolderRequested: Bool = false
    ) throws -> DocumentImportBatchRecord {
        try writer.write { db in
            guard targetFolderRequested == (targetFolderID != nil) else {
                throw DocumentJobRepositoryError.invalidTargetFolderIntent
            }
            if let targetFolderID {
                guard let folder = try DocumentFolderRecord.fetchOne(db, key: targetFolderID),
                      folder.matterID == matterID,
                      folder.deletedAt == nil else {
                    throw DocumentJobRepositoryError.targetFolderUnavailable(targetFolderID)
                }
            }
            let record = DocumentImportBatchRecord(
                matterID: matterID,
                sourceRootDisplay: sourceRootDisplay,
                targetFolderID: targetFolderID,
                targetFolderRequested: targetFolderRequested
            )
            try record.insert(db)
            return record
        }
    }

    public func updateBatchProgress(
        id: String,
        discoveredCount: Int? = nil,
        importedCount: Int? = nil,
        failedCount: Int? = nil
    ) throws {
        try writer.write { db in
            guard var record = try DocumentImportBatchRecord.fetchOne(db, key: id) else { return }
            if let discoveredCount { record.discoveredCount = discoveredCount }
            if let importedCount { record.importedCount = importedCount }
            if let failedCount { record.failedCount = failedCount }
            record.status = DocumentImportBatchStatus.processing.rawValue
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    public func finalizeBatch(
        id: String,
        status: DocumentImportBatchStatus,
        reportJSON: String?
    ) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_import_batches
                SET status = ?, report_json = ?, completed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, reportJSON, now, now, id]
            )
        }
    }

    public func fetchBatch(id: String) throws -> DocumentImportBatchRecord? {
        try writer.read { db in try DocumentImportBatchRecord.fetchOne(db, key: id) }
    }

    public func fetchBatches(matterID: String) throws -> [DocumentImportBatchRecord] {
        try writer.read { db in
            try DocumentImportBatchRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_import_batches WHERE matter_id = ? ORDER BY started_at DESC",
                arguments: [matterID]
            )
        }
    }

    /// Finalizes batches left active by a terminated process. Every active
    /// source becomes resumable `interrupted`; already-accounted outcomes and
    /// their exact reasons are preserved in a synthesized report. The batch
    /// update and source transitions are one transaction and a repeated call is
    /// a no-op because only discovering/processing batches are selected.
    @discardableResult
    public func reconcileOrphanedBatches() throws -> [DocumentImportBatchRecord] {
        try writer.write { db in
            var batches = try DocumentImportBatchRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_import_batches
                WHERE status IN (?, ?)
                ORDER BY started_at, id
                """,
                arguments: [
                    DocumentImportBatchStatus.discovering.rawValue,
                    DocumentImportBatchStatus.processing.rawValue,
                ]
            )
            guard !batches.isEmpty else { return [] }

            let now = Date()
            let interruptionReason = "Import interrupted before completion."
            let activeStates = [
                DocumentImportSourceState.selected.rawValue,
                DocumentImportSourceState.discovered.rawValue,
                DocumentImportSourceState.validated.rawValue,
                DocumentImportSourceState.copying.rawValue,
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            for index in batches.indices {
                let batchID = batches[index].id
                try db.execute(
                    sql: """
                    UPDATE document_import_sources
                    SET state = ?, reason = COALESCE(reason, ?), updated_at = ?
                    WHERE import_batch_id = ? AND state IN (?, ?, ?, ?)
                    """,
                    arguments: [
                        DocumentImportSourceState.interrupted.rawValue,
                        interruptionReason,
                        now,
                        batchID,
                        activeStates[0],
                        activeStates[1],
                        activeStates[2],
                        activeStates[3],
                    ]
                )

                let sources = try DocumentImportSourceRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM document_import_sources
                    WHERE import_batch_id = ?
                    ORDER BY created_at, id
                    """,
                    arguments: [batchID]
                )
                let stateCounts = Dictionary(grouping: sources, by: \.state).mapValues { $0.count }
                let importedCount = stateCounts[DocumentImportSourceState.admitted.rawValue, default: 0]
                let failedCount = [
                    DocumentImportSourceState.rejected,
                    .unsupportedByPolicy,
                    .failed,
                    .cancelled,
                    .interrupted,
                ].reduce(into: 0) { count, state in
                    count += stateCounts[state.rawValue, default: 0]
                }
                let report = ReconciledImportReport(
                    items: sources.map(ReconciledImportReportItem.init),
                    counts: stateCounts
                )
                let reportJSON = String(data: try encoder.encode(report), encoding: .utf8)

                batches[index].status = DocumentImportBatchStatus.interrupted.rawValue
                batches[index].discoveredCount = sources.count
                batches[index].importedCount = importedCount
                batches[index].failedCount = failedCount
                batches[index].reportJSON = reportJSON
                batches[index].completedAt = now
                batches[index].updatedAt = now
                try batches[index].update(db)
            }
            return batches
        }
    }

    /// Most recent persisted batch that should restore the import-failure
    /// banner after process recreation.
    public func fetchLatestImportFailureBatch() throws -> DocumentImportBatchRecord? {
        try writer.read { db in
            try DocumentImportBatchRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM document_import_batches
                WHERE status IN (?, ?, ?)
                ORDER BY COALESCE(completed_at, updated_at) DESC, id DESC
                LIMIT 1
                """,
                arguments: [
                    DocumentImportBatchStatus.interrupted.rawValue,
                    DocumentImportBatchStatus.completeWithFailures.rawValue,
                    DocumentImportBatchStatus.failed.rawValue,
                ]
            )
        }
    }

    // MARK: - Import source ledger

    /// Inserts the durable identity for a selected/discovered source, or returns
    /// the existing row for the batch/key idempotency contract. Child rows never
    /// retain a top-level security-scoped bookmark.
    @discardableResult
    public func recordDiscovered(
        batchID: String,
        matterID: String,
        sourceKey: String,
        sourceDisplayPath: String,
        sourceBookmark: Data? = nil,
        parentSourceID: String? = nil,
        state: DocumentImportSourceState = .discovered
    ) throws -> DocumentImportSourceRecord {
        let normalizedKey = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = sourceDisplayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw DocumentJobRepositoryError.requiredFieldMissing("source_key")
        }
        guard !normalizedPath.isEmpty, !NSString(string: normalizedPath).isAbsolutePath else {
            throw DocumentJobRepositoryError.invalidSourceDisplayPath(sourceDisplayPath)
        }
        return try writer.write { db in
            guard let batch = try DocumentImportBatchRecord.fetchOne(db, key: batchID),
                  batch.matterID == matterID else {
                throw DocumentJobRepositoryError.batchMatterMismatch(batchID: batchID, matterID: matterID)
            }
            if let existing = try DocumentImportSourceRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_import_sources WHERE import_batch_id = ? AND source_key = ?",
                arguments: [batchID, normalizedKey]
            ) {
                guard existing.matterID == matterID else {
                    throw DocumentJobRepositoryError.batchMatterMismatch(batchID: batchID, matterID: matterID)
                }
                guard existing.sourceDisplayPath == normalizedPath,
                      existing.parentSourceID == parentSourceID else {
                    throw DocumentJobRepositoryError.sourceIdentityMismatch(normalizedKey)
                }
                return existing
            }
            if let parentSourceID {
                guard let parent = try DocumentImportSourceRecord.fetchOne(db, key: parentSourceID),
                      parent.importBatchID == batchID,
                      parent.matterID == matterID else {
                    throw DocumentJobRepositoryError.parentSourceMismatch(parentSourceID)
                }
            }
            let record = DocumentImportSourceRecord(
                importBatchID: batchID,
                matterID: matterID,
                sourceKey: normalizedKey,
                sourceDisplayPath: normalizedPath,
                sourceBookmark: parentSourceID == nil && !state.isTerminal ? sourceBookmark : nil,
                parentSourceID: parentSourceID,
                state: state.rawValue
            )
            try record.insert(db)
            return record
        }
    }

    /// Advances one source toward a terminal accounting state. Bookmark clearing
    /// occurs in the same transaction as the terminal state write.
    @discardableResult
    public func markState(
        sourceID: String,
        state: DocumentImportSourceState,
        rejectionCode: String? = nil,
        reason: String? = nil,
        documentID: String? = nil,
        blobSHA256: String? = nil
    ) throws -> DocumentImportSourceRecord {
        try writer.write { db in
            guard var record = try DocumentImportSourceRecord.fetchOne(db, key: sourceID) else {
                throw DocumentJobRepositoryError.sourceNotFound(sourceID)
            }
            let current = DocumentImportSourceState(rawValue: record.state)
            guard Self.canTransition(from: current, to: state) else {
                throw DocumentJobRepositoryError.invalidSourceTransition(from: record.state, to: state.rawValue)
            }
            if let documentID {
                guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID),
                      document.matterID == record.matterID else {
                    throw DocumentJobRepositoryError.documentMatterMismatch(documentID)
                }
            }
            record.state = state.rawValue
            if let rejectionCode { record.rejectionCode = rejectionCode }
            if let reason { record.reason = reason }
            if let documentID { record.documentID = documentID }
            if let blobSHA256 { record.blobSHA256 = blobSHA256 }
            if state.isTerminal { record.sourceBookmark = nil }
            record.updatedAt = Date()
            try record.update(db)
            return record
        }
    }

    public func fetchSources(batchID: String) throws -> [DocumentImportSourceRecord] {
        try writer.read { db in
            try DocumentImportSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_import_sources WHERE import_batch_id = ? ORDER BY created_at, id",
                arguments: [batchID]
            )
        }
    }

    public func fetchSources(matterID: String) throws -> [DocumentImportSourceRecord] {
        try writer.read { db in
            try DocumentImportSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_import_sources WHERE matter_id = ? ORDER BY created_at, id",
                arguments: [matterID]
            )
        }
    }

    public func unfinishedSources(batchID: String) throws -> [DocumentImportSourceRecord] {
        try fetchSources(batchID: batchID).filter { !$0.isTerminal }
    }

    public func sourcesSummary(batchID: String) throws -> DocumentImportSourcesSummary {
        let sources = try fetchSources(batchID: batchID)
        func count(_ state: DocumentImportSourceState) -> Int {
            sources.count { $0.state == state.rawValue }
        }
        let admitted = count(.admitted)
        let containers = count(.containerCompleted)
        let rejected = count(.rejected)
        let unsupported = count(.unsupportedByPolicy)
        let failed = count(.failed)
        let cancelled = count(.cancelled)
        let interrupted = count(.interrupted)
        let hidden = count(.excludedHidden)
        let excluded = count(.excludedByUser)
        let terminal = admitted + containers + rejected + unsupported + failed
            + cancelled + hidden + excluded
        let unfinishedStates: Set<DocumentImportSourceState> = [
            .selected, .discovered, .validated, .copying, .interrupted,
        ]
        let unfinished = sources.count {
            guard let state = $0.sourceState else { return false }
            return unfinishedStates.contains(state)
        }
        let categorized = terminal + unfinished
        return DocumentImportSourcesSummary(
            totalCount: sources.count,
            terminalCount: terminal,
            unfinishedCount: unfinished,
            contentDenominator: sources.count - containers,
            admittedCount: admitted,
            containerCompletedCount: containers,
            rejectedCount: rejected,
            unsupportedByPolicyCount: unsupported,
            failedCount: failed,
            cancelledCount: cancelled,
            interruptedCount: interrupted,
            excludedHiddenCount: hidden,
            excludedByUserCount: excluded,
            balanceErrorCount: abs(sources.count - categorized)
        )
    }

    private static func canTransition(
        from current: DocumentImportSourceState?,
        to next: DocumentImportSourceState
    ) -> Bool {
        guard let current else { return false }
        if current == next { return true }
        if current == .interrupted, next == .copying { return true }
        if current.isTerminal { return false }
        if next == .interrupted { return true }
        if next.isTerminal { return true }
        let rank: [DocumentImportSourceState: Int] = [
            .selected: 0,
            .discovered: 1,
            .validated: 2,
            .copying: 3,
        ]
        guard let currentRank = rank[current], let nextRank = rank[next] else { return false }
        return nextRank >= currentRank
    }

    // MARK: - Processing jobs

    /// Enqueues a job at the end of the FIFO queue. `kind` selects the work the
    /// queue runs (import/reindex, classification-only, or targeted reprocess);
    /// `payloadJSON` carries any kind-specific targets. Existing callers keep the
    /// default `process` kind and no payload.
    @discardableResult
    public func enqueueJob(
        matterID: String,
        importBatchID: String? = nil,
        kind: String = DocumentProcessingJobKind.process.rawValue,
        payloadJSON: String? = nil
    ) throws -> DocumentProcessingJobRecord {
        try writer.write { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: """
                SELECT MAX(queue_position) FROM document_processing_jobs
                WHERE status IN (?, ?)
                """,
                arguments: [
                    DocumentProcessingJobStatus.queued.rawValue,
                    DocumentProcessingJobStatus.active.rawValue
                ]
            ) ?? -1
            let record = DocumentProcessingJobRecord(
                matterID: matterID,
                importBatchID: importBatchID,
                kind: kind,
                payloadJSON: payloadJSON,
                queuePosition: maxPosition + 1
            )
            try record.insert(db)
            return record
        }
    }

    public func fetchActiveJob() throws -> DocumentProcessingJobRecord? {
        try writer.read { db in
            try DocumentProcessingJobRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE status = ? LIMIT 1",
                arguments: [DocumentProcessingJobStatus.active.rawValue]
            )
        }
    }

    public func fetchQueuedJobs() throws -> [DocumentProcessingJobRecord] {
        try writer.read { db in
            try DocumentProcessingJobRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_processing_jobs
                WHERE status = ?
                ORDER BY queue_position ASC
                """,
                arguments: [DocumentProcessingJobStatus.queued.rawValue]
            )
        }
    }

    public func fetchPausedJobs() throws -> [DocumentProcessingJobRecord] {
        try writer.read { db in
            try DocumentProcessingJobRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE status = ? ORDER BY updated_at DESC",
                arguments: [DocumentProcessingJobStatus.paused.rawValue]
            )
        }
    }

    public func fetchJobs(matterID: String) throws -> [DocumentProcessingJobRecord] {
        try writer.read { db in
            try DocumentProcessingJobRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE matter_id = ? ORDER BY created_at DESC",
                arguments: [matterID]
            )
        }
    }

    public func fetchJob(id: String) throws -> DocumentProcessingJobRecord? {
        try writer.read { db in try DocumentProcessingJobRecord.fetchOne(db, key: id) }
    }

    /// Promotes the next queued job to active if no job is currently active, and
    /// returns the now-active job (or the existing active job).
    @discardableResult
    public func activateNextJobIfIdle() throws -> DocumentProcessingJobRecord? {
        try writer.write { db in
            if let active = try DocumentProcessingJobRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE status = ? LIMIT 1",
                arguments: [DocumentProcessingJobStatus.active.rawValue]
            ) {
                return active
            }
            guard var next = try DocumentProcessingJobRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM document_processing_jobs
                WHERE status = ?
                ORDER BY queue_position ASC
                LIMIT 1
                """,
                arguments: [DocumentProcessingJobStatus.queued.rawValue]
            ) else {
                return nil
            }
            let now = Date()
            next.status = DocumentProcessingJobStatus.active.rawValue
            next.startedAt = next.startedAt ?? now
            next.updatedAt = now
            try next.update(db)
            return next
        }
    }

    public func updateJobProgress(
        id: String,
        phase: DocumentProcessingPhase,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        phaseProgressJSON: String? = nil
    ) throws {
        try writer.write { db in
            guard var record = try DocumentProcessingJobRecord.fetchOne(db, key: id) else { return }
            record.phase = phase.rawValue
            if let completedUnits { record.completedUnits = completedUnits }
            if let totalUnits { record.totalUnits = totalUnits }
            if let phaseProgressJSON { record.phaseProgressJSON = phaseProgressJSON }
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    public func pauseJob(id: String, resumeStateJSON: String? = nil) throws {
        try writer.write { db in
            guard var record = try DocumentProcessingJobRecord.fetchOne(db, key: id) else { return }
            let now = Date()
            record.status = DocumentProcessingJobStatus.paused.rawValue
            record.phase = DocumentProcessingPhase.paused.rawValue
            record.pausedAt = now
            if let resumeStateJSON { record.resumeStateJSON = resumeStateJSON }
            record.updatedAt = now
            try record.update(db)
        }
    }

    /// Re-queues a paused job at the end of the FIFO queue so the single-active
    /// scheduler promotes it only when idle (avoids two simultaneous active jobs).
    public func requeueJob(id: String) throws {
        try writer.write { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: "SELECT MAX(queue_position) FROM document_processing_jobs WHERE status IN (?, ?)",
                arguments: [DocumentProcessingJobStatus.queued.rawValue, DocumentProcessingJobStatus.active.rawValue]
            ) ?? -1
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, queue_position = ?, paused_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [DocumentProcessingJobStatus.queued.rawValue, maxPosition + 1, now, id]
            )
        }
    }

    public func completeJob(id: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, phase = ?, completed_at = ?, queue_position = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    DocumentProcessingJobStatus.complete.rawValue,
                    DocumentProcessingPhase.complete.rawValue,
                    now, now, id
                ]
            )
        }
    }

    public func failJob(id: String, errorSummary: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, phase = ?, error_summary = ?, completed_at = ?, queue_position = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    DocumentProcessingJobStatus.failed.rawValue,
                    DocumentProcessingPhase.failed.rawValue,
                    errorSummary, now, now, id
                ]
            )
        }
    }

    public func cancelJob(id: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, phase = ?, queue_position = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    DocumentProcessingJobStatus.cancelled.rawValue,
                    DocumentProcessingPhase.cancelled.rawValue,
                    now, id
                ]
            )
        }
    }

    /// Relaunch reconciliation: any job left `active` when the app last quit is
    /// treated as interrupted and moved to `paused` so the user can choose to
    /// resume. Returns the affected job ids.
    @discardableResult
    public func reconcileInterruptedJobs() throws -> [String] {
        try writer.write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM document_processing_jobs WHERE status = ?",
                arguments: [DocumentProcessingJobStatus.active.rawValue]
            )
            guard !ids.isEmpty else { return [] }
            let now = Date()
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, phase = ?, paused_at = ?, updated_at = ?
                WHERE status = ?
                """,
                arguments: [
                    DocumentProcessingJobStatus.paused.rawValue,
                    DocumentProcessingPhase.paused.rawValue,
                    now, now,
                    DocumentProcessingJobStatus.active.rawValue
                ]
            )
            return ids
        }
    }
}

private struct ReconciledImportReport: Codable {
    var items: [ReconciledImportReportItem]
    var counts: [String: Int]
}

private struct ReconciledImportReportItem: Codable {
    var displayName: String
    var sourceDisplayPath: String
    var disposition: String
    var reason: String?
    var documentID: String?
    var parentDocumentID: String?
    var rejectionCode: String?

    init(_ source: DocumentImportSourceRecord) {
        displayName = NSString(string: source.sourceDisplayPath).lastPathComponent
        sourceDisplayPath = source.sourceDisplayPath
        disposition = source.state
        reason = source.reason
        documentID = source.documentID
        parentDocumentID = nil
        rejectionCode = source.rejectionCode
    }
}

public enum DocumentJobRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
    case invalidTargetFolderIntent
    case targetFolderUnavailable(String)
    case batchMatterMismatch(batchID: String, matterID: String)
    case invalidSourceDisplayPath(String)
    case parentSourceMismatch(String)
    case sourceIdentityMismatch(String)
    case sourceNotFound(String)
    case invalidSourceTransition(from: String, to: String)
    case documentMatterMismatch(String)
}
