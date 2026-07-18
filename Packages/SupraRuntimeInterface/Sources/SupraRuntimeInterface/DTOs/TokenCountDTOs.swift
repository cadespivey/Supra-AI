import Foundation
import SupraCore

public struct CountTokensRequest: Codable, Equatable, Sendable {
    public var modelID: ModelID
    public var texts: [String]

    public init(modelID: ModelID, texts: [String]) {
        self.modelID = modelID
        self.texts = texts
    }
}

public struct CountTokensResponse: Codable, Equatable, Sendable {
    public var modelID: ModelID
    public var counts: [Int]
    public var error: RuntimeError?

    public init(
        modelID: ModelID,
        counts: [Int],
        error: RuntimeError? = nil
    ) {
        self.modelID = modelID
        self.counts = counts
        self.error = error
    }
}
