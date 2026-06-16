public struct GenerationOptions: Codable, Hashable, Sendable {
    public var preset: GenerationPreset
    public var temperature: Double
    public var topP: Double
    public var maxOutputTokens: Int
    public var contextLength: Int?

    public init(
        preset: GenerationPreset = .precise,
        temperature: Double = 0.2,
        topP: Double = 0.8,
        maxOutputTokens: Int = 1024,
        contextLength: Int? = nil
    ) {
        self.preset = preset
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.contextLength = contextLength
    }
}

public enum GenerationPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case balanced
    case precise
    case drafting
    case extractive
}
