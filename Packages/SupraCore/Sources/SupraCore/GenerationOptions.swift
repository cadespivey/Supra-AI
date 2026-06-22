public struct GenerationOptions: Codable, Hashable, Sendable {
    public var preset: GenerationPreset
    public var temperature: Double
    public var topP: Double
    public var topK: Int?
    public var maxContextTokens: Int
    public var maxOutputTokens: Int
    public var thinkingBudget: ThinkingBudget

    public init(
        preset: GenerationPreset = .precise,
        temperature: Double = 0.2,
        topP: Double = 0.8,
        topK: Int? = nil,
        maxContextTokens: Int = 32_768,
        maxOutputTokens: Int = 1024,
        thinkingBudget: ThinkingBudget = .off
    ) {
        self.preset = preset
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.thinkingBudget = thinkingBudget
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case temperature
        case topP
        case topK
        case maxContextTokens
        case maxOutputTokens
        case thinkingBudget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try container.decodeIfPresent(GenerationPreset.self, forKey: .preset) ?? .precise
        let defaults = preset.defaultOptions

        self.preset = preset
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
        // Distinguish "topK key absent" (legacy data → fall back to preset default)
        // from "topK encoded as null" (an explicit nil the user chose, which we
        // round-trip faithfully). `encode(to:)` always writes the key, so anything
        // we wrote keeps its exact topK, including nil.
        self.topK = container.contains(.topK)
            ? try container.decode(Int?.self, forKey: .topK)
            : defaults.topK
        self.maxContextTokens = try container.decodeIfPresent(Int.self, forKey: .maxContextTokens) ?? defaults.maxContextTokens
        self.maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? defaults.maxOutputTokens
        self.thinkingBudget = try container.decodeIfPresent(ThinkingBudget.self, forKey: .thinkingBudget) ?? defaults.thinkingBudget
    }

    /// Coerces sampling/budget parameters into safe ranges. Applied at the runtime
    /// boundary so a malformed or hostile request (NaN, negative, or absurd values
    /// that crossed XPC) can never reach the MLX generator. Coercion (not rejection)
    /// keeps a slightly-off preset runnable.
    public func clampedForRuntime() -> GenerationOptions {
        var copy = self
        copy.temperature = temperature.isFinite ? min(max(temperature, 0), 2) : 0.2
        copy.topP = topP.isFinite ? min(max(topP, 0), 1) : 1.0
        copy.topK = topK.map { max(0, $0) }
        copy.maxOutputTokens = min(max(maxOutputTokens, 1), 16_384)
        copy.maxContextTokens = min(max(maxContextTokens, 1), 1_048_576)
        return copy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topP, forKey: .topP)
        // Always write topK (null when nil) so the decoder can tell an explicit
        // nil from a missing key — see init(from:).
        try container.encode(topK, forKey: .topK)
        try container.encode(maxContextTokens, forKey: .maxContextTokens)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(thinkingBudget, forKey: .thinkingBudget)
    }
}

public enum GenerationPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case balanced
    case precise
    case drafting
    case extractive
    case legalReasoning = "legal_reasoning"
    case legalResearch = "legal_research"
    case legalCritique = "legal_critique"
    case legalVerify = "legal_verify"

    public static let userSelectableDefaults: [GenerationPreset] = [
        .balanced,
        .precise,
        .drafting,
        .extractive
    ]

    /// Sampling parameters that give each preset its character. The runtime
    /// historically read only `temperature`/`topP`, so the settings flow applies
    /// these when the preset changes. `precise` matches the historical defaults,
    /// so the default preset is behaviour-preserving.
    public var samplingParameters: (temperature: Double, topP: Double) {
        let parameters = generationParameters
        return (parameters.temperature, parameters.topP)
    }

    public var defaultOptions: GenerationOptions {
        let parameters = generationParameters
        return GenerationOptions(
            preset: self,
            temperature: parameters.temperature,
            topP: parameters.topP,
            topK: parameters.topK,
            maxContextTokens: parameters.maxContextTokens,
            maxOutputTokens: parameters.maxOutputTokens,
            thinkingBudget: parameters.thinkingBudget
        )
    }

    public var displayName: String {
        switch self {
        case .balanced: "Balanced"
        case .precise: "Precise"
        case .drafting: "Drafting"
        case .extractive: "Extractive"
        case .legalReasoning: "Legal Reasoning"
        case .legalResearch: "Legal Research"
        case .legalCritique: "Legal Critique"
        case .legalVerify: "Legal Verify"
        }
    }

    private var generationParameters: (
        temperature: Double,
        topP: Double,
        topK: Int?,
        maxContextTokens: Int,
        maxOutputTokens: Int,
        thinkingBudget: ThinkingBudget
    ) {
        switch self {
        case .extractive:
            (0.0, 1.0, nil, 32_768, 1024, .off)
        case .precise:
            (0.2, 0.8, nil, 32_768, 1024, .off)
        case .balanced:
            (0.5, 0.9, nil, 32_768, 2048, .off)
        case .drafting:
            (0.45, 0.95, 40, 32_768, 5000, .lowOrOff)
        case .legalReasoning:
            (0.2, 0.9, 30, 32_768, 4096, .medium)
        case .legalResearch:
            (0.15, 0.85, 20, 65_536, 6000, .high)
        case .legalCritique:
            (0.2, 0.9, 30, 32_768, 3000, .medium)
        case .legalVerify:
            // Verification must be reproducible: greedy decoding (temp 0, no nucleus/
            // top-k truncation) removes run-to-run variance and the marginal-sampling
            // fabrication risk on the task whose entire job is checking citations.
            (0.0, 1.0, nil, 32_768, 3000, .medium)
        }
    }
}

public enum ThinkingBudget: String, Codable, Hashable, Sendable, CaseIterable {
    case off
    case lowOrOff = "low_or_off"
    case low
    case medium
    case high

    public var enablesModelThinking: Bool {
        switch self {
        case .off, .lowOrOff:
            false
        case .low, .medium, .high:
            true
        }
    }
}
