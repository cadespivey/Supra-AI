import Foundation
import GRDB

public struct ModelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "models"

    public var id: String
    public var displayName: String
    public var path: String
    public var bookmarkData: Data?
    public var isActive: Bool
    public var validationStatus: String?
    public var lastValidatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        path: String,
        bookmarkData: Data? = nil,
        isActive: Bool = false,
        validationStatus: String? = nil,
        lastValidatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.isActive = isActive
        self.validationStatus = validationStatus
        self.lastValidatedAt = lastValidatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case path
        case bookmarkData = "bookmark_data"
        case isActive = "is_active"
        case validationStatus = "validation_status"
        case lastValidatedAt = "last_validated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
