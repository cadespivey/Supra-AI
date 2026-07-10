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

    /// The live folder with this exact parent and Unicode case-insensitive name,
    /// if one exists. When legacy data contains duplicate siblings, the oldest
    /// folder (then lexical id) wins deterministically.
    public func findFolder(matterID: String, parentFolderID: String?, name: String) throws -> DocumentFolderRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try writer.read { db in
            try Self.findFolder(
                db,
                matterID: matterID,
                parentFolderID: parentFolderID,
                normalizedName: Self.folderIdentity(trimmed)
            )
        }
    }

    /// Returns the matching live sibling or creates it atomically. Import,
    /// research, templates, and manual folder creation all use this path so
    /// their definition of "the same folder" cannot drift.
    @discardableResult
    public func ensureFolder(
        matterID: String,
        name: String,
        parentFolderID: String? = nil
    ) throws -> DocumentFolderRecord {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        return try writer.write { db in
            if let existing = try Self.findFolder(
                db,
                matterID: matterID,
                parentFolderID: parentFolderID,
                normalizedName: Self.folderIdentity(trimmed)
            ) {
                return existing
            }
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
            let folderIDs = try Self.folderSubtreeIDs(db, rootID: id, includingDeleted: true)
            for folderID in folderIDs {
                try db.execute(
                    sql: "UPDATE document_folders SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                    arguments: [now, now, folderID]
                )
            }
            try Self.softDeleteDocuments(db, inFolders: folderIDs, at: now)
        }
    }

    /// Restores a folder, its descendant folders, and the document instances that
    /// were soft-deleted *by this folder delete*.
    ///
    /// `softDeleteFolder` stamps every cascade-deleted document with the folder's
    /// deletion timestamp but skips documents already soft-deleted on their own
    /// (`deleted_at IS NULL` guard). Restoring therefore matches that same
    /// timestamp so documents the user deleted independently beforehand stay
    /// deleted instead of being silently un-deleted.
    public func restoreFolder(id: String) throws {
        try writer.write { db in
            let now = Date()
            // Capture the folder's deletion timestamp (raw stored text, for an exact
            // match) before we clear it.
            let folderDeletedAt = try String.fetchOne(
                db,
                sql: "SELECT deleted_at FROM document_folders WHERE id = ?",
                arguments: [id]
            )
            guard let folderDeletedAt else { return }
            let folderIDs = try Self.folderSubtreeIDs(db, rootID: id, includingDeleted: true)
            for folderID in folderIDs {
                try db.execute(
                    sql: "UPDATE document_folders SET deleted_at = NULL, updated_at = ? WHERE id = ? AND deleted_at = ?",
                    arguments: [now, folderID, folderDeletedAt]
                )
            }
            for folderID in folderIDs {
                try db.execute(
                    sql: """
                    UPDATE matter_documents
                    SET deleted_at = NULL, status = ?, updated_at = ?
                    WHERE folder_id = ? AND deleted_at = ?
                    """,
                    arguments: [MatterDocumentStatus.ready.rawValue, now, folderID, folderDeletedAt]
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

    /// Persists the document classifier's structured result (1.3.2) — the serialized
    /// `DocumentClassification` JSON, or nil to clear it.
    public func updateClassification(documentID: String, classificationMetadataJSON: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET classification_metadata_json = ?, updated_at = ? WHERE id = ?",
                arguments: [classificationMetadataJSON, Date(), documentID]
            )
        }
    }

    /// Marks a document's extracted text as user-edited and its index stale, so a
    /// later indexing pass re-chunks/re-embeds it (plan §6.2, §7.1).
    public func markTextEdited(documentID: String) throws {
        try writer.write { db in
            // Clearing the classification re-opens the document for re-classification
            // on the next pass — its content changed, so its old category may not fit.
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET has_user_edited_text = 1, extraction_status = ?, index_status = ?,
                    classification_metadata_json = NULL, updated_at = ?
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

    /// All soft-deleted document instances (across matters) whose deletion is
    /// older than the cutoff — candidates for auto-purge (plan §12.2).
    public func fetchDocumentsDeletedBefore(_ cutoff: Date) throws -> [MatterDocumentRecord] {
        try writer.read { db in
            try MatterDocumentRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM matter_documents
                WHERE deleted_at IS NOT NULL AND deleted_at < ?
                ORDER BY deleted_at ASC
                """,
                arguments: [cutoff]
            )
        }
    }

    /// All individually soft-deleted documents whose matter is still live — documents
    /// trashed as part of a matter delete are restored with the matter, so they aren't
    /// listed separately. Powers the global Recycle Bin.
    public func fetchAllSoftDeletedDocuments() throws -> [MatterDocumentRecord] {
        try writer.read { db in
            try MatterDocumentRecord.fetchAll(
                db,
                sql: """
                SELECT d.* FROM matter_documents d
                JOIN matters m ON m.id = d.matter_id
                WHERE d.deleted_at IS NOT NULL AND m.deleted_at IS NULL
                ORDER BY d.deleted_at DESC
                """
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
        /// Managed relative paths of every blob file freed by the delete (one per
        /// document in the deleted subtree whose blob is no longer referenced).
        public let removedBlobPaths: [String]
        /// Every document id removed (root + attachment descendants), so callers
        /// iterating a list of expired documents don't double-process a child that
        /// was already cascade-purged with its parent.
        public let removedDocumentIDs: [String]
    }

    /// Permanently removes a document instance, its attachment subtree (emails
    /// import attachments as child documents), and all derived index rows. Each
    /// freed blob's managed file path is returned so the caller can delete it; a
    /// blob is only freed when no surviving document still references it.
    @discardableResult
    public func permanentlyDeleteDocument(id: String) throws -> PermanentDeleteResult {
        try writer.write { db in
            guard try MatterDocumentRecord.fetchOne(db, key: id) != nil else {
                return PermanentDeleteResult(removedBlobPaths: [], removedDocumentIDs: [])
            }
            let subtreeIDs = try Self.documentSubtreeIDs(db, rootID: id)

            // Capture blob ids and clear the standalone FTS5 index (no FK cascade)
            // for every document in the subtree BEFORE deleting any rows, so a FK
            // cascade on parent_document_id cannot remove a child row before we
            // record its blob — otherwise the child's blob/file/FTS rows leak.
            var blobIDs = Set<String>()
            for documentID in subtreeIDs {
                if let row = try MatterDocumentRecord.fetchOne(db, key: documentID) {
                    blobIDs.insert(row.blobID)
                }
                try db.execute(sql: "DELETE FROM document_chunk_fts WHERE document_id = ?", arguments: [documentID])
            }
            // Delete deepest-first so we never violate the parent FK or depend on
            // cascade behavior.
            for documentID in subtreeIDs.reversed() {
                try db.execute(sql: "DELETE FROM matter_documents WHERE id = ?", arguments: [documentID])
            }

            var removedPaths: [String] = []
            for blobID in blobIDs {
                let remaining = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_documents WHERE blob_id = ?",
                    arguments: [blobID]
                ) ?? 0
                guard remaining == 0 else { continue }
                if let path = try DocumentBlobRecord.fetchOne(db, key: blobID)?.managedRelativePath {
                    removedPaths.append(path)
                }
                try db.execute(sql: "DELETE FROM document_blobs WHERE id = ?", arguments: [blobID])
            }
            return PermanentDeleteResult(removedBlobPaths: removedPaths, removedDocumentIDs: subtreeIDs)
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

    /// Resolves a Q&A/search scope (folders/documents/tags/date filters) to the
    /// set of non-deleted document instance ids it covers (plan §7.2, §8.1). All
    /// filters nil → every non-deleted document in the matter.
    public func resolveScopeDocumentIDs(
        matterID: String,
        folderIDs: [String]? = nil,
        documentIDs: [String]? = nil,
        tagIDs: [String]? = nil,
        dateStart: Date? = nil,
        dateEnd: Date? = nil
    ) throws -> [String] {
        try writer.read { db in
            var sql = "SELECT DISTINCT d.id FROM matter_documents d"
            var clauses = ["d.matter_id = ?", "d.deleted_at IS NULL"]
            var arguments: [DatabaseValueConvertible] = [matterID]
            if let tagIDs, !tagIDs.isEmpty {
                sql += " JOIN document_tag_assignments a ON a.document_id = d.id"
                clauses.append("a.tag_id IN (\(databaseQuestionMarks(count: tagIDs.count)))")
                arguments.append(contentsOf: tagIDs)
            }
            if let folderIDs, !folderIDs.isEmpty {
                // A folder scope covers the folder AND its subfolders — with
                // nested folders, scoping to "Discovery" must include documents
                // filed in "Discovery/Depositions". Silent under-inclusion is
                // the dangerous failure for a legal research scope.
                var expanded: Set<String> = []
                for folderID in folderIDs {
                    expanded.formUnion(
                        try Self.folderSubtreeIDs(db, rootID: folderID, includingDeleted: false)
                    )
                }
                guard !expanded.isEmpty else { return [] }
                clauses.append("d.folder_id IN (\(databaseQuestionMarks(count: expanded.count)))")
                arguments.append(contentsOf: Array(expanded))
            }
            if let documentIDs, !documentIDs.isEmpty {
                clauses.append("d.id IN (\(databaseQuestionMarks(count: documentIDs.count)))")
                arguments.append(contentsOf: documentIDs)
            }
            // A date filter narrows by *known* dates but never silently drops a
            // document whose date could not be extracted (metadata_created_at IS
            // NULL) — excluding undated evidence from a legal scope is the more
            // dangerous failure, so NULL-dated documents are always retained.
            if let dateStart {
                clauses.append("(d.metadata_created_at IS NULL OR d.metadata_created_at >= ?)")
                arguments.append(dateStart)
            }
            if let dateEnd {
                clauses.append("(d.metadata_created_at IS NULL OR d.metadata_created_at <= ?)")
                arguments.append(dateEnd)
            }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
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

    /// Returns a folder id plus its descendants. Delete/restore traversal includes
    /// trashed rows so it can preserve cascade ownership; retrieval traversal is
    /// live-only and stops before a trashed branch.
    private static func folderSubtreeIDs(
        _ db: Database,
        rootID: String,
        includingDeleted: Bool
    ) throws -> [String] {
        let rootSQL = "SELECT id FROM document_folders WHERE id = ?"
            + (includingDeleted ? "" : " AND deleted_at IS NULL")
        guard try String.fetchOne(db, sql: rootSQL, arguments: [rootID]) != nil else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        var queue: [String] = [rootID]
        while let current = queue.first {
            queue.removeFirst()
            // Cycle guard: a corrupted/cyclic parent pointer must not hang the
            // write transaction in an infinite loop.
            guard seen.insert(current).inserted else { continue }
            result.append(current)
            let children = try String.fetchAll(
                db,
                sql: "SELECT id FROM document_folders WHERE parent_folder_id = ?"
                    + (includingDeleted ? "" : " AND deleted_at IS NULL")
                    + " ORDER BY id ASC",
                arguments: [current]
            )
            queue.append(contentsOf: children)
        }
        return result
    }

    private static func findFolder(
        _ db: Database,
        matterID: String,
        parentFolderID: String?,
        normalizedName: String
    ) throws -> DocumentFolderRecord? {
        let candidates = try DocumentFolderRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM document_folders
            WHERE matter_id = ?
              AND deleted_at IS NULL
              AND parent_folder_id \(parentFolderID == nil ? "IS NULL" : "= ?")
            ORDER BY created_at ASC, id ASC
            """,
            arguments: parentFolderID == nil ? [matterID] : [matterID, parentFolderID]
        )
        return candidates.first { folderIdentity($0.name) == normalizedName }
    }

    private static func folderIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    /// Breadth-first list of a document id followed by all of its attachment
    /// descendants (root first), used to purge an entire attachment subtree.
    private static func documentSubtreeIDs(_ db: Database, rootID: String) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var queue: [String] = [rootID]
        while let current = queue.first {
            queue.removeFirst()
            // Cycle guard against a corrupted/cyclic parent pointer.
            guard seen.insert(current).inserted else { continue }
            result.append(current)
            let children = try String.fetchAll(
                db,
                sql: "SELECT id FROM matter_documents WHERE parent_document_id = ?",
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
