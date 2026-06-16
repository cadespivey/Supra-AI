import Foundation
import GRDB
import SupraCore

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "messages"

    public var id: String
    public var chatID: String
    public var role: String
    public var content: String
    public var status: String
    public var activeVariantID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        chatID: String,
        role: String,
        content: String = "",
        status: String = MessageStatus.pending.rawValue,
        activeVariantID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.content = content
        self.status = status
        self.activeVariantID = activeVariantID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case role
        case content
        case status
        case activeVariantID = "active_variant_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
