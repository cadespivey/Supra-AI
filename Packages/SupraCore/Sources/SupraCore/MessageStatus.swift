public enum MessageStatus: String, Codable, Sendable {
    case pending
    case completed
    case cancelled
    case interrupted
    case failed
    case deleted
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}
