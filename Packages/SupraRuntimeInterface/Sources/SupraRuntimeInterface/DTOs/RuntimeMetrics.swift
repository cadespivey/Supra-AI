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
    /// True when the runtime dropped the oldest conversation turns to fit the prompt
    /// into the context window. Benign for one-shot grounded flows (the system prompt,
    /// question, and evidence are preserved); the chat surfaces it as a note.
    public let contextTrimmed: Bool?
    /// True when, even after dropping all history, the system prompt + current prompt
    /// (the grounding contract + evidence + question) still exceed the window — so the
    /// front of the prompt is evicted mid-generation and cannot be recovered. Grounded
    /// callers must refuse rather than return a confidently-ungrounded answer.
    public let contextOverflowed: Bool?

    public init(
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil,
        truncated: Bool? = nil,
        reasoningActive: Bool? = nil,
        contextTrimmed: Bool? = nil,
        contextOverflowed: Bool? = nil
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
        self.contextOverflowed = contextOverflowed
    }
}
