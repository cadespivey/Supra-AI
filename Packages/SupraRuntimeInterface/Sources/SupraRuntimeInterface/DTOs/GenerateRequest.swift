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
    /// Optional content identity required at generation admission. When present,
    /// the runtime must reject the request unless the currently loaded model was
    /// verified against this exact lowercase SHA-256 fingerprint.
    public let expectedModelSHA256: String?
    public let prompt: String
    public let systemPrompt: String?
    /// Prior turns (oldest→newest) prepended to the chat template so the model can
    /// answer follow-ups in context. Empty for a fresh conversation or a one-shot.
    public let history: [Turn]
    /// Declares whether context contains exact grounded evidence that must never
    /// be silently evicted by the rotating KV cache.
    public let contextWorkload: RuntimeContextWorkload
    /// True only when the caller can deterministically repack the same exact
    /// source set and retry after a bounded context-admission response.
    public let allowsExactSourceRepacking: Bool
    public let options: GenerationOptions

    public init(
        generationID: GenerationID,
        modelID: ModelID,
        expectedModelSHA256: String? = nil,
        prompt: String,
        systemPrompt: String?,
        history: [Turn] = [],
        contextWorkload: RuntimeContextWorkload = .ordinaryConversation,
        allowsExactSourceRepacking: Bool = false,
        options: GenerationOptions
    ) {
        self.generationID = generationID
        self.modelID = modelID
        self.expectedModelSHA256 = expectedModelSHA256
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.history = history
        self.contextWorkload = contextWorkload
        self.allowsExactSourceRepacking = allowsExactSourceRepacking
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generationID = try container.decode(GenerationID.self, forKey: .generationID)
        self.modelID = try container.decode(ModelID.self, forKey: .modelID)
        // Tolerate requests encoded before content-bound generation admission.
        self.expectedModelSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .expectedModelSHA256
        )
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        // Tolerate requests encoded before `history` existed.
        self.history = try container.decodeIfPresent([Turn].self, forKey: .history) ?? []
        self.contextWorkload = try container.decodeIfPresent(
            RuntimeContextWorkload.self,
            forKey: .contextWorkload
        ) ?? .ordinaryConversation
        self.allowsExactSourceRepacking = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsExactSourceRepacking
        ) ?? false
        self.options = try container.decode(GenerationOptions.self, forKey: .options)
    }
}
