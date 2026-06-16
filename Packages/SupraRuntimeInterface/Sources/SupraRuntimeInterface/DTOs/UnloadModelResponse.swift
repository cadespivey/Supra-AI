import Foundation

public struct UnloadModelResponse: Codable, Sendable {
    public let status: UnloadModelStatus
    public let metrics: RuntimeMetrics?
    public let error: RuntimeError?

    public init(
        status: UnloadModelStatus,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) {
        self.status = status
        self.metrics = metrics
        self.error = error
    }
}

public enum UnloadModelStatus: String, Codable, Sendable {
    case unloaded
    case noModelLoaded
    case failed
}
