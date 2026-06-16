import Foundation
import GRDB
import SupraCore

public struct MessageVariantRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "message_variants"

    public var id: String
    public var messageID: String
    public var generationSessionID: String?
    public var content: String
    public var status: String
    public var interruptionReason: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        messageID: String,
        generationSessionID: String? = nil,
        content: String = "",
        status: String = MessageStatus.pending.rawValue,
        interruptionReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.generationSessionID = generationSessionID
        self.content = content
        self.status = status
        self.interruptionReason = interruptionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case generationSessionID = "generation_session_id"
        case content
        case status
        case interruptionReason = "interruption_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
