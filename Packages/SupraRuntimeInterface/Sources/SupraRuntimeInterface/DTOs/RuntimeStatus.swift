import Foundation
import SupraCore

public struct RuntimeStatus: Codable, Sendable {
    public let state: RuntimeServiceState
    public let loadedModelID: ModelID?
    public let activeGenerationID: GenerationID?
    public let message: String?
    public let metrics: RuntimeMetrics?
    /// The loaded embedding model, if any (Milestone 3). Decodes as nil for
    /// statuses produced before embedding support existed.
    public let embeddingModelID: DocumentEmbeddingModelID?

    public init(
        state: RuntimeServiceState,
        loadedModelID: ModelID?,
        activeGenerationID: GenerationID?,
        message: String?,
        metrics: RuntimeMetrics?,
        embeddingModelID: DocumentEmbeddingModelID? = nil
    ) {
        self.state = state
        self.loadedModelID = loadedModelID
        self.activeGenerationID = activeGenerationID
        self.message = message
        self.metrics = metrics
        self.embeddingModelID = embeddingModelID
    }

    private enum CodingKeys: String, CodingKey {
        case state, loadedModelID, activeGenerationID, message, metrics, embeddingModelID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(RuntimeServiceState.self, forKey: .state)
        loadedModelID = try container.decodeIfPresent(ModelID.self, forKey: .loadedModelID)
        activeGenerationID = try container.decodeIfPresent(GenerationID.self, forKey: .activeGenerationID)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        metrics = try container.decodeIfPresent(RuntimeMetrics.self, forKey: .metrics)
        embeddingModelID = try container.decodeIfPresent(DocumentEmbeddingModelID.self, forKey: .embeddingModelID)
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
