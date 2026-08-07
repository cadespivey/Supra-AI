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

    /// Fetches a deterministic, bounded page for integrity reconciliation.
    /// IDs are opaque but stable and indexed by the primary key.
    public func fetchBlobs(afterID: String? = nil, limit: Int) throws -> [DocumentBlobRecord] {
        let boundedLimit = min(max(limit, 1), 200)
        return try writer.read { db in
            if let afterID {
                return try DocumentBlobRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM document_blobs WHERE id > ? ORDER BY id LIMIT ?",
                    arguments: [afterID, boundedLimit]
                )
            }
            return try DocumentBlobRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_blobs ORDER BY id LIMIT ?",
                arguments: [boundedLimit]
            )
        }
    }

    public func updateBlobIntegrity(
        id: String,
        status: DocumentBlobIntegrityStatus,
        verifiedAt: Date?,
        error: String?
    ) throws {
        let boundedError = error.map { String($0.prefix(256)) }
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE document_blobs
                SET integrity_status = ?, verified_at = ?, integrity_error = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, verifiedAt, boundedError, id]
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
            try DocumentAttachmentIntegrity.validateParentScope(document, in: db)
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

    /// Promotes a document's status only when its current status is one of
    /// `allowed` — a single conditional UPDATE so a concurrently-set terminal
    /// state (needs_review, failed) is never clobbered by a stale promotion.
    @discardableResult
    public func promoteStatus(documentID: String, to status: MatterDocumentStatus, whenCurrentIn allowed: [MatterDocumentStatus]) throws -> Bool {
        guard !allowed.isEmpty else { return false }
        return try writer.write { db in
            var arguments: [DatabaseValueConvertible] = [status.rawValue, Date(), documentID]
            arguments.append(contentsOf: allowed.map(\.rawValue))
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET status = ?, updated_at = ?
                WHERE id = ? AND status IN (\(databaseQuestionMarks(count: allowed.count)))
                """,
                arguments: StatementArguments(arguments)
            )
            return db.changesCount > 0
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
                SELECT document.*
                FROM matter_documents AS document
                JOIN matters AS matter ON matter.id = document.matter_id
                WHERE document.deleted_at IS NOT NULL
                  AND document.deleted_at < ?
                  AND matter.deleted_at IS NULL
                ORDER BY document.deleted_at ASC
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
    public func permanentlyDeleteDocument(
        id: String,
        actor: String = "system",
        at timestamp: Date = Date()
    ) throws -> PermanentDeleteResult {
        let normalizedActor = try Self.requireNonEmpty(actor, fieldName: "actor")
        return try writer.write { db in
            guard let root = try MatterDocumentRecord.fetchOne(db, key: id) else {
                return PermanentDeleteResult(removedBlobPaths: [], removedDocumentIDs: [])
            }
            let subtreeIDs = try Self.documentSubtreeIDs(
                db,
                rootID: id,
                matterID: root.matterID
            )
            try DocumentAttachmentIntegrity.validateDeletionBoundary(
                parentIDs: subtreeIDs,
                matterID: root.matterID,
                in: db
            )
            let removedDocumentIDs = Set(subtreeIDs)

            let revisionIDs = Set(try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM document_part_revisions
                    WHERE document_id IN (\(databaseQuestionMarks(count: subtreeIDs.count)))
                    """,
                arguments: StatementArguments(subtreeIDs)
            ))
            let chunkIDs = Set(try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM document_chunks
                    WHERE document_id IN (\(databaseQuestionMarks(count: subtreeIDs.count)))
                    """,
                arguments: StatementArguments(subtreeIDs)
            ))

            // Capture every directly dependent saved version before FK SET NULL
            // clears the live document/chunk/revision identities on source rows.
            var sourcePredicates = [
                "source.document_id IN (\(databaseQuestionMarks(count: subtreeIDs.count)))"
            ]
            var sourceArguments: [DatabaseValueConvertible] = subtreeIDs
            if !chunkIDs.isEmpty {
                sourcePredicates.append(
                    "source.chunk_id IN (\(databaseQuestionMarks(count: chunkIDs.count)))"
                )
                sourceArguments.append(contentsOf: chunkIDs.sorted())
            }
            if !revisionIDs.isEmpty {
                sourcePredicates.append(
                    "source.revision_id IN (\(databaseQuestionMarks(count: revisionIDs.count)))"
                )
                sourceArguments.append(contentsOf: revisionIDs.sorted())
            }
            let dependentSources = try DocumentOutputSourceRecord.fetchAll(
                db,
                sql: """
                    SELECT source.*
                    FROM document_output_sources AS source
                    WHERE \(sourcePredicates.joined(separator: " OR "))
                    """,
                arguments: StatementArguments(sourceArguments)
            )
            var impactedVersionIDs = Set<String>()
            for source in dependentSources {
                if let versionID = source.structuredOutputVersionID {
                    impactedVersionIDs.insert(versionID)
                }
                if let sourceSet = try DocumentSourceSetRecord.fetchOne(db, key: source.sourceSetID),
                   let versionID = sourceSet.structuredOutputVersionID {
                    impactedVersionIDs.insert(versionID)
                }
            }

            let matterRuns = try CorpusAnalysisRunRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? ORDER BY id",
                arguments: [root.matterID]
            )
            var impactedRunIDs = Set<String>()
            if !revisionIDs.isEmpty {
                var sliceArguments: [DatabaseValueConvertible] = [root.matterID]
                sliceArguments.append(contentsOf: subtreeIDs)
                sliceArguments.append(contentsOf: revisionIDs.sorted())
                impactedRunIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT slice.run_id
                        FROM corpus_analysis_partition_slices AS slice
                        JOIN corpus_analysis_runs AS run ON run.id = slice.run_id
                        WHERE run.matter_id = ?
                          AND (
                            slice.document_id IN (\(databaseQuestionMarks(count: subtreeIDs.count)))
                            OR slice.revision_id IN (\(databaseQuestionMarks(count: revisionIDs.count)))
                          )
                        """,
                    arguments: StatementArguments(sliceArguments)
                ))
            } else {
                var sliceArguments: [DatabaseValueConvertible] = [root.matterID]
                sliceArguments.append(contentsOf: subtreeIDs)
                impactedRunIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT slice.run_id
                        FROM corpus_analysis_partition_slices AS slice
                        JOIN corpus_analysis_runs AS run ON run.id = slice.run_id
                        WHERE run.matter_id = ?
                          AND slice.document_id IN (\(databaseQuestionMarks(count: subtreeIDs.count)))
                        """,
                    arguments: StatementArguments(sliceArguments)
                ))
            }

            // Pre-v2/custom runs record their actual model inputs on partitions,
            // not exact slice rows. Malformed same-matter input lineage cannot
            // prove exclusion and therefore fails closed.
            let matterPartitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: """
                    SELECT partition.*
                    FROM corpus_analysis_partitions AS partition
                    JOIN corpus_analysis_runs AS run ON run.id = partition.run_id
                    WHERE run.matter_id = ?
                    ORDER BY partition.run_id, partition.id
                    """,
                arguments: [root.matterID]
            )
            let partitionDecoder = JSONDecoder()
            for partition in matterPartitions {
                guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
                      let inputRevisionIDs = try? partitionDecoder.decode([String].self, from: data),
                      !inputRevisionIDs.isEmpty,
                      inputRevisionIDs.allSatisfy({ !$0.isEmpty }),
                      Set(inputRevisionIDs).count == inputRevisionIDs.count else {
                    impactedRunIDs.insert(partition.runID)
                    continue
                }
                if !revisionIDs.isDisjoint(with: inputRevisionIDs) {
                    impactedRunIDs.insert(partition.runID)
                }
            }

            let snapshotDecoder = JSONDecoder()
            for run in matterRuns {
                guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8) else {
                    impactedRunIDs.insert(run.id)
                    continue
                }
                guard let snapshot = try? snapshotDecoder.decode(
                    CorpusAnalysisSnapshot.self,
                    from: snapshotData
                ), Self.isSemanticallyValidDeletionSnapshot(snapshot) else {
                    // Malformed same-matter lineage cannot prove exclusion, so
                    // permanent deletion invalidates it conservatively.
                    impactedRunIDs.insert(run.id)
                    continue
                }
                if snapshot.members.contains(where: { member in
                    member.documentID.map(removedDocumentIDs.contains) ?? false
                        || !revisionIDs.isDisjoint(with: member.revisionIDs)
                }) {
                    impactedRunIDs.insert(run.id)
                }
            }

            // Follow the run/version relation to a fixed point. Either side may
            // be the only surviving pointer in historical data.
            var dependencyExpanded = true
            while dependencyExpanded {
                dependencyExpanded = false
                for run in matterRuns {
                    if let versionID = run.structuredOutputVersionID,
                       impactedVersionIDs.contains(versionID),
                       impactedRunIDs.insert(run.id).inserted {
                        dependencyExpanded = true
                    }
                    if impactedRunIDs.contains(run.id),
                       let versionID = run.structuredOutputVersionID,
                       impactedVersionIDs.insert(versionID).inserted {
                        dependencyExpanded = true
                    }
                }
            }

            let staleReason = "source_permanently_deleted:document=\(id)"
            let impactedRuns = impactedRunIDs.sorted()
            if !impactedRuns.isEmpty {
                let reasonsJSON = try Self.canonicalJSON([staleReason])
                var arguments: [DatabaseValueConvertible] = [
                    OutputAssuranceState.stale.rawValue,
                    reasonsJSON,
                ]
                arguments.append(contentsOf: impactedRuns)
                try db.execute(
                    sql: """
                        UPDATE corpus_analysis_runs
                        SET assurance_state = ?, assurance_reasons_json = ?
                        WHERE id IN (\(databaseQuestionMarks(count: impactedRuns.count)))
                        """,
                    arguments: StatementArguments(arguments)
                )
            }
            let impactedVersions = impactedVersionIDs.sorted()
            if !impactedVersions.isEmpty {
                var versionArguments: [DatabaseValueConvertible] = [
                    OutputAssuranceState.stale.rawValue,
                    staleReason,
                    timestamp,
                ]
                versionArguments.append(contentsOf: impactedVersions)
                try db.execute(
                    sql: """
                        UPDATE structured_output_versions
                        SET assurance_state = ?, stale_reason = ?, updated_at = ?
                        WHERE id IN (\(databaseQuestionMarks(count: impactedVersions.count)))
                        """,
                    arguments: StatementArguments(versionArguments)
                )
                var outputArguments: [DatabaseValueConvertible] = [
                    StructuredOutputStatus.needsReview.rawValue,
                    timestamp,
                ]
                outputArguments.append(contentsOf: impactedVersions)
                try db.execute(
                    sql: """
                        UPDATE structured_outputs
                        SET status = ?, updated_at = ?
                        WHERE active_version_id IN (
                            \(databaseQuestionMarks(count: impactedVersions.count))
                        )
                        """,
                    arguments: StatementArguments(outputArguments)
                )
            }

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
            for blobID in blobIDs.sorted() {
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
            let metadataJSON = try Self.canonicalJSON([
                "schema_version": 1,
                "matter_id": root.matterID,
                "document_id": id,
                "removed_document_ids": subtreeIDs.sorted(),
                "invalidated_output_version_ids": impactedVersions,
                "invalidated_corpus_run_ids": impactedRuns,
            ])
            try AuditEventRecord(
                matterID: root.matterID,
                timestamp: timestamp,
                eventType: "document_permanently_deleted",
                actor: normalizedActor,
                summary: "Permanently deleted document source data and invalidated dependent work.",
                relatedTable: MatterDocumentRecord.databaseTableName,
                relatedID: id,
                metadataJSON: metadataJSON
            ).insert(db)
            return PermanentDeleteResult(
                removedBlobPaths: removedPaths.sorted(),
                removedDocumentIDs: subtreeIDs
            )
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
    private static func documentSubtreeIDs(
        _ db: Database,
        rootID: String,
        matterID: String
    ) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var queue: [String] = [rootID]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            // Cycle guard against a corrupted/cyclic parent pointer.
            guard seen.insert(current).inserted else { continue }
            result.append(current)
            let children = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM matter_documents
                    WHERE parent_document_id = ? AND matter_id = ?
                    ORDER BY id
                    """,
                arguments: [current, matterID]
            )
            queue.append(contentsOf: children)
        }
        return result
    }

    private static func isSemanticallyValidDeletionSnapshot(
        _ snapshot: CorpusAnalysisSnapshot
    ) -> Bool {
        guard snapshot.schemaVersion > 0 else { return false }
        var memberKeys = Set<String>()
        for member in snapshot.members {
            guard !member.memberKey.isEmpty,
                  !member.displayName.isEmpty,
                  member.documentID.map({ !$0.isEmpty }) ?? true,
                  member.revisionIDs.allSatisfy({ !$0.isEmpty }),
                  Set(member.revisionIDs).count == member.revisionIDs.count,
                  memberKeys.insert(member.memberKey).inserted else {
                return false
            }
            if member.disposition == .eligible {
                guard member.documentID != nil, !member.revisionIDs.isEmpty else {
                    return false
                }
            }
        }
        return true
    }

    private static func canonicalJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
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

