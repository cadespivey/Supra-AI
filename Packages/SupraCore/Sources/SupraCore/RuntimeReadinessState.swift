public enum RuntimeReadinessState: String, Codable, Sendable {
    case unavailable
    case limited
    case chatReady
    case embeddingsReady
    case fullyReady
    case degraded
}
