import Foundation

/// Which collection of chats a `GlobalChatController` operates on: the global
/// list, or the chats belonging to a specific matter.
public enum ChatScope: Sendable, Equatable {
    case global
    case matter(id: String)
}
