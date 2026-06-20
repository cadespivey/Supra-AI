import Foundation
import SupraCore

public struct GenerateRequest: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    /// One prior conversation turn, so the model has context for follow-ups.
    public struct Turn: Codable, Sendable {
        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    public let generationID: GenerationID
    public let modelID: ModelID
    public let prompt: String
    public let systemPrompt: String?
    /// Prior turns (oldest→newest) prepended to the chat template so the model can
    /// answer follow-ups in context. Empty for a fresh conversation or a one-shot.
    public let history: [Turn]
    public let options: GenerationOptions

    public init(
        generationID: GenerationID,
        modelID: ModelID,
        prompt: String,
        systemPrompt: String?,
        history: [Turn] = [],
        options: GenerationOptions
    ) {
        self.generationID = generationID
        self.modelID = modelID
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.history = history
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generationID = try container.decode(GenerationID.self, forKey: .generationID)
        self.modelID = try container.decode(ModelID.self, forKey: .modelID)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        // Tolerate requests encoded before `history` existed.
        self.history = try container.decodeIfPresent([Turn].self, forKey: .history) ?? []
        self.options = try container.decode(GenerationOptions.self, forKey: .options)
    }
}
