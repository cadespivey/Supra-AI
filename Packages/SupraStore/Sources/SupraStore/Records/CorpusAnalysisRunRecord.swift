import Foundation
import GRDB

public struct CorpusAnalysisRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "corpus_analysis_runs"

    public var id: String
    public var runKey: String
    public var matterID: String
    public var taskKind: String
    public var scopeJSON: String
    public var corpusSnapshotJSON: String
    public var partitionStrategy: String
    public var partitionStrategyVersion: Int
    public var modelLineageJSON: String?
    public var status: String
    public var coverageJSON: String?
    public var reconciliationJSON: String?
    public var validationResultsJSON: String?
    public var assuranceState: String?
    public var assuranceReasonsJSON: String?
    public var structuredOutputVersionID: String?
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        runKey: String,
        matterID: String,
        taskKind: String,
        scopeJSON: String,
        corpusSnapshotJSON: String,
        partitionStrategy: String,
        partitionStrategyVersion: Int,
        modelLineageJSON: String? = nil,
        status: String,
        coverageJSON: String? = nil,
        reconciliationJSON: String? = nil,
        validationResultsJSON: String? = nil,
        assuranceState: String? = nil,
        assuranceReasonsJSON: String? = nil,
        structuredOutputVersionID: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runKey = runKey
        self.matterID = matterID
        self.taskKind = taskKind
        self.scopeJSON = scopeJSON
        self.corpusSnapshotJSON = corpusSnapshotJSON
        self.partitionStrategy = partitionStrategy
        self.partitionStrategyVersion = partitionStrategyVersion
        self.modelLineageJSON = modelLineageJSON
        self.status = status
        self.coverageJSON = coverageJSON
        self.reconciliationJSON = reconciliationJSON
        self.validationResultsJSON = validationResultsJSON
        self.assuranceState = assuranceState
        self.assuranceReasonsJSON = assuranceReasonsJSON
        self.structuredOutputVersionID = structuredOutputVersionID
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runKey = "run_key"
        case matterID = "matter_id"
        case taskKind = "task_kind"
        case scopeJSON = "scope_json"
        case corpusSnapshotJSON = "corpus_snapshot_json"
        case partitionStrategy = "partition_strategy"
        case partitionStrategyVersion = "partition_strategy_version"
        case modelLineageJSON = "model_lineage_json"
        case status
        case coverageJSON = "coverage_json"
        case reconciliationJSON = "reconciliation_json"
        case validationResultsJSON = "validation_results_json"
        case assuranceState = "assurance_state"
        case assuranceReasonsJSON = "assurance_reasons_json"
        case structuredOutputVersionID = "structured_output_version_id"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}
