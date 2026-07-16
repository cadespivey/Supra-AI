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
    public func createBatch(matterID: String, sourceRootDisplay: String? = nil) throws -> DocumentImportBatchRecord {
        try writer.write { db in
            let record = DocumentImportBatchRecord(matterID: matterID, sourceRootDisplay: sourceRootDisplay)
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
