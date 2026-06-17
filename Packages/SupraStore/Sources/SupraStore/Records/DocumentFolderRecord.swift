import Foundation
import GRDB
import SupraCore

/// Matter-scoped, user-created folder for organizing document instances (M3).
public struct DocumentFolderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_folders"

    public var id: String
    public var matterID: String
    public var parentFolderID: String?
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        parentFolderID: String? = nil,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.parentFolderID = parentFolderID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case parentFolderID = "parent_folder_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
