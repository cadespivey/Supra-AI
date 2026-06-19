import Foundation

public struct RuntimeMetrics: Codable, Sendable {
    public let loadTimeMs: Int?
    public let firstTokenLatencyMs: Int?
    public let tokensPerSecond: Double?
    public let cancellationLatencyMs: Int?
    public let peakMemoryMb: Int?
    public let generatedTokenCount: Int?
    /// True when generation stopped because it hit the output-token cap rather
    /// than the model's natural stop. Lets callers tell a truncated reasoning trace
    /// from a finished answer.
    public let truncated: Bool?
    /// True when the loaded model actually had reasoning active for this run
    /// (its chat template honors `enable_thinking` AND the preset enabled it). Only
    /// then does a missing `</think>` imply a truncated reasoning trace — a plain
    /// model produces no think block regardless of the requested budget.
    public let reasoningActive: Bool?

    public init(
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil,
        truncated: Bool? = nil,
        reasoningActive: Bool? = nil
    ) {
        self.loadTimeMs = loadTimeMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
        self.cancellationLatencyMs = cancellationLatencyMs
        self.peakMemoryMb = peakMemoryMb
        self.generatedTokenCount = generatedTokenCount
        self.truncated = truncated
        self.reasoningActive = reasoningActive
    }
}
