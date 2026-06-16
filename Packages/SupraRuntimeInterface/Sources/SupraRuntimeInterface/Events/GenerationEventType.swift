public enum GenerationEventType: String, Codable, Sendable {
    case queued
    case modelLoading
    case modelLoaded
    case generationStarted
    case token
    case generationCompleted
    case generationCancelled
    case generationFailed
    case metrics
}
