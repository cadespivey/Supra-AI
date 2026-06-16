import Foundation
import SupraCore

public struct LoadModelRequest: Codable, Sendable {
    public let modelID: ModelID
    public let modelPath: String
    public let displayName: String

    public init(modelID: ModelID, modelPath: String, displayName: String) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.displayName = displayName
    }
}
