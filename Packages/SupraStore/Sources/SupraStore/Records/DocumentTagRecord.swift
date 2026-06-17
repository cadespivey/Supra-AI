import Foundation
import GRDB
import SupraCore

/// Matter-scoped, user-created tag (Milestone 3). Tags attach to document
/// instances, not blobs.
public struct DocumentTagRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_tags"

    public var id: String
    public var matterID: String
    public var name: String
    public var color: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        name: String,
        color: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case name
        case color
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
