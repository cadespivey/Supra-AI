import Foundation
import GRDB
import SupraCore

/// Join row attaching a tag to a document instance (Milestone 3).
public struct DocumentTagAssignmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_tag_assignments"

    public var id: String
    public var tagID: String
    public var documentID: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        tagID: String,
        documentID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tagID = tagID
        self.documentID = documentID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tagID = "tag_id"
        case documentID = "document_id"
        case createdAt = "created_at"
    }
}