enum DocumentAttachmentIntegrity {
    static func validateParentScope(
        _ document: MatterDocumentRecord,
        in db: Database
    ) throws {
        guard let parentID = document.parentDocumentID else { return }
        guard let parent = try MatterDocumentRecord.fetchOne(db, key: parentID) else {
            throw DocumentAttachmentIntegrityError.parentUnavailable(parentID)
        }
        guard parent.matterID == document.matterID else {
            throw DocumentAttachmentIntegrityError.crossMatterParent(
                childID: document.id,
                parentID: parentID
            )
        }
    }

    static func validateDeletionBoundary(
        parentIDs: [String],
        matterID: String,
        in db: Database
    ) throws {
        guard !parentIDs.isEmpty else { return }
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT child.id AS child_id, child.parent_document_id AS parent_id
                FROM matter_documents AS child
                WHERE child.parent_document_id IN (
                    \(databaseQuestionMarks(count: parentIDs.count))
                )
                  AND child.matter_id <> ?
                ORDER BY child.id
                LIMIT 1
                """,
            arguments: StatementArguments(parentIDs + [matterID])
        ) {
            throw DocumentAttachmentIntegrityError.crossMatterDeletionBoundary(
                childID: row["child_id"],
                parentID: row["parent_id"]
            )
        }
    }
}

public enum DocumentAttachmentIntegrityError: Error, LocalizedError, Equatable, Sendable {
    case parentUnavailable(String)
    case crossMatterParent(childID: String, parentID: String)
    case crossMatterDeletionBoundary(childID: String, parentID: String)

    public var errorDescription: String? {
        switch self {
        case .parentUnavailable(let parentID):
            "The parent document \(parentID) is unavailable."
        case .crossMatterParent:
            "An attachment cannot use a parent document from another matter."
        case .crossMatterDeletionBoundary:
            "Permanent deletion stopped because an attachment crosses a matter boundary."
        }
    }
}
