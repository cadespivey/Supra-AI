import Foundation
import GRDB
import SupraCore

public struct StructuredOutputRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "structured_outputs"

    public var id: String
    public var matterID: String
    public var chatID: String?
    public var researchSessionID: String?
    public var title: String
    public var outputType: String
    public var activeVersionID: String?
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        chatID: String? = nil,
        researchSessionID: String? = nil,
        title: String,
        outputType: String,
        activeVersionID: String? = nil,
        status: String = StructuredOutputStatus.draft.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.chatID = chatID
        self.researchSessionID = researchSessionID
        self.title = title
        self.outputType = outputType
        self.activeVersionID = activeVersionID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case chatID = "chat_id"
        case researchSessionID = "research_session_id"
        case title
        case outputType = "output_type"
        case activeVersionID = "active_version_id"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
