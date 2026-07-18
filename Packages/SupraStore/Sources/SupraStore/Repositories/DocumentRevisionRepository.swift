import Foundation
import GRDB

public enum DocumentRevisionRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case derivationKeyCollision(String)
    case selectionKeyCollision(String)
    case revisionScopeMismatch(String)
    case selectionScopeMismatch(String)
    case partNotFound(documentID: String, partIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .derivationKeyCollision(let key):
            "Revision derivation key \(key) was reused for different immutable content."
        case .selectionKeyCollision(let key):
            "Selection key \(key) was reused for a different decision."
        case .revisionScopeMismatch(let id):
            "Revision \(id) does not belong to the selected document part."
        case .selectionScopeMismatch(let id):
            "Selection \(id) does not belong to the selected document part."
        case .partNotFound(let documentID, let partIndex):
            "Document part \(documentID)#\(partIndex) does not exist."
        }
    }
}

/// Owns immutable extraction candidates and append-only selection decisions.
public final class DocumentRevisionRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Appends a candidate, or returns the existing immutable row when a retry
    /// presents the same document/part/derivation key and payload.
    @discardableResult
    public func appendRevision(_ revision: DocumentPartRevisionRecord) throws -> DocumentPartRevisionRecord {
        try writer.write { db in
            try appendRevision(revision, db: db)
        }
    }

    /// Appends a decision and atomically materializes its chosen text/pointers on
    /// the compatible part row. Retrying an existing selection key is idempotent
    /// and never rolls a part back from a later selection.
    @discardableResult
    public func appendSelection(_ selection: DocumentPartSelectionRecord) throws -> DocumentPartSelectionRecord {
        try writer.write { db in
            try appendSelection(selection, materializeExisting: false, db: db)
        }
    }

    /// Appends one intentional user correction and its selection atomically.
    /// The compatible part text is only the materialized projection; the prior
    /// machine/user revision and selection remain immutable and queryable.
    @discardableResult
    public func appendUserEdit(
        documentID: String,
        partID: String,
        text: String,
        author: String,
        reason: String
    ) throws -> DocumentPartRevisionRecord {
        try writer.write { db in
            guard let part = try DocumentPagePartRecord.fetchOne(db, key: partID),
                  part.documentID == documentID else {
                throw DocumentRevisionRepositoryError.partNotFound(documentID: documentID, partIndex: -1)
            }
            guard let priorRevisionID = part.currentRevisionID,
                  try DocumentPartRevisionRecord.fetchOne(db, key: priorRevisionID) != nil else {
                throw DocumentRevisionRepositoryError.revisionScopeMismatch(part.currentRevisionID ?? partID)
            }

            let revision = DocumentPartRevisionRecord(
                documentID: documentID,
                partIndex: part.partIndex,
                derivationKey: "user-edit:\(UUID().uuidString)",
                origin: "user_edit",
                method: "manual",
                text: text,
                charCount: text.count,
                author: author,
                reason: reason,
                supersedesRevisionID: priorRevisionID
            )
            _ = try appendRevision(revision, db: db)
            let decisionObject: [String: Any] = [
                "author": author,
                "reason": reason,
                "rule": "user_edit",
                "selectedRevisionID": revision.id,
            ]
            let decisionData = try JSONSerialization.data(
                withJSONObject: decisionObject,
                options: [.sortedKeys]
            )
            let selection = DocumentPartSelectionRecord(
                documentID: documentID,
                partIndex: part.partIndex,
                selectedRevisionID: revision.id,
                selectionKey: "user-edit:\(UUID().uuidString)",
                selectedBy: "user",
                policyVersion: nil,
                decisionJSON: String(decoding: decisionData, as: UTF8.self),
                supersedesSelectionID: part.currentSelectionID
            )
            _ = try appendSelection(selection, materializeExisting: false, db: db)
            return revision
        }
    }

    /// Atomically replaces the compatible part projection while preserving all
    /// historical revisions/selections and appending the supplied new lineage.
    @discardableResult
    public func replacePartsAndPersistLineage(
        documentID: String,
        parts: [DocumentPagePartRecord],
        revisions: [DocumentPartRevisionRecord],
        selections: [DocumentPartSelectionRecord],
        preserveSelectedUserEdits: Bool = false
    ) throws -> Set<Int> {
        try writer.write { db in
            guard parts.allSatisfy({ $0.documentID == documentID }),
                  revisions.allSatisfy({ $0.documentID == documentID }),
                  selections.allSatisfy({ $0.documentID == documentID }) else {
                throw DocumentRevisionRepositoryError.revisionScopeMismatch(documentID)
            }

            var preservedSelections: [Int: (DocumentPartSelectionRecord, DocumentPartRevisionRecord)] = [:]
            if preserveSelectedUserEdits {
                let currentParts = try DocumentPagePartRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM document_pages_parts WHERE document_id = ?",
                    arguments: [documentID]
                )
                for part in currentParts {
                    guard let revisionID = part.currentRevisionID,
                          let selectionID = part.currentSelectionID,
                          let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                          revision.origin == "user_edit",
                          let selection = try DocumentPartSelectionRecord.fetchOne(db, key: selectionID)
                    else { continue }
                    preservedSelections[part.partIndex] = (selection, revision)
                }
            }

            try db.execute(
                sql: "DELETE FROM document_pages_parts WHERE document_id = ?",
                arguments: [documentID]
            )
            for var part in parts {
                // Candidates and decisions are inserted after the compatible part,
                // then the chosen revision is materialized transactionally.
                part.currentRevisionID = nil
                part.currentSelectionID = nil
                try part.insert(db)
            }
            for revision in revisions {
                _ = try appendRevision(revision, db: db)
            }
            for selection in selections where preservedSelections[selection.partIndex] == nil {
                _ = try appendSelection(selection, materializeExisting: true, db: db)
            }
            for (_, preserved) in preservedSelections {
                try materialize(preserved.0, revision: preserved.1, db: db)
            }
            return Set(preservedSelections.keys)
        }
    }

    public func fetchRevisions(documentID: String, partIndex: Int) throws -> [DocumentPartRevisionRecord] {
        try writer.read { db in
            try DocumentPartRevisionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_part_revisions
                WHERE document_id = ? AND part_index = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                arguments: [documentID, partIndex]
            )
        }
    }

    public func fetchSelections(documentID: String, partIndex: Int) throws -> [DocumentPartSelectionRecord] {
        try writer.read { db in
            try DocumentPartSelectionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_part_selections
                WHERE document_id = ? AND part_index = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                arguments: [documentID, partIndex]
            )
        }
    }

    public func fetchRevision(id: String) throws -> DocumentPartRevisionRecord? {
        try writer.read { db in try DocumentPartRevisionRecord.fetchOne(db, key: id) }
    }

    private func appendRevision(
        _ revision: DocumentPartRevisionRecord,
        db: Database
    ) throws -> DocumentPartRevisionRecord {
        if let existing = try DocumentPartRevisionRecord.fetchOne(
            db,
            sql: """
            SELECT * FROM document_part_revisions
            WHERE document_id = ? AND part_index = ? AND derivation_key = ?
            """,
            arguments: [revision.documentID, revision.partIndex, revision.derivationKey]
        ) {
            guard existing.origin == revision.origin,
                  existing.method == revision.method,
                  existing.text == revision.text,
                  existing.charCount == revision.charCount,
                  existing.ocrConfidence == revision.ocrConfidence,
                  existing.boundingBoxesJSON == revision.boundingBoxesJSON,
                  existing.toolchainVersion == revision.toolchainVersion,
                  existing.author == revision.author,
                  existing.reason == revision.reason,
                  existing.supersedesRevisionID == revision.supersedesRevisionID else {
                throw DocumentRevisionRepositoryError.derivationKeyCollision(revision.derivationKey)
            }
            return existing
        }

        if let supersedesID = revision.supersedesRevisionID {
            guard let superseded = try DocumentPartRevisionRecord.fetchOne(db, key: supersedesID),
                  superseded.documentID == revision.documentID,
                  superseded.partIndex == revision.partIndex else {
                throw DocumentRevisionRepositoryError.revisionScopeMismatch(supersedesID)
            }
        }
        try revision.insert(db)
        return revision
    }

    private func appendSelection(
        _ selection: DocumentPartSelectionRecord,
        materializeExisting: Bool,
        db: Database
    ) throws -> DocumentPartSelectionRecord {
        guard let revision = try DocumentPartRevisionRecord.fetchOne(db, key: selection.selectedRevisionID),
              revision.documentID == selection.documentID,
              revision.partIndex == selection.partIndex else {
            throw DocumentRevisionRepositoryError.revisionScopeMismatch(selection.selectedRevisionID)
        }

        if let existing = try DocumentPartSelectionRecord.fetchOne(
            db,
            sql: """
            SELECT * FROM document_part_selections
            WHERE document_id = ? AND part_index = ? AND selection_key = ?
            """,
            arguments: [selection.documentID, selection.partIndex, selection.selectionKey]
        ) {
            guard existing.selectedRevisionID == selection.selectedRevisionID,
                  existing.selectedBy == selection.selectedBy,
                  existing.policyVersion == selection.policyVersion,
                  decisionPayloadsEqual(existing.decisionJSON, selection.decisionJSON),
                  existing.supersedesSelectionID == selection.supersedesSelectionID else {
                throw DocumentRevisionRepositoryError.selectionKeyCollision(selection.selectionKey)
            }
            if materializeExisting {
                try materialize(existing, revision: revision, db: db)
            }
            return existing
        }

        if let supersedesID = selection.supersedesSelectionID {
            guard let superseded = try DocumentPartSelectionRecord.fetchOne(db, key: supersedesID),
                  superseded.documentID == selection.documentID,
                  superseded.partIndex == selection.partIndex else {
                throw DocumentRevisionRepositoryError.selectionScopeMismatch(supersedesID)
            }
        }
        try selection.insert(db)
        try materialize(selection, revision: revision, db: db)
        return selection
    }

    private func materialize(
        _ selection: DocumentPartSelectionRecord,
        revision: DocumentPartRevisionRecord,
        db: Database
    ) throws {
        guard try DocumentPagePartRecord.fetchOne(
            db,
            sql: "SELECT * FROM document_pages_parts WHERE document_id = ? AND part_index = ?",
            arguments: [selection.documentID, selection.partIndex]
        ) != nil else {
            throw DocumentRevisionRepositoryError.partNotFound(
                documentID: selection.documentID,
                partIndex: selection.partIndex
            )
        }
        try db.execute(
            sql: """
            UPDATE document_pages_parts
            SET current_revision_id = ?, current_selection_id = ?,
                normalized_text = ?, char_count = ?, ocr_confidence = ?,
                bounding_boxes_json = ?, updated_at = ?
            WHERE document_id = ? AND part_index = ?
            """,
            arguments: [
                revision.id, selection.id, revision.text, revision.charCount,
                revision.ocrConfidence, revision.boundingBoxesJSON, Date(),
                selection.documentID, selection.partIndex,
            ]
        )
    }

    private func decisionPayloadsEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let lhsObject = try? JSONSerialization.jsonObject(with: Data(lhs.utf8)) as? NSObject,
              let rhsObject = try? JSONSerialization.jsonObject(with: Data(rhs.utf8)) as? NSObject else {
            return false
        }
        return lhsObject.isEqual(rhsObject)
    }
}
