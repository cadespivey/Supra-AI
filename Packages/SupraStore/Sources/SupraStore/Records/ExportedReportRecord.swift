import Foundation
import GRDB

public struct ExportedReportRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "exported_reports"

    public var id: String
    public var validationRunID: String?
    public var format: String
    public var fileURL: String
    public var redacted: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        validationRunID: String? = nil,
        format: String,
        fileURL: String,
        redacted: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.validationRunID = validationRunID
        self.format = format
        self.fileURL = fileURL
        self.redacted = redacted
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case validationRunID = "validation_run_id"
        case format
        case fileURL = "file_url"
        case redacted
        case createdAt = "created_at"
    }
}
