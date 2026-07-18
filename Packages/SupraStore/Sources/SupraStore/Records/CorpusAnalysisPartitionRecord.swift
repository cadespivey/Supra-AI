import Foundation
import GRDB

public struct CorpusAnalysisPartitionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "corpus_analysis_partitions"

    public var id: String
    public var runID: String
    public var partitionKey: String
    public var inputRevisionIDsJSON: String
    public var attemptCount: Int
    public var attemptHistoryJSON: String
    public var disposition: String
    public var dispositionReason: String?
    public var findingsJSON: String?
    public var errorSummary: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        runID: String,
        partitionKey: String,
        inputRevisionIDsJSON: String,
        attemptCount: Int = 0,
        attemptHistoryJSON: String = "[]",
        disposition: String = "pending",
        dispositionReason: String? = nil,
        findingsJSON: String? = nil,
        errorSummary: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.partitionKey = partitionKey
        self.inputRevisionIDsJSON = inputRevisionIDsJSON
        self.attemptCount = attemptCount
        self.attemptHistoryJSON = attemptHistoryJSON
        self.disposition = disposition
        self.dispositionReason = dispositionReason
        self.findingsJSON = findingsJSON
        self.errorSummary = errorSummary
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case partitionKey = "partition_key"
        case inputRevisionIDsJSON = "input_revision_ids_json"
        case attemptCount = "attempt_count"
        case attemptHistoryJSON = "attempt_history_json"
        case disposition
        case dispositionReason = "disposition_reason"
        case findingsJSON = "findings_json"
        case errorSummary = "error_summary"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}
