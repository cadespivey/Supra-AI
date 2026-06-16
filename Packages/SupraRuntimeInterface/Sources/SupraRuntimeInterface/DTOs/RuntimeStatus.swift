import Foundation
import SupraCore

public struct RuntimeStatus: Codable, Sendable {
    public let state: RuntimeServiceState
    public let loadedModelID: ModelID?
    public let activeGenerationID: GenerationID?
    public let message: String?
    public let metrics: RuntimeMetrics?

    public init(
        state: RuntimeServiceState,
        loadedModelID: ModelID?,
        activeGenerationID: GenerationID?,
        message: String?,
        metrics: RuntimeMetrics?
    ) {
        self.state = state
        self.loadedModelID = loadedModelID
        self.activeGenerationID = activeGenerationID
        self.message = message
        self.metrics = metrics
    }
}

public enum RuntimeServiceState: String, Codable, Sendable {
    case disconnected
    case starting
    case connected
    case modelUnloaded
    case modelLoading
    case modelLoaded
    case generating
    case cancelling
    case failed
    case restarting
}
