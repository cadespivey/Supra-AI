import Foundation
import GRDB
import SupraCore

public final class GenerationRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createGenerationSession(
        chatID: String,
        messageID: String,
        variantID: String? = nil,
        modelID: String? = nil,
        prompt: String,
        systemPrompt: String? = nil,
        options: GenerationOptions
    ) throws -> GenerationSessionRecord {
        let optionsJSON = try JSONCoding.encode(options)
        return try writer.write { db in
            let now = Date()
            let record = GenerationSessionRecord(
                chatID: chatID,
                messageID: messageID,
                variantID: variantID,
                modelID: modelID,
                prompt: prompt,
                systemPrompt: systemPrompt,
                optionsJSON: optionsJSON,
                status: MessageStatus.pending.rawValue,
                startedAt: now,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    /// Persists the completed generation audit record for a document artifact.
    /// A runtime model UUID is useful for diagnostics but is not stable lineage;
    /// the repository/revision pair and prompt builder version are mandatory.
    public func createDocumentGenerationSession(
        modelID: String? = nil,
        modelRepository: String,
        modelRevision: String,
        promptBuilderVersion: String,
        prompt: String,
        systemPrompt: String? = nil,
        options: GenerationOptions
    ) throws -> GenerationSessionRecord {
        try createDocumentGenerationSession(
            modelID: modelID,
            modelRepository: modelRepository,
            modelRevision: modelRevision,
            promptBuilderVersion: promptBuilderVersion,
            prompt: prompt,
            systemPrompt: systemPrompt,
            optionsJSON: JSONCoding.encode(options)
        )
    }

    public func createDocumentGenerationSession(
        modelID: String? = nil,
        modelRepository: String,
        modelRevision: String,
        promptBuilderVersion: String,
        prompt: String,
        systemPrompt: String? = nil,
        optionsJSON: String
    ) throws -> GenerationSessionRecord {
        let modelRepository = try Self.requireNonEmpty(
            modelRepository,
            fieldName: "model_repository"
        )
        let modelRevision = try Self.requireNonEmpty(
            modelRevision,
            fieldName: "model_revision"
        )
        let promptBuilderVersion = try Self.requireNonEmpty(
            promptBuilderVersion,
            fieldName: "prompt_builder_version"
        )
        let prompt = try Self.requireNonEmpty(prompt, fieldName: "prompt")
        guard let optionsData = optionsJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: optionsData)) != nil else {
            throw GenerationRepositoryError.invalidOptionsJSON
        }
        return try writer.write { db in
            let now = Date()
            let record = GenerationSessionRecord(
                modelID: modelID,
                modelRepository: modelRepository,
                modelRevision: modelRevision,
                promptBuilderVersion: promptBuilderVersion,
                prompt: prompt,
                systemPrompt: systemPrompt,
                optionsJSON: optionsJSON,
                status: MessageStatus.completed.rawValue,
                startedAt: now,
                completedAt: now,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    public func linkVariant(generationID: String, variantID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE generation_sessions SET variant_id = ?, updated_at = ? WHERE id = ?",
                arguments: [variantID, Date(), generationID]
            )
        }
    }

    public func fetchGenerationSession(generationID: String) throws -> GenerationSessionRecord? {
        try writer.read { db in
            try GenerationSessionRecord.fetchOne(db, key: generationID)
        }
    }

    public func fetchGenerationSessions(chatID: String, limit: Int? = nil) throws -> [GenerationSessionRecord] {
        try writer.read { db in
            if let limit {
                return try GenerationSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM generation_sessions
                    WHERE chat_id = ?
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                    arguments: [chatID, max(0, limit)]
                )
            }

            return try GenerationSessionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM generation_sessions
                WHERE chat_id = ?
                ORDER BY created_at DESC
                """,
                arguments: [chatID]
            )
        }
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw GenerationRepositoryError.requiredFieldMissing(fieldName)
        }
        return normalized
    }

    public func markFirstToken(generationID: String, date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE generation_sessions
                SET first_token_at = ?, updated_at = ?
                WHERE id = ? AND first_token_at IS NULL
                """,
                arguments: [date, Date(), generationID]
            )
        }
    }

    public func completeGeneration(generationID: String, metrics: StoredRuntimeMetrics = StoredRuntimeMetrics()) throws {
        try finishGeneration(
            generationID: generationID,
            status: .completed,
            metrics: metrics,
            errorSummary: nil,
            interruptionReason: nil,
            diagnosticEventID: nil
        )
    }

    public func cancelGeneration(generationID: String, metrics: StoredRuntimeMetrics = StoredRuntimeMetrics()) throws {
        try finishGeneration(
            generationID: generationID,
            status: .cancelled,
            metrics: metrics,
            errorSummary: nil,
            interruptionReason: nil,
            diagnosticEventID: nil
        )
    }

    public func interruptGeneration(
        generationID: String,
        reason: String,
        diagnosticEventID: String?
    ) throws {
        try finishGeneration(
            generationID: generationID,
            status: .interrupted,
            metrics: StoredRuntimeMetrics(),
            errorSummary: nil,
            interruptionReason: reason,
            diagnosticEventID: diagnosticEventID
        )
    }

    public func failGeneration(
        generationID: String,
        errorSummary: String,
        diagnosticEventID: String?
    ) throws {
        try finishGeneration(
            generationID: generationID,
            status: .failed,
            metrics: StoredRuntimeMetrics(),
            errorSummary: errorSummary,
            interruptionReason: nil,
            diagnosticEventID: diagnosticEventID
        )
    }

    private func finishGeneration(
        generationID: String,
        status: MessageStatus,
        metrics: StoredRuntimeMetrics,
        errorSummary: String?,
        interruptionReason: String?,
        diagnosticEventID: String?
    ) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                UPDATE generation_sessions
                SET status = ?,
                    completed_at = ?,
                    load_time_ms = ?,
                    first_token_latency_ms = ?,
                    tokens_per_second = ?,
                    cancellation_latency_ms = ?,
                    peak_memory_mb = ?,
                    generated_token_count = ?,
                    error_summary = ?,
                    interruption_reason = ?,
                    diagnostic_event_id = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status.rawValue,
                    now,
                    metrics.loadTimeMs,
                    metrics.firstTokenLatencyMs,
                    metrics.tokensPerSecond,
                    metrics.cancellationLatencyMs,
                    metrics.peakMemoryMb,
                    metrics.generatedTokenCount,
                    errorSummary,
                    interruptionReason,
                    diagnosticEventID,
                    now,
                    generationID
                ]
            )
        }
    }
}

public enum GenerationRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
    case invalidOptionsJSON
}
