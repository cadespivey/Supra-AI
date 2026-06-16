import Foundation
import SupraCore

public struct GenerateRequest: Codable, Sendable {
    public let generationID: GenerationID
    public let modelID: ModelID
    public let prompt: String
    public let systemPrompt: String?
    public let options: GenerationOptions

    public init(
        generationID: GenerationID,
        modelID: ModelID,
        prompt: String,
        systemPrompt: String?,
        options: GenerationOptions
    ) {
        self.generationID = generationID
        self.modelID = modelID
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.options = options
    }
}
