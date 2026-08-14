import Foundation
import GRDB
import SupraCore

/// Persists Document Intelligence setup state and the embedding-model catalog
/// (Milestone 3). Setup state is a single row; embedding models are a small set.
public final class DocumentSettingsRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Setup state

    /// Reads the singleton setup row, creating an empty one if absent.
    @discardableResult
    public func loadSettings() throws -> DocumentIntelligenceSettingsRecord {
        try writer.write { db in
            if let existing = try DocumentIntelligenceSettingsRecord.fetchOne(
                db,
                key: DocumentIntelligenceSettingsRecord.singletonID
            ) {
                return existing
            }
            let record = DocumentIntelligenceSettingsRecord()
            try record.insert(db)
            return record
        }
    }

    /// Applies a mutation to the singleton setup row, stamping `updatedAt`.
    @discardableResult
    public func updateSettings(
        _ mutate: (inout DocumentIntelligenceSettingsRecord) -> Void
    ) throws -> DocumentIntelligenceSettingsRecord {
        try writer.write { db in
            var record = try DocumentIntelligenceSettingsRecord.fetchOne(
                db,
                key: DocumentIntelligenceSettingsRecord.singletonID
            ) ?? DocumentIntelligenceSettingsRecord()
            mutate(&record)
            record.updatedAt = Date()
            try record.save(db)
            return record
        }
    }

    /// Marks setup as needing review (invalidated) with a reason and clears the
    /// completion timestamp.
    public func invalidateSetup(reason: String) throws {
        try updateSettings { settings in
            settings.setupInvalidatedReason = reason
            settings.setupCompletedAt = nil
        }
    }

    // MARK: - Embedding models

    public func upsertEmbeddingModel(_ model: DocumentEmbeddingModelRecord) throws {
        try writer.write { db in
            try model.save(db)
        }
    }

    public func fetchEmbeddingModels() throws -> [DocumentEmbeddingModelRecord] {
        try writer.read { db in
            try DocumentEmbeddingModelRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_embedding_models ORDER BY display_name COLLATE NOCASE ASC"
            )
        }
    }

    public func fetchEmbeddingModel(id: String) throws -> DocumentEmbeddingModelRecord? {
        try writer.read { db in
            try DocumentEmbeddingModelRecord.fetchOne(db, key: id)
        }
    }

    public func fetchSelectedEmbeddingModel() throws -> DocumentEmbeddingModelRecord? {
        try writer.read { db in
            try DocumentEmbeddingModelRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_embedding_models WHERE is_selected = 1 LIMIT 1"
            )
        }
    }

    /// Marks one embedding model as the selected default, clearing the flag on
    /// all others. Also records the selection on the setup row.
    public func selectEmbeddingModel(id: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE document_embedding_models SET is_selected = (id = ?), updated_at = ?",
                arguments: [id, now]
            )
            try db.execute(
                sql: """
                UPDATE document_intelligence_settings
                SET selected_embedding_model_id = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [id, now, DocumentIntelligenceSettingsRecord.singletonID]
            )
        }
    }

    /// Atomically selects one model only while its immutable identity and
    /// successful load-test timestamp still match the caller's observation.
    /// The legacy id-only selector remains available to existing callers.
    public func activateVerifiedEmbeddingModel(
        _ command: DocumentVerifiedEmbeddingModelSelectionCommand
    ) throws -> DocumentVerifiedEmbeddingModelSelectionReceipt {
        try writer.write { database in
            guard var settings = try DocumentIntelligenceSettingsRecord.fetchOne(
                database,
                key: DocumentIntelligenceSettingsRecord.singletonID
            ) else {
                throw DocumentReadinessTransitionError.settingsNotFound
            }
            guard let model = try DocumentEmbeddingModelRecord.fetchOne(
                database,
                key: command.expectedModel.id
            ) else {
                throw DocumentReadinessTransitionError.modelNotFound(command.expectedModel.id)
            }
            let persistedIdentity = DocumentReadinessEmbeddingModelIdentity(
                id: model.id,
                repoID: model.repoID,
                revision: model.revision,
                dimension: model.dimension
            )
            guard persistedIdentity == command.expectedModel,
                  model.dimension > 0 else {
                throw DocumentReadinessTransitionError.modelIdentityChanged(model.id)
            }
            guard model.lastTestLoadResult == "passed",
                  model.lastTestLoadAt != nil else {
                throw DocumentReadinessTransitionError.modelNotVerified(model.id)
            }
            guard model.lastTestLoadAt == command.verifiedAt else {
                throw DocumentReadinessTransitionError.modelVerificationChanged(model.id)
            }
            guard !command.setupInvalidationReason
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DocumentReadinessTransitionError.modelSelectionInconsistent(model.id)
            }

            let now = Date()
            try database.execute(
                sql: """
                    UPDATE document_embedding_models
                    SET is_selected = (id = ?), updated_at = ?
                    """,
                arguments: [model.id, now]
            )
            settings.selectedEmbeddingModelID = model.id
            settings.embeddingModelLastTestedAt = command.verifiedAt
            settings.setupCompletedAt = nil
            settings.setupInvalidatedReason = command.setupInvalidationReason
            settings.updatedAt = now
            try settings.update(database)

            let selectedIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id
                    FROM document_embedding_models
                    WHERE is_selected = 1
                    ORDER BY id
                    """
            )
            guard selectedIDs == [model.id] else {
                throw DocumentReadinessTransitionError.modelSelectionInconsistent(model.id)
            }
            return DocumentVerifiedEmbeddingModelSelectionReceipt(
                activeModel: persistedIdentity,
                verifiedAt: command.verifiedAt,
                setupInvalidationReason: command.setupInvalidationReason
            )
        }
    }

    public func recordTestLoad(
        modelID: String,
        at date: Date = Date(),
        result: String
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE document_embedding_models
                SET last_test_load_at = ?, last_test_load_result = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [date, result, date, modelID]
            )
        }
    }
}
