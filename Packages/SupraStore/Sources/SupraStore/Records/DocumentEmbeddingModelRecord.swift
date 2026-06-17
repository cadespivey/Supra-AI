import Foundation
import GRDB
import SupraCore

/// A locally-installed embedding model usable for semantic indexing (M3). Kept
/// separate from the chat `models` table so the two are never confused.
public struct DocumentEmbeddingModelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_embedding_models"

    public var id: String
    public var repoID: String
    public var localPath: String?
    public var displayName: String
    public var dimension: Int
    public var runtimeFamily: String
    public var revision: String?
    public var isDefault: Bool
    public var isSelected: Bool
    public var lastTestLoadAt: Date?
    public var lastTestLoadResult: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        repoID: String,
        localPath: String? = nil,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        revision: String? = nil,
        isDefault: Bool = false,
        isSelected: Bool = false,
        lastTestLoadAt: Date? = nil,
        lastTestLoadResult: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.repoID = repoID
        self.localPath = localPath
        self.displayName = displayName
        self.dimension = dimension
        self.runtimeFamily = runtimeFamily
        self.revision = revision
        self.isDefault = isDefault
        self.isSelected = isSelected
        self.lastTestLoadAt = lastTestLoadAt
        self.lastTestLoadResult = lastTestLoadResult
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case repoID = "repo_id"
        case localPath = "local_path"
        case displayName = "display_name"
        case dimension
        case runtimeFamily = "runtime_family"
        case revision
        case isDefault = "is_default"
        case isSelected = "is_selected"
        case lastTestLoadAt = "last_test_load_at"
        case lastTestLoadResult = "last_test_load_result"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
