import Foundation
import GRDB

public struct AppSettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "app_settings"

    public var key: String
    public var valueJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        key: String,
        valueJSON: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.valueJSON = valueJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case valueJSON = "value_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
