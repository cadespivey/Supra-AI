import Foundation

/// One result of a tag/content search across chats and ScratchPad notes, grouped by
/// matter for display. Chat hits in the current scope carry an `openableChatID` (tap
/// to open); cross-matter and note hits are discovery-only (shown with their matter
/// and date).
public struct TagSearchHit: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case chat, note }

    public let id: String
    public let kind: Kind
    /// Set when this chat belongs to the current scope and can be opened in place.
    public let openableChatID: String?
    /// Display group: a matter name, "Global chats", or "Unassigned notes".
    public let group: String
    public let title: String
    public let snippet: String
    public let date: Date?

    public init(
        id: String,
        kind: Kind,
        openableChatID: String?,
        group: String,
        title: String,
        snippet: String,
        date: Date?
    ) {
        self.id = id
        self.kind = kind
        self.openableChatID = openableChatID
        self.group = group
        self.title = title
        self.snippet = snippet
        self.date = date
    }
}
