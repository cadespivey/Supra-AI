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

    public func createMatterChat(matterID: String, title: String) throws -> ChatRecord {
        try writer.write { db in
            let record = ChatRecord(title: title, scope: "matter", matterID: matterID)
            try record.insert(db)
            return record
        }
    }

    public func fetchMatterChats(matterID: String) throws -> [ChatRecord] {
        try writer.read { db in
            try ChatRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM chats
                WHERE scope = 'matter' AND matter_id = ? AND deleted_at IS NULL
                ORDER BY updated_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    /// Renames a chat (used by the chat-history sidebar). Touches `updated_at` so
    /// the row keeps its place in the most-recent-first ordering.
    public func renameChat(id: String, title: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE chats SET title = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [title, now, id]
            )
        }
    }

    /// Soft-deletes a chat (sets `deleted_at`). Its messages stay in place — every
    /// fetch already filters on `deleted_at IS NULL`, so the chat simply disappears
    /// from the list. Returns `false` if no live chat with that id exists, so the
    /// caller can avoid acting on a delete that didn't happen.
    @discardableResult
    public func softDeleteChat(id: String, deletedAt: Date = Date()) throws -> Bool {
        try writer.write { db in
            guard try ChatRecord.fetchOne(
                db,
                sql: "SELECT * FROM chats WHERE id = ? AND deleted_at IS NULL",
                arguments: [id]
            ) != nil else {
                return false
            }
            try db.execute(
                sql: "UPDATE chats SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [deletedAt, deletedAt, id]
            )
            return true
        }
    }

    /// Re-homes a global chat into a matter. Messages reference the chat by id, so
    /// they follow it automatically; only the chat's scope/owner changes. Validates
    /// that both the chat and target matter still exist and returns the updated
    /// record (or `nil` if either is gone), so the caller never records a move that
    /// didn't actually happen.
    @discardableResult
    public func moveChatToMatter(id: String, matterID: String, movedAt: Date = Date()) throws -> ChatRecord? {
        try writer.write { db in
            guard try MatterRecord.fetchOne(
                db,
                sql: "SELECT * FROM matters WHERE id = ? AND deleted_at IS NULL",
                arguments: [matterID]
            ) != nil else {
                return nil
            }
            guard try ChatRecord.fetchOne(
                db,
                sql: "SELECT * FROM chats WHERE id = ? AND deleted_at IS NULL",
                arguments: [id]
            ) != nil else {
                return nil
            }
            try db.execute(
                sql: """
                UPDATE chats
                SET scope = 'matter', matter_id = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [matterID, movedAt, id]
            )
            return try ChatRecord.fetchOne(db, key: id)
        }
    }

    /// A chat matched by a content/tag search, with a sample matching-message snippet.
    public struct ChatSearchHit: Sendable, Equatable {
        public let chatID: String
        public let title: String
        public let scope: String
        public let matterID: String?
        /// The first matching message's content (nil when matched only by title).
        public let snippet: String?
        public let updatedAt: Date
    }

    /// Finds live chats whose title OR any message content contains `term`
    /// (case-insensitive). When `matterID` is given, restricts to that matter's chats;
    /// otherwise spans every scope (global + all matters). Powers tag/content search.
    public func searchChats(term: String, matterID: String? = nil, limit: Int = 200) throws -> [ChatSearchHit] {
        let like = "%\(Self.escapeLike(term))%"
        return try writer.read { db in
            var arguments: [DatabaseValueConvertible] = [like, like, like]
            var matterClause = ""
            if let matterID {
                matterClause = "AND c.matter_id = ?"
                arguments.append(matterID)
            }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.title AS title, c.scope AS scope, c.matter_id AS matter_id, c.updated_at AS updated_at,
                  (SELECT m2.content FROM messages m2
                   WHERE m2.chat_id = c.id AND m2.deleted_at IS NULL AND m2.content LIKE ? ESCAPE '\\'
                   ORDER BY m2.created_at ASC LIMIT 1) AS snippet
                FROM chats c
                WHERE c.deleted_at IS NULL
                  AND (c.title LIKE ? ESCAPE '\\'
                       OR EXISTS (SELECT 1 FROM messages m WHERE m.chat_id = c.id AND m.deleted_at IS NULL AND m.content LIKE ? ESCAPE '\\'))
                  \(matterClause)
                ORDER BY c.updated_at DESC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.map { row in
                ChatSearchHit(
                    chatID: row["id"], title: row["title"], scope: row["scope"],
                    matterID: row["matter_id"], snippet: row["snippet"], updatedAt: row["updated_at"]
                )
            }
        }
    }

    /// Escapes LIKE metacharacters so a literal `%`/`_`/`\` in a search term doesn't
    /// act as a wildcard (used with `ESCAPE '\'`).
    private static func escapeLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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

    /// Replaces the inline citations for a message (delete-then-insert in one write),
    /// so re-finalizing a regenerated message doesn't leave orphan rows.
    public func replaceCitations(messageID: String, _ citations: [MessageCitationRecord]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM message_citations WHERE message_id = ?", arguments: [messageID])
            for citation in citations {
                var row = citation
                row.messageID = messageID
                try row.insert(db)
            }
        }
    }

    /// The persisted inline citations for a message, ordered by rank ([A1], [A2], …).
    public func fetchCitations(messageID: String) throws -> [MessageCitationRecord] {
        try writer.read { db in
            try MessageCitationRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM message_citations
                WHERE message_id = ?
                ORDER BY rank ASC
                """,
                arguments: [messageID]
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

    public func markVariantFailed(_ variantID: String, reason: String) throws {
        try updateVariantStatus(variantID, status: .failed, interruptionReason: reason)
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
