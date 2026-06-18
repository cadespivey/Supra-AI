import Foundation
import SupraCore

public struct CancelGenerationResponse: Codable, Sendable {
    public let status: CancelGenerationStatus
    public let generationID: GenerationID
    public let metrics: RuntimeMetrics?
    public let error: RuntimeError?

    public init(
        status: CancelGenerationStatus,
        generationID: GenerationID,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) {
        self.status = status
        self.generationID = generationID
        self.metrics = metrics
        self.error = error
    }
}

public enum CancelGenerationStatus: String, Codable, Sendable {
    case cancelled
    case notFound
    /// Reserved wire status for a cancel that errored; not currently produced by the service.
    case failed
}
