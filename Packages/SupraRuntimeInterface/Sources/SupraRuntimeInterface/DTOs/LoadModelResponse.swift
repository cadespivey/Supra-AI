import Foundation
import SupraCore

public struct LoadModelResponse: Codable, Sendable {
    public let status: LoadModelStatus
    public let modelID: ModelID?
    public let metrics: RuntimeMetrics?
    public let error: RuntimeError?
    /// Canonical SHA-256 the runtime independently verified before loading.
    /// Nil is retained for backward-compatible decoding of legacy responses.
    public let verifiedModelSHA256: String?

    public init(
        status: LoadModelStatus,
        modelID: ModelID? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil,
        verifiedModelSHA256: String? = nil
    ) {
        self.status = status
        self.modelID = modelID
        self.metrics = metrics
        self.error = error
        self.verifiedModelSHA256 = verifiedModelSHA256
    }
}

public enum LoadModelStatus: String, Codable, Sendable {
    case loaded
    case failed
}
