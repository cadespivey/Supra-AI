import Foundation

public struct RuntimeMetrics: Codable, Sendable {
    public let loadTimeMs: Int?
    public let firstTokenLatencyMs: Int?
    public let tokensPerSecond: Double?
    public let cancellationLatencyMs: Int?
    public let peakMemoryMb: Int?
    public let generatedTokenCount: Int?

    public init(
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil
    ) {
        self.loadTimeMs = loadTimeMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
        self.cancellationLatencyMs = cancellationLatencyMs
        self.peakMemoryMb = peakMemoryMb
        self.generatedTokenCount = generatedTokenCount
    }
}
