import Foundation
import GRDB
import SupraCore

public struct ModelValidationRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "model_validation_runs"

    public var id: String
    public var modelID: String
    public var suiteID: String
    public var suiteVersion: Int
    public var status: String
    public var startedAt: Date
    public var completedAt: Date?
    public var summary: String?
    public var warningsJSON: String
    public var errorsJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        modelID: String,
        suiteID: String,
        suiteVersion: Int,
        status: String = ValidationRunStatus.partial.rawValue,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        summary: String? = nil,
        warningsJSON: String = "[]",
        errorsJSON: String = "[]",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.modelID = modelID
        self.suiteID = suiteID
        self.suiteVersion = suiteVersion
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.summary = summary
        self.warningsJSON = warningsJSON
        self.errorsJSON = errorsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID = "model_id"
        case suiteID = "suite_id"
        case suiteVersion = "suite_version"
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case summary
        case warningsJSON = "warnings_json"
        case errorsJSON = "errors_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
