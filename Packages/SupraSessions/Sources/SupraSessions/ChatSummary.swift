import Foundation
import SupraStore

/// A view-facing snapshot of a global chat for the sidebar/list.
public struct ChatSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    init(record: ChatRecord) {
        self.init(id: record.id, title: record.title, updatedAt: record.updatedAt)
    }
}
