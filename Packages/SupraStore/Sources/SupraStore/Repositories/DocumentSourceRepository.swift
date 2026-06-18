import Foundation
import GRDB
import SupraCore

/// Owns version-scoped source sets, cited output sources, and export records for
/// generated document outputs (Milestone 3). Each generated output version has
/// its own source set so older versions retain their original citations.
public final class DocumentSourceRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Source sets

    @discardableResult
    public func createSourceSet(
        matterID: String,
        mode: DocumentSourceSetMode,
        scopeJSON: String = "{}",
        retrievalQuery: String? = nil,
        structuredOutputVersionID: String? = nil,
        status: DocumentSourceSetStatus = .pending
    ) throws -> DocumentSourceSetRecord {
        try writer.write { db in
            let record = DocumentSourceSetRecord(
                matterID: matterID,
                structuredOutputVersionID: structuredOutputVersionID,
                status: status.rawValue,
                mode: mode.rawValue,
                scopeJSON: scopeJSON,
                retrievalQuery: retrievalQuery
            )
            try record.insert(db)
            return record
        }
    }

    /// Attaches a pending source set (and its source rows) to a generated output
    /// version, marking it `attached`.
    public func attachSourceSet(id: String, structuredOutputVersionID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE document_source_sets
                SET structured_output_version_id = ?, status = ?
                WHERE id = ?
                """,
                arguments: [structuredOutputVersionID, DocumentSourceSetStatus.attached.rawValue, id]
            )
            try db.execute(
                sql: """
                UPDATE document_output_sources
                SET structured_output_version_id = ?
                WHERE source_set_id = ?
                """,
                arguments: [structuredOutputVersionID, id]
            )
        }
    }

    public func fetchSourceSet(id: String) throws -> DocumentSourceSetRecord? {
        try writer.read { db in try DocumentSourceSetRecord.fetchOne(db, key: id) }
    }

    public func fetchSourceSet(structuredOutputVersionID: String) throws -> DocumentSourceSetRecord? {
        try writer.read { db in
            try DocumentSourceSetRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM document_source_sets
                WHERE structured_output_version_id = ? AND status = ?
                ORDER BY created_at DESC LIMIT 1
                """,
                arguments: [structuredOutputVersionID, DocumentSourceSetStatus.attached.rawValue]
            )
        }
    }

    // MARK: - Cited output sources

    public func addOutputSource(_ source: DocumentOutputSourceRecord) throws {
        try writer.write { db in try source.insert(db) }
    }

    public func addOutputSources(_ sources: [DocumentOutputSourceRecord]) throws {
        try writer.write { db in
            for source in sources {
                try source.insert(db)
            }
        }
    }

    public func fetchSources(sourceSetID: String) throws -> [DocumentOutputSourceRecord] {
        try writer.read { db in
            try DocumentOutputSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_output_sources WHERE source_set_id = ? ORDER BY rank ASC",
                arguments: [sourceSetID]
            )
        }
    }

    public func fetchSources(structuredOutputVersionID: String) throws -> [DocumentOutputSourceRecord] {
        try writer.read { db in
            try DocumentOutputSourceRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_output_sources
                WHERE structured_output_version_id = ?
                ORDER BY rank ASC
                """,
                arguments: [structuredOutputVersionID]
            )
        }
    }

    // MARK: - Exports

    @discardableResult
    public func recordExport(_ export: DocumentExportRecord) throws -> DocumentExportRecord {
        try writer.write { db in
            try export.insert(db)
            return export
        }
    }

    public func fetchExports(structuredOutputID: String) throws -> [DocumentExportRecord] {
        try writer.read { db in
            try DocumentExportRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_exports WHERE structured_output_id = ? ORDER BY created_at DESC",
                arguments: [structuredOutputID]
            )
        }
    }

    public func fetchExports(matterID: String) throws -> [DocumentExportRecord] {
        try writer.read { db in
            try DocumentExportRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_exports WHERE matter_id = ? ORDER BY created_at DESC",
                arguments: [matterID]
            )
        }
    }
}
