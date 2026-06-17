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

    /// Sampling parameters that give each preset its character. The runtime
    /// reads only `temperature`/`topP`, so a preset that didn't set them would
    /// be an inert label; the settings flow applies these when the preset
    /// changes. `precise` matches the historical defaults, so the default
    /// preset is behaviour-preserving.
    public var samplingParameters: (temperature: Double, topP: Double) {
        switch self {
        case .extractive: (0.0, 1.0)   // deterministic: verbatim extraction
        case .precise:    (0.2, 0.8)   // careful, low variance (default)
        case .balanced:   (0.5, 0.9)
        case .drafting:   (0.7, 0.95)  // more fluent prose for drafting
        }
    }
}
