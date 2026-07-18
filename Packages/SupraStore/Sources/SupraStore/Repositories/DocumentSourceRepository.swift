import Foundation
import GRDB
import SupraCore

public enum DocumentSourceRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case sourceSetNotFound(String)
    case documentNotFound(String)
    case sourceMatterMismatch(String)
    case chunkScopeMismatch(String)
    case revisionScopeMismatch(String)
    case messageNotFound(String)
    case messageMatterMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .sourceSetNotFound(let id):
            "Document source set \(id) was not found."
        case .documentNotFound(let id):
            "Document \(id) was not found."
        case .sourceMatterMismatch(let id):
            "Document \(id) does not belong to the source set's matter."
        case .chunkScopeMismatch(let id):
            "Document chunk \(id) does not belong to the cited document."
        case .revisionScopeMismatch(let id):
            "Document revision \(id) does not belong to the cited document."
        case .messageNotFound(let id):
            "Message \(id) was not found."
        case .messageMatterMismatch(let id):
            "Message \(id) does not belong to a chat in the source set's matter."
        }
    }
}

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
        retrievalDepth: String? = nil,
        packingReportJSON: String? = nil,
        embeddingModelID: String? = nil,
        embeddingModelRevision: String? = nil,
        chunkerVersion: Int? = nil,
        retrievalConfigJSON: String? = nil,
        corpusSnapshotHash: String? = nil,
        messageID: String? = nil,
        structuredOutputVersionID: String? = nil,
        status: DocumentSourceSetStatus = .pending
    ) throws -> DocumentSourceSetRecord {
        try writer.write { db in
            if let messageID {
                guard let message = try MessageRecord.fetchOne(db, key: messageID) else {
                    throw DocumentSourceRepositoryError.messageNotFound(messageID)
                }
                guard let chat = try ChatRecord.fetchOne(db, key: message.chatID),
                      chat.scope == "matter",
                      chat.matterID == matterID else {
                    throw DocumentSourceRepositoryError.messageMatterMismatch(messageID)
                }
                if let existing = try DocumentSourceSetRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM document_source_sets WHERE message_id = ?",
                    arguments: [messageID]
                ) {
                    return existing
                }
            }
            let record = DocumentSourceSetRecord(
                matterID: matterID,
                structuredOutputVersionID: structuredOutputVersionID,
                status: status.rawValue,
                mode: mode.rawValue,
                scopeJSON: scopeJSON,
                retrievalQuery: retrievalQuery,
                retrievalDepth: retrievalDepth,
                packingReportJSON: packingReportJSON,
                embeddingModelID: embeddingModelID,
                embeddingModelRevision: embeddingModelRevision,
                chunkerVersion: chunkerVersion,
                retrievalConfigJSON: retrievalConfigJSON,
                corpusSnapshotHash: corpusSnapshotHash,
                messageID: messageID
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

    public func fetchSourceSet(messageID: String) throws -> DocumentSourceSetRecord? {
        try writer.read { db in
            try DocumentSourceSetRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_source_sets WHERE message_id = ? LIMIT 1",
                arguments: [messageID]
            )
        }
    }

    /// Returns every source set for a matter, including pending sets. This is
    /// intentionally broader than the version-scoped fetch so callers and
    /// integrity tests can detect abandoned provenance writes.
    public func fetchSourceSets(matterID: String) throws -> [DocumentSourceSetRecord] {
        try writer.read { db in
            try DocumentSourceSetRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_source_sets
                WHERE matter_id = ?
                ORDER BY created_at DESC, id DESC
                """,
                arguments: [matterID]
            )
        }
    }

    // MARK: - Cited output sources

    public func addOutputSource(
        _ source: DocumentOutputSourceRecord,
        preserveUnknownRevision: Bool = false
    ) throws {
        try writer.write { db in
            let prepared = try prepare(
                source,
                preserveUnknownRevision: preserveUnknownRevision,
                db: db
            )
            try prepared.insert(db)
        }
    }

    public func addOutputSources(
        _ sources: [DocumentOutputSourceRecord],
        preserveUnknownRevision: Bool = false
    ) throws {
        try writer.write { db in
            for source in sources {
                let prepared = try prepare(
                    source,
                    preserveUnknownRevision: preserveUnknownRevision,
                    db: db
                )
                try prepared.insert(db)
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

    public func fetchSource(id: String) throws -> DocumentOutputSourceRecord? {
        try writer.read { db in try DocumentOutputSourceRecord.fetchOne(db, key: id) }
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

    /// Validates matter/document/revision scope and, for ordinary new writes,
    /// derives the exact revision from the immutable cited chunk. Callers cloning
    /// a legacy source set opt into preserving nil so unknown history is never
    /// silently laundered into current provenance.
    private func prepare(
        _ source: DocumentOutputSourceRecord,
        preserveUnknownRevision: Bool,
        db: Database
    ) throws -> DocumentOutputSourceRecord {
        guard let sourceSet = try DocumentSourceSetRecord.fetchOne(db, key: source.sourceSetID) else {
            throw DocumentSourceRepositoryError.sourceSetNotFound(source.sourceSetID)
        }

        var prepared = source
        if let documentID = source.documentID {
            guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID) else {
                throw DocumentSourceRepositoryError.documentNotFound(documentID)
            }
            guard document.matterID == sourceSet.matterID else {
                throw DocumentSourceRepositoryError.sourceMatterMismatch(documentID)
            }
        }

        if let chunkID = source.chunkID,
           let chunk = try DocumentChunkRecord.fetchOne(db, key: chunkID) {
            if let documentID = source.documentID, chunk.documentID != documentID {
                throw DocumentSourceRepositoryError.chunkScopeMismatch(chunkID)
            }
            if prepared.revisionID == nil, !preserveUnknownRevision {
                prepared.revisionID = chunk.revisionID
            }
        }

        if let revisionID = prepared.revisionID {
            guard let documentID = prepared.documentID,
                  let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                  revision.documentID == documentID else {
                throw DocumentSourceRepositoryError.revisionScopeMismatch(revisionID)
            }
        }
        return prepared
    }

    // MARK: - Exports

    @discardableResult
    public func recordExport(_ export: DocumentExportRecord) throws -> DocumentExportRecord {
        try writer.write { db in
            try export.insert(db)
            return export
        }
    }

    /// Records the durable file's export row and corresponding success audit as
    /// one database transaction. Callers must invoke this only after the file is
    /// validated and atomically installed.
    public func recordExportCompletion(
        _ export: DocumentExportRecord,
        auditEvent: AuditEventRecord
    ) throws {
        try writer.write { db in
            try export.insert(db)
            try auditEvent.insert(db)
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
