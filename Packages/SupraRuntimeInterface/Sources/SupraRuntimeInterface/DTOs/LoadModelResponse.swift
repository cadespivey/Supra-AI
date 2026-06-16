import Foundation
import SupraCore

public struct LoadModelResponse: Codable, Sendable {
    public let status: LoadModelStatus
    public let modelID: ModelID?
    public let metrics: RuntimeMetrics?
    public let error: RuntimeError?

    public init(
        status: LoadModelStatus,
        modelID: ModelID? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) {
        self.status = status
        self.modelID = modelID
        self.metrics = metrics
        self.error = error
    }
}

public enum LoadModelStatus: String, Codable, Sendable {
    case loaded
    case failed
}
