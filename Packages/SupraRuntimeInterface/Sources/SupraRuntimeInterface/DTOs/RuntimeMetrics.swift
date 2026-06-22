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
    /// True when the assembled prompt exceeded the model's context window and the
    /// runtime had to drop the oldest conversation turns (or, if even the system
    /// prompt + current question overflow, could not fully fit it). Lets callers warn
    /// that earlier context was not in view rather than silently losing it.
    public let contextTrimmed: Bool?

    public init(
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil,
        truncated: Bool? = nil,
        reasoningActive: Bool? = nil,
        contextTrimmed: Bool? = nil
    ) {
        self.loadTimeMs = loadTimeMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
        self.cancellationLatencyMs = cancellationLatencyMs
        self.peakMemoryMb = peakMemoryMb
        self.generatedTokenCount = generatedTokenCount
        self.truncated = truncated
        self.reasoningActive = reasoningActive
        self.contextTrimmed = contextTrimmed
    }
}
