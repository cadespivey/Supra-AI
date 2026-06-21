import Foundation
import GRDB

public final class ModelRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsertModel(_ model: ModelRecord) throws {
        try writer.write { db in
            var model = model
            model.updatedAt = Date()
            try model.save(db)
        }
    }

    public func fetchModels() throws -> [ModelRecord] {
        try writer.read { db in
            try ModelRecord.fetchAll(
                db,
                sql: "SELECT * FROM models ORDER BY is_active DESC, display_name COLLATE NOCASE ASC"
            )
        }
    }

    public func fetchModel(id: String) throws -> ModelRecord? {
        try writer.read { db in
            try ModelRecord.fetchOne(db, key: id)
        }
    }

    /// Removes a model registration. Returns false if no row matched. Historical
    /// references that store the model's id as a plain string (generation sessions,
    /// validation runs) are intentionally left untouched — they're an audit trail,
    /// not foreign keys.
    @discardableResult
    public func deleteModel(id: String) throws -> Bool {
        try writer.write { db in
            try ModelRecord.deleteOne(db, key: id)
        }
    }

    public func setActiveModel(id: String) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE models SET is_active = 0, updated_at = ?", arguments: [now])
            try db.execute(sql: "UPDATE models SET is_active = 1, updated_at = ? WHERE id = ?", arguments: [now, id])
        }
    }

    public func updateValidationStatus(modelID: String, status: String, date: Date) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE models
                SET validation_status = ?, last_validated_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status, date, Date(), modelID]
            )
        }
    }
}
