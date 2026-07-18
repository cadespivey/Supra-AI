import Foundation
import GRDB
import SupraCore

public struct GenerationSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "generation_sessions"

    public var id: String
    public var chatID: String?
    public var messageID: String?
    public var variantID: String?
    public var modelID: String?
    public var modelRepository: String?
    public var modelRevision: String?
    public var promptBuilderVersion: String?
    public var prompt: String
    public var systemPrompt: String?
    public var optionsJSON: String
    public var status: String
    public var startedAt: Date
    public var firstTokenAt: Date?
    public var completedAt: Date?
    public var loadTimeMs: Int?
    public var firstTokenLatencyMs: Int?
    public var tokensPerSecond: Double?
    public var cancellationLatencyMs: Int?
    public var peakMemoryMb: Int?
    public var generatedTokenCount: Int?
    public var errorSummary: String?
    public var interruptionReason: String?
    public var diagnosticEventID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        chatID: String? = nil,
        messageID: String? = nil,
        variantID: String? = nil,
        modelID: String? = nil,
        modelRepository: String? = nil,
        modelRevision: String? = nil,
        promptBuilderVersion: String? = nil,
        prompt: String,
        systemPrompt: String? = nil,
        optionsJSON: String,
        status: String = MessageStatus.pending.rawValue,
        startedAt: Date = Date(),
        firstTokenAt: Date? = nil,
        completedAt: Date? = nil,
        loadTimeMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        cancellationLatencyMs: Int? = nil,
        peakMemoryMb: Int? = nil,
        generatedTokenCount: Int? = nil,
        errorSummary: String? = nil,
        interruptionReason: String? = nil,
        diagnosticEventID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.chatID = chatID
        self.messageID = messageID
        self.variantID = variantID
        self.modelID = modelID
        self.modelRepository = modelRepository
        self.modelRevision = modelRevision
        self.promptBuilderVersion = promptBuilderVersion
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.optionsJSON = optionsJSON
        self.status = status
        self.startedAt = startedAt
        self.firstTokenAt = firstTokenAt
        self.completedAt = completedAt
        self.loadTimeMs = loadTimeMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
        self.cancellationLatencyMs = cancellationLatencyMs
        self.peakMemoryMb = peakMemoryMb
        self.generatedTokenCount = generatedTokenCount
        self.errorSummary = errorSummary
        self.interruptionReason = interruptionReason
        self.diagnosticEventID = diagnosticEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case messageID = "message_id"
        case variantID = "variant_id"
        case modelID = "model_id"
        case modelRepository = "model_repository"
        case modelRevision = "model_revision"
        case promptBuilderVersion = "prompt_builder_version"
        case prompt
        case systemPrompt = "system_prompt"
        case optionsJSON = "options_json"
        case status
        case startedAt = "started_at"
        case firstTokenAt = "first_token_at"
        case completedAt = "completed_at"
        case loadTimeMs = "load_time_ms"
        case firstTokenLatencyMs = "first_token_latency_ms"
        case tokensPerSecond = "tokens_per_second"
        case cancellationLatencyMs = "cancellation_latency_ms"
        case peakMemoryMb = "peak_memory_mb"
        case generatedTokenCount = "generated_token_count"
        case errorSummary = "error_summary"
        case interruptionReason = "interruption_reason"
        case diagnosticEventID = "diagnostic_event_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
