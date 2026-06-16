import Foundation
import SupraCore

public struct GenerateStartResponse: Codable, Sendable {
    public let status: GenerateStartStatus
    public let generationID: GenerationID
    public let error: RuntimeError?

    public init(
        status: GenerateStartStatus,
        generationID: GenerationID,
        error: RuntimeError? = nil
    ) {
        self.status = status
        self.generationID = generationID
        self.error = error
    }
}

public enum GenerateStartStatus: String, Codable, Sendable {
    case started
    case busy
    case modelNotLoaded
    case invalidRequest
    case failed
}
