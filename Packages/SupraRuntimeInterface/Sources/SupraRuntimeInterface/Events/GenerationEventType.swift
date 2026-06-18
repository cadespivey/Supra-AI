public enum GenerationEventType: String, Codable, Sendable {
    // Reserved lifecycle events: consumers handle them defensively, but the current
    // coordinator does not emit queued/modelLoading/modelLoaded during generation.
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
