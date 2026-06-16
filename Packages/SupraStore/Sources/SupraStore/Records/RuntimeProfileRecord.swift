import Foundation
import GRDB

public struct RuntimeProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "runtime_profiles"

    public var id: String
    public var modelID: String
    public var runtimeState: String
    public var loadTimeMs: Int?
    public var firstTokenLatencyMs: Int?
    public var tokensPerSecond: Double?
    public var cancellationLatencyMs: Int?
    public var peakMemoryMb: Int?
    public var generatedTokenCount: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        modelID: String,
        runtimeState: String,
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.modelID = modelID
        self.runtimeState = runtimeState
        self.loadTimeMs = loadTimeMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
        self.cancellationLatencyMs = cancellationLatencyMs
        self.peakMemoryMb = peakMemoryMb
        self.generatedTokenCount = generatedTokenCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID = "model_id"
        case runtimeState = "runtime_state"
        case loadTimeMs = "load_time_ms"
        case firstTokenLatencyMs = "first_token_latency_ms"
        case tokensPerSecond = "tokens_per_second"
        case cancellationLatencyMs = "cancellation_latency_ms"
        case peakMemoryMb = "peak_memory_mb"
        case generatedTokenCount = "generated_token_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
