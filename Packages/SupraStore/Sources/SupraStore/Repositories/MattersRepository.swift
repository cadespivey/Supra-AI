import Foundation
import GRDB
import SupraCore

public final class MattersRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createMatter(
        name: String,
        jurisdiction: String = "Unspecified",
        partyPerspective: PartyPerspective = .neutral,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        clientNames: String? = nil,
        matterDescription: String? = nil,
        internalMatterID: String? = nil,
        clientID: String? = nil,
        clientMatterID: String? = nil,
        notes: String? = nil,
        defaultChatTitle: String? = nil
    ) throws -> MatterRecord {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        let chatTitle = defaultChatTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            let now = Date()
            let record = MatterRecord(
                name: normalized.name,
                jurisdiction: normalized.jurisdiction,
                partyPerspective: partyPerspective.rawValue,
                court: Self.trimOptional(court),
                judge: Self.trimOptional(judge),
                docketNumber: Self.trimOptional(docketNumber),
                practiceArea: Self.trimOptional(practiceArea),
                clientNames: Self.trimOptional(clientNames),
                matterDescription: Self.trimOptional(matterDescription),
                internalMatterID: Self.trimOptional(internalMatterID),
                clientID: Self.trimOptional(clientID),
                clientMatterID: Self.trimOptional(clientMatterID),
                notes: Self.trimOptional(notes),
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            // Create the default matter chat in the same transaction so a matter
            // never exists without it (spec §8.3); both roll back together.
            if let chatTitle, !chatTitle.isEmpty {
                try ChatRecord(title: chatTitle, scope: "matter", matterID: record.id).insert(db)
            }
            return record
        }
    }

    public func fetchMatters() throws -> [MatterRecord] {
        try writer.read { db in
            try MatterRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM matters
                WHERE deleted_at IS NULL
                ORDER BY updated_at DESC
                """
            )
        }
    }

    public func fetchMatter(id: String) throws -> MatterRecord? {
        try writer.read { db in
            try MatterRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM matters
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [id]
            )
        }
    }

    public func renameMatter(id: String, name: String) throws {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), id]
            )
        }
    }

    public func updateMatter(
        id: String,
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        clientNames: String? = nil,
        matterDescription: String? = nil,
        internalMatterID: String? = nil,
        clientID: String? = nil,
        clientMatterID: String? = nil,
        notes: String? = nil
    ) throws {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matters
                SET name = ?,
                    jurisdiction = ?,
                    party_perspective = ?,
                    court = ?,
                    judge = ?,
                    docket_number = ?,
                    practice_area = ?,
                    client_names = ?,
                    matter_description = ?,
                    internal_matter_id = ?,
                    client_id = ?,
                    client_matter_id = ?,
                    notes = ?,
                    updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    normalized.name,
                    normalized.jurisdiction,
                    partyPerspective.rawValue,
                    Self.trimOptional(court),
                    Self.trimOptional(judge),
                    Self.trimOptional(docketNumber),
                    Self.trimOptional(practiceArea),
                    Self.trimOptional(clientNames),
                    Self.trimOptional(matterDescription),
                    Self.trimOptional(internalMatterID),
                    Self.trimOptional(clientID),
                    Self.trimOptional(clientMatterID),
                    Self.trimOptional(notes),
                    Date(),
                    id
                ]
            )
        }
    }

    public func softDeleteMatter(id: String, deletedAt: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matters
                SET deleted_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [deletedAt, deletedAt, id]
            )
            // Cascade the soft-delete to the matter's child rows that support it, so
            // deleting a matter doesn't leave its folders, documents, and outputs
            // visible and orphaned. (Other children are reached only via the now-hidden
            // matter.) Kept as soft-deletes for potential recovery.
            for table in ["document_folders", "matter_documents", "structured_outputs"] {
                try db.execute(
                    sql: "UPDATE \(table) SET deleted_at = ?, updated_at = ? WHERE matter_id = ? AND deleted_at IS NULL",
                    arguments: [deletedAt, deletedAt, id]
                )
            }
            // Processing jobs have no deleted_at; cancel any in-flight ones so a deleted
            // matter's imports stop consuming the queue.
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, updated_at = ?
                WHERE matter_id = ? AND status IN ('queued', 'active', 'paused')
                """,
                arguments: [DocumentProcessingJobStatus.cancelled.rawValue, deletedAt, id]
            )
        }
    }

    /// Soft-deleted matters, newest deletion first — the Recycle Bin source.
    public func fetchSoftDeletedMatters() throws -> [MatterRecord] {
        try writer.read { db in
            try MatterRecord.fetchAll(
                db,
                sql: "SELECT * FROM matters WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC"
            )
        }
    }

    /// Restores a soft-deleted matter and the children that *this* delete cascaded
    /// (matched by the shared deletion timestamp), leaving documents that were trashed
    /// independently — before the matter — in the trash. Returns false if the matter
    /// isn't currently deleted.
    @discardableResult
    public func restoreMatter(id: String) throws -> Bool {
        try writer.write { db in
            guard let deletedAt = try Date.fetchOne(
                db,
                sql: "SELECT deleted_at FROM matters WHERE id = ? AND deleted_at IS NOT NULL",
                arguments: [id]
            ) else { return false }
            let now = Date()
            try db.execute(
                sql: "UPDATE matters SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                arguments: [now, id]
            )
            for table in ["document_folders", "matter_documents", "structured_outputs"] {
                try db.execute(
                    sql: "UPDATE \(table) SET deleted_at = NULL, updated_at = ? WHERE matter_id = ? AND deleted_at = ?",
                    arguments: [now, id, deletedAt]
                )
            }
            return true
        }
    }

    /// Permanently deletes a matter and everything it owns. FK cascade removes the
    /// matter's chats, documents, folders, outputs, and research rows; the standalone
    /// FTS index and orphaned blob files are not FK-cascaded, so the document chunks'
    /// FTS rows are cleared here and the managed paths of any now-unreferenced blob are
    /// returned for the caller to delete from disk.
    @discardableResult
    public func permanentlyDeleteMatter(id: String) throws -> [String] {
        try writer.write { db in
            let docIDs = try String.fetchAll(
                db, sql: "SELECT id FROM matter_documents WHERE matter_id = ?", arguments: [id]
            )
            let blobIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT blob_id FROM matter_documents WHERE matter_id = ? AND blob_id IS NOT NULL",
                arguments: [id]
            ))
            for docID in docIDs {
                try db.execute(sql: "DELETE FROM document_chunk_fts WHERE document_id = ?", arguments: [docID])
            }
            try db.execute(sql: "DELETE FROM matters WHERE id = ?", arguments: [id])

            var removedPaths: [String] = []
            for blobID in blobIDs {
                let remaining = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM matter_documents WHERE blob_id = ?", arguments: [blobID]
                ) ?? 0
                guard remaining == 0 else { continue }
                if let path = try DocumentBlobRecord.fetchOne(db, key: blobID)?.managedRelativePath {
                    removedPaths.append(path)
                }
                try db.execute(sql: "DELETE FROM document_blobs WHERE id = ?", arguments: [blobID])
            }
            return removedPaths
        }
    }

    private static func validateMatterFields(
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective
    ) throws -> (name: String, jurisdiction: String) {
        (
            try requireNonEmpty(name, fieldName: "name"),
            try requireNonEmpty(jurisdiction, fieldName: "jurisdiction")
        )
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatterRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }

    private static func trimOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum MatterRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
}
