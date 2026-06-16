public enum ValidationRunStatus: String, Codable, Sendable {
    case passed
    case partial
    case failed
    case cancelled
}

public enum ValidationTestStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case skipped
    case cancelled
}
