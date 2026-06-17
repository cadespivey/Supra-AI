import Foundation
import GRDB
import SupraCore

/// Owns the document "library": content blobs, folders, document instances, and
/// tags (Milestone 3). Blobs are shared by sha256; document instances are the
/// per-folder, per-tag, per-deletion-state objects users interact with.
public final class DocumentLibraryRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Blobs

    /// Result of a blob upsert: the stored blob plus whether an existing blob
    /// with the same sha256 was reused.
    public struct BlobUpsertResult: Sendable {
        public let blob: DocumentBlobRecord
        public let reused: Bool
    }

    /// Inserts a blob, or returns the existing blob if one already exists with
    /// the same sha256 (content-addressed dedup).
    @discardableResult
    public func upsertBlob(_ blob: DocumentBlobRecord) throws -> BlobUpsertResult {
        try writer.write { db in
            if let existing = try DocumentBlobRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_blobs WHERE sha256 = ?",
                arguments: [blob.sha256]
            ) {
                return BlobUpsertResult(blob: existing, reused: true)
            }
            try blob.insert(db)
            return BlobUpsertResult(blob: blob, reused: false)
        }
    }

    public func fetchBlob(id: String) throws -> DocumentBlobRecord? {
        try writer.read { db in try DocumentBlobRecord.fetchOne(db, key: id) }
    }

    public func fetchBlob(sha256: String) throws -> DocumentBlobRecord? {
        try writer.read { db in
            try DocumentBlobRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_blobs WHERE sha256 = ?",
                arguments: [sha256]
            )
        }
    }

    /// Number of document instances (including soft-deleted) still referencing a
    /// blob. Used to decide when a blob can be physically removed.
    public func referenceCount(blobID: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM matter_documents WHERE blob_id = ?",
                arguments: [blobID]
            ) ?? 0
        }
    }

    // MARK: - Folders

    @discardableResult
    public func createFolder(
        matterID: String,
        name: String,
        parentFolderID: String? = nil
    ) throws -> DocumentFolderRecord {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        return try writer.write { db in
            let record = DocumentFolderRecord(
                matterID: matterID,
                parentFolderID: parentFolderID,
                name: trimmed
            )
            try record.insert(db)
            return record
        }
    }

    public func renameFolder(id: String, name: String) throws {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE document_folders SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), id]
            )
        }
    }

    public func moveFolder(id: String, newParentFolderID: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE document_folders SET parent_folder_id = ?, updated_at = ? WHERE id = ?",
                arguments: [newParentFolderID, Date(), id]
            )
        }
    }

    public func fetchFolders(matterID: String, includeDeleted: Bool = false) throws -> [DocumentFolderRecord] {
        try writer.read { db in
            try DocumentFolderRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_folders
                WHERE matter_id = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY name COLLATE NOCASE ASC
                """,
                arguments: [matterID]
            )
        }
    }

    public func fetchFolder(id: String) throws -> DocumentFolderRecord? {
        try writer.read { db in try DocumentFolderRecord.fetchOne(db, key: id) }
    }

    /// Soft-deletes a folder, its descendant folders, and every contained
    /// document instance, in one transaction.
    public func softDeleteFolder(id: String) throws {
        try writer.write { db in
            let now = Date()
            let folderIDs = try Self.folderSubtreeIDs(db, rootID: id)
            for folderID in folderIDs {
                try db.execute(
                    sql: "UPDATE document_folders SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, folderID]
                )
            }
            try Self.softDeleteDocuments(db, inFolders: folderIDs, at: now)
        }
    }

    /// Restores a folder, its descendant folders, and contained instances.
    public func restoreFolder(id: String) throws {
        try writer.write { db in
            let now = Date()
            let folderIDs = try Self.folderSubtreeIDs(db, rootID: id)
            for folderID in folderIDs {
                try db.execute(
                    sql: "UPDATE document_folders SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                    arguments: [now, folderID]
                )
            }
            for folderID in folderIDs {
                try db.execute(
                    sql: """
                    UPDATE matter_documents
                    SET deleted_at = NULL, status = ?, updated_at = ?
                    WHERE folder_id = ? AND deleted_at IS NOT NULL
                    """,
                    arguments: [MatterDocumentStatus.ready.rawValue, now, folderID]
                )
            }
        }
    }

    // MARK: - Document instances

    @discardableResult
    public func insertDocument(_ document: MatterDocumentRecord) throws -> MatterDocumentRecord {
        try writer.write { db in
            try document.insert(db)
            return document
        }
    }

    public func fetchDocument(id: String) throws -> MatterDocumentRecord? {
        try writer.read { db in try MatterDocumentRecord.fetchOne(db, key: id) }
    }

    public func fetchDocuments(
        matterID: String,
        folderID: String? = nil,
        includeDeleted: Bool = false
    ) throws -> [MatterDocumentRecord] {
        try writer.read { db in
            var sql = "SELECT * FROM matter_documents WHERE matter_id = ?"
            var arguments: [DatabaseValueConvertible] = [matterID]
            if let folderID {
                sql += " AND folder_id = ?"
                arguments.append(folderID)
            }
            if !includeDeleted {
                sql += " AND deleted_at IS NULL"
            }
            sql += " ORDER BY display_name COLLATE NOCASE ASC"
            return try MatterDocumentRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    public func fetchDocuments(blobID: String) throws -> [MatterDocumentRecord] {
        try writer.read { db in
            try MatterDocumentRecord.fetchAll(
                db,
                sql: "SELECT * FROM matter_documents WHERE blob_id = ?",
                arguments: [blobID]
            )
        }
    }

    public func moveDocument(id: String, toFolderID: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET folder_id = ?, updated_at = ? WHERE id = ?",
                arguments: [toFolderID, Date(), id]
            )
        }
    }

    /// Copies a document instance into another folder. The new instance shares
    /// the same blob but has its own identity, tags, and (to-be-rebuilt) index
    /// state.
    @discardableResult
    public func copyDocument(id: String, toFolderID: String?) throws -> MatterDocumentRecord {
        try writer.write { db in
            guard let source = try MatterDocumentRecord.fetchOne(db, key: id) else {
                throw DocumentLibraryRepositoryError.documentNotFound(id)
            }
            let now = Date()
            var copy = source
            copy.id = UUID().uuidString
            copy.folderID = toFolderID
            copy.status = MatterDocumentStatus.indexing.rawValue
            copy.indexStatus = DocumentIndexStatus.notIndexed.rawValue
            copy.createdAt = now
            copy.updatedAt = now
            copy.deletedAt = nil
            try copy.insert(db)
            return copy
        }
    }

    public func updateStatus(documentID: String, status: MatterDocumentStatus) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), documentID]
            )
        }
    }

    public func updateIndexStatus(documentID: String, indexStatus: DocumentIndexStatus) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET index_status = ?, updated_at = ? WHERE id = ?",
                arguments: [indexStatus.rawValue, Date(), documentID]
            )
        }
    }

    /// Records the result of an extraction pass on a document instance (M3 §6.1).
    public func updateExtraction(
        documentID: String,
        status: MatterDocumentStatus,
        extractionStatus: DocumentExtractionStatus,
        method: String,
        checksum: String?,
        pagePartCount: Int,
        ocrConfidenceSummary: String? = nil,
        warningsJSON: String? = nil,
        errorsJSON: String? = nil,
        metadataCreatedAt: Date? = nil,
        metadataModifiedAt: Date? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET status = ?, extraction_status = ?, extraction_method = ?,
                    extracted_text_checksum = ?, page_part_count = ?,
                    ocr_confidence_summary = ?, extraction_warnings_json = ?,
                    extraction_errors_json = ?, metadata_created_at = ?,
                    metadata_modified_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status.rawValue, extractionStatus.rawValue, method,
                    checksum, pagePartCount, ocrConfidenceSummary, warningsJSON,
                    errorsJSON, metadataCreatedAt, metadataModifiedAt, Date(),
                    documentID
                ]
            )
        }
    }

    /// Marks a document's extracted text as user-edited and its index stale, so a
    /// later indexing pass re-chunks/re-embeds it (plan §6.2, §7.1).
    public func markTextEdited(documentID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET has_user_edited_text = 1, extraction_status = ?, index_status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    DocumentExtractionStatus.edited.rawValue,
                    DocumentIndexStatus.stale.rawValue,
                    Date(), documentID
                ]
            )
        }
    }

    public func softDeleteDocument(id: String) throws {
        try writer.write { db in
            try Self.softDeleteDocuments(db, ids: [id], at: Date())
        }
    }

    public func restoreDocument(id: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET deleted_at = NULL, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [MatterDocumentStatus.ready.rawValue, Date(), id]
            )
        }
    }

    public func fetchSoftDeletedDocuments(matterID: String) throws -> [MatterDocumentRecord] {
        try writer.read { db in
            try MatterDocumentRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM matter_documents
                WHERE matter_id = ? AND deleted_at IS NOT NULL
                ORDER BY deleted_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    /// Permanently removes a document instance and its derived index rows (via
    /// FK cascade). If no remaining instance references the shared blob, the
    /// blob row is also removed and its managed relative path is returned so the
    /// caller can delete the file.
    public struct PermanentDeleteResult: Sendable {
        public let removedBlobPath: String?
    }

    @discardableResult
    public func permanentlyDeleteDocument(id: String) throws -> PermanentDeleteResult {
        try writer.write { db in
            guard let document = try MatterDocumentRecord.fetchOne(db, key: id) else {
                return PermanentDeleteResult(removedBlobPath: nil)
            }
            let blobID = document.blobID
            try db.execute(sql: "DELETE FROM matter_documents WHERE id = ?", arguments: [id])

            let remaining = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM matter_documents WHERE blob_id = ?",
                arguments: [blobID]
            ) ?? 0
            guard remaining == 0 else {
                return PermanentDeleteResult(removedBlobPath: nil)
            }
            let blob = try DocumentBlobRecord.fetchOne(db, key: blobID)
            try db.execute(sql: "DELETE FROM document_blobs WHERE id = ?", arguments: [blobID])
            return PermanentDeleteResult(removedBlobPath: blob?.managedRelativePath)
        }
    }

    // MARK: - Tags

    @discardableResult
    public func createTag(matterID: String, name: String, color: String? = nil) throws -> DocumentTagRecord {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        return try writer.write { db in
            let record = DocumentTagRecord(matterID: matterID, name: trimmed, color: color)
            try record.insert(db)
            return record
        }
    }

    public func renameTag(id: String, name: String) throws {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE document_tags SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), id]
            )
        }
    }

    public func deleteTag(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM document_tags WHERE id = ?", arguments: [id])
        }
    }

    public func fetchTags(matterID: String) throws -> [DocumentTagRecord] {
        try writer.read { db in
            try DocumentTagRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_tags WHERE matter_id = ? ORDER BY name COLLATE NOCASE ASC",
                arguments: [matterID]
            )
        }
    }

    public func assignTag(tagID: String, documentID: String) throws {
        try writer.write { db in
            let record = DocumentTagAssignmentRecord(tagID: tagID, documentID: documentID)
            try record.insert(db, onConflict: .ignore)
        }
    }

    public func unassignTag(tagID: String, documentID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM document_tag_assignments WHERE tag_id = ? AND document_id = ?",
                arguments: [tagID, documentID]
            )
        }
    }

    public func fetchTags(documentID: String) throws -> [DocumentTagRecord] {
        try writer.read { db in
            try DocumentTagRecord.fetchAll(
                db,
                sql: """
                SELECT t.* FROM document_tags t
                JOIN document_tag_assignments a ON a.tag_id = t.id
                WHERE a.document_id = ?
                ORDER BY t.name COLLATE NOCASE ASC
                """,
                arguments: [documentID]
            )
        }
    }

    // MARK: - Helpers

    private static func softDeleteDocuments(_ db: Database, ids: [String], at date: Date) throws {
        for id in ids {
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET deleted_at = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [date, MatterDocumentStatus.deleted.rawValue, date, id]
            )
        }
    }

    private static func softDeleteDocuments(_ db: Database, inFolders folderIDs: [String], at date: Date) throws {
        guard !folderIDs.isEmpty else { return }
        let placeholders = databaseQuestionMarks(count: folderIDs.count)
        var arguments: [DatabaseValueConvertible] = [date, MatterDocumentStatus.deleted.rawValue, date]
        arguments.append(contentsOf: folderIDs)
        try db.execute(
            sql: """
            UPDATE matter_documents
            SET deleted_at = ?, status = ?, updated_at = ?
            WHERE folder_id IN (\(placeholders)) AND deleted_at IS NULL
            """,
            arguments: StatementArguments(arguments)
        )
    }

    /// Returns a folder id plus all descendant folder ids (depth-first).
    private static func folderSubtreeIDs(_ db: Database, rootID: String) throws -> [String] {
        var result: [String] = []
        var queue: [String] = [rootID]
        while let current = queue.first {
            queue.removeFirst()
            result.append(current)
            let children = try String.fetchAll(
                db,
                sql: "SELECT id FROM document_folders WHERE parent_folder_id = ?",
                arguments: [current]
            )
            queue.append(contentsOf: children)
        }
        return result
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DocumentLibraryRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }
}

public enum DocumentLibraryRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
    case documentNotFound(String)
}
