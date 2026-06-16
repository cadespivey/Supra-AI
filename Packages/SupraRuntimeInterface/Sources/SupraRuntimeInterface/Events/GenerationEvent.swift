import Foundation
import SupraCore

public struct GenerationEvent: Codable, Sendable {
    public let generationID: GenerationID
    public let sequenceNumber: Int
    public let timestamp: Date
    public let type: GenerationEventType
    public let tokenText: String?
    public let message: String?
    public let metrics: RuntimeMetrics?
    public let error: RuntimeError?

    public init(
        generationID: GenerationID,
        sequenceNumber: Int,
        timestamp: Date,
        type: GenerationEventType,
        tokenText: String? = nil,
        message: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) {
        self.generationID = generationID
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.type = type
        self.tokenText = tokenText
        self.message = message
        self.metrics = metrics
        self.error = error
    }
}
