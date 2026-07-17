import Foundation
import GRDB
import SupraCore

/// A document processing job in the app-wide FIFO queue (Milestone 3). Exactly
/// one job is active at a time; others queue by `queuePosition`.
public struct DocumentProcessingJobRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_processing_jobs"

    public var id: String
    public var matterID: String
    public var importBatchID: String?
    /// What work this job performs (`DocumentProcessingJobKind`): a full
    /// import/reindex, a classification-only pass, or a targeted re-extraction.
    public var kind: String
    /// Kind-specific JSON payload (e.g. the target document ids for a reprocess
    /// job). Nil for jobs whose targets are derived from the matter.
    public var payloadJSON: String?
    public var status: String
    public var phase: String
    public var queuePosition: Int?
    public var totalUnits: Int
    public var completedUnits: Int
    public var phaseProgressJSON: String?
    public var resumeStateJSON: String?
    public var errorSummary: String?
    public var startedAt: Date?
    public var pausedAt: Date?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        importBatchID: String? = nil,
        kind: String = DocumentProcessingJobKind.process.rawValue,
        payloadJSON: String? = nil,
        status: String = DocumentProcessingJobStatus.queued.rawValue,
        phase: String = DocumentProcessingPhase.discovering.rawValue,
        queuePosition: Int? = nil,
        totalUnits: Int = 0,
        completedUnits: Int = 0,
        phaseProgressJSON: String? = nil,
        resumeStateJSON: String? = nil,
        errorSummary: String? = nil,
        startedAt: Date? = nil,
        pausedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.importBatchID = importBatchID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.status = status
        self.phase = phase
        self.queuePosition = queuePosition
        self.totalUnits = totalUnits
        self.completedUnits = completedUnits
        self.phaseProgressJSON = phaseProgressJSON
        self.resumeStateJSON = resumeStateJSON
        self.errorSummary = errorSummary
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case importBatchID = "import_batch_id"
        case kind
        case payloadJSON = "payload_json"
        case status
        case phase
        case queuePosition = "queue_position"
        case totalUnits = "total_units"
        case completedUnits = "completed_units"
        case phaseProgressJSON = "phase_progress_json"
        case resumeStateJSON = "resume_state_json"
        case errorSummary = "error_summary"
        case startedAt = "started_at"
        case pausedAt = "paused_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
