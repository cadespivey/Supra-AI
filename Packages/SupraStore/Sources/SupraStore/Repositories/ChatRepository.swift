import Foundation
import GRDB
import SupraCore

public final class ChatRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createGlobalChat(title: String) throws -> ChatRecord {
        try writer.write { db in
            let record = ChatRecord(title: title, scope: "global")
            try record.insert(db)
            return record
        }
    }

    public func fetchGlobalChats() throws -> [ChatRecord] {
        try writer.read { db in
            try ChatRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM chats
                WHERE scope = 'global' AND deleted_at IS NULL
                ORDER BY updated_at DESC
                """
            )
        }
    }

    public func fetchMessages(chatID: String) throws -> [MessageRecord] {
        try writer.read { db in
            try MessageRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM messages
                WHERE chat_id = ? AND deleted_at IS NULL
                ORDER BY created_at ASC
                """,
                arguments: [chatID]
            )
        }
    }

    public func fetchVariants(messageID: String, includeDeleted: Bool = false) throws -> [MessageVariantRecord] {
        try writer.read { db in
            let deletedClause = includeDeleted ? "" : "AND deleted_at IS NULL"
            return try MessageVariantRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM message_variants
                WHERE message_id = ? \(deletedClause)
                ORDER BY created_at ASC
                """,
                arguments: [messageID]
            )
        }
    }

    public func appendUserMessage(chatID: String, content: String) throws -> MessageRecord {
        try writer.write { db in
            let now = Date()
            let message = MessageRecord(
                chatID: chatID,
                role: MessageRole.user.rawValue,
                content: content,
                status: MessageStatus.completed.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try message.insert(db)
            try touchChat(db, chatID: chatID, date: now)
            return message
        }
    }

    public func createAssistantMessageShell(chatID: String) throws -> MessageRecord {
        try writer.write { db in
            let now = Date()
            let message = MessageRecord(
                chatID: chatID,
                role: MessageRole.assistant.rawValue,
                status: MessageStatus.pending.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try message.insert(db)
            try touchChat(db, chatID: chatID, date: now)
            return message
        }
    }

    public func createVariant(messageID: String, generationSessionID: String?) throws -> MessageVariantRecord {
        try writer.write { db in
            let now = Date()
            let variant = MessageVariantRecord(
                messageID: messageID,
                generationSessionID: generationSessionID,
                status: MessageStatus.pending.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try variant.insert(db)
            try db.execute(
                sql: "UPDATE messages SET active_variant_id = ?, updated_at = ? WHERE id = ? AND active_variant_id IS NULL",
                arguments: [variant.id, now, messageID]
            )
            return variant
        }
    }

    public func appendToken(to variantID: String, token: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE message_variants
                SET content = content || ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [token, now, variantID]
            )
            try syncActiveMessageContent(db, variantID: variantID, status: nil, date: now)
        }
    }

    public func completeVariant(_ variantID: String) throws {
        try updateVariantStatus(variantID, status: .completed, interruptionReason: nil)
    }

    public func markVariantCancelled(_ variantID: String) throws {
        try updateVariantStatus(variantID, status: .cancelled, interruptionReason: nil)
    }

    public func markVariantInterrupted(_ variantID: String, reason: String) throws {
        try updateVariantStatus(variantID, status: .interrupted, interruptionReason: reason)
    }

    public func softDeleteVariant(_ variantID: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE message_variants
                SET status = ?, deleted_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [MessageStatus.deleted.rawValue, now, now, variantID]
            )
        }
    }

    public func setActiveVariant(messageID: String, variantID: String) throws {
        try writer.write { db in
            let now = Date()
            guard let variant = try MessageVariantRecord.fetchOne(db, key: variantID), variant.messageID == messageID else {
                return
            }
            try db.execute(
                sql: """
                UPDATE messages
                SET active_variant_id = ?, content = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [variantID, variant.content, variant.status, now, messageID]
            )
        }
    }

    private func updateVariantStatus(
        _ variantID: String,
        status: MessageStatus,
        interruptionReason: String?
    ) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE message_variants
                SET status = ?, interruption_reason = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [status.rawValue, interruptionReason, now, variantID]
            )
            try syncActiveMessageContent(db, variantID: variantID, status: status.rawValue, date: now)
        }
    }

    private func syncActiveMessageContent(
        _ db: Database,
        variantID: String,
        status: String?,
        date: Date
    ) throws {
        guard let variant = try MessageVariantRecord.fetchOne(db, key: variantID) else {
            return
        }
        let nextStatus = status ?? variant.status
        try db.execute(
            sql: """
            UPDATE messages
            SET content = ?, status = ?, updated_at = ?
            WHERE id = ? AND active_variant_id = ?
            """,
            arguments: [variant.content, nextStatus, date, variant.messageID, variantID]
        )
        if let message = try MessageRecord.fetchOne(db, key: variant.messageID) {
            try touchChat(db, chatID: message.chatID, date: date)
        }
    }

    private func touchChat(_ db: Database, chatID: String, date: Date) throws {
        try db.execute(sql: "UPDATE chats SET updated_at = ? WHERE id = ?", arguments: [date, chatID])
    }
}
