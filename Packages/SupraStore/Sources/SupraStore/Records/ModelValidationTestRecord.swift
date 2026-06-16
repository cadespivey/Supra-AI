import Foundation
import GRDB
import SupraCore

public struct ModelValidationTestRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "model_validation_tests"

    public var id: String
    public var runID: String
    public var testID: String
    public var name: String
    public var status: String
    public var outputExcerpt: String
    public var warningsJSON: String
    public var errorsJSON: String
    public var startedAt: Date
    public var completedAt: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        runID: String,
        testID: String,
        name: String,
        status: String = ValidationTestStatus.skipped.rawValue,
        outputExcerpt: String = "",
        warningsJSON: String = "[]",
        errorsJSON: String = "[]",
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.testID = testID
        self.name = name
        self.status = status
        self.outputExcerpt = outputExcerpt
        self.warningsJSON = warningsJSON
        self.errorsJSON = errorsJSON
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case testID = "test_id"
        case name
        case status
        case outputExcerpt = "output_excerpt"
        case warningsJSON = "warnings_json"
        case errorsJSON = "errors_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }
}
