import Foundation

public struct StoredRuntimeMetrics: Codable, Hashable, Sendable {
    public var loadTimeMs: Int?
    public var firstTokenLatencyMs: Int?
    public var tokensPerSecond: Double?
    public var cancellationLatencyMs: Int?
    public var peakMemoryMb: Int?
    public var generatedTokenCount: Int?

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
