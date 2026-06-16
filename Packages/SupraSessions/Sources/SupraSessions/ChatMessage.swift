import Foundation
import SupraCore
import SupraStore

/// A view-facing snapshot of a single chat message.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: MessageRole
    public var content: String
    public var status: MessageStatus

    public init(id: String, role: MessageRole, content: String, status: MessageStatus) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
    }

    init(record: MessageRecord) {
        self.init(
            id: record.id,
            role: MessageRole(rawValue: record.role) ?? .assistant,
            content: record.content,
            status: MessageStatus(rawValue: record.status) ?? .pending
        )
    }

    /// `true` while an assistant message is still being generated.
    public var isStreaming: Bool {
        role == .assistant && status == .pending
    }
}
