import Foundation
import GRDB

public enum DocumentClassificationRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case documentMatterMismatch(String)
    case revisionScopeMismatch(String)
    case classificationKeyCollision(String)
    case invalidJSON(String)
    case invalidRecord(String)

    public var errorDescription: String? {
        switch self {
        case .documentMatterMismatch(let id):
            "Document \(id) does not belong to the selected matter."
        case .revisionScopeMismatch(let id):
            "Revision \(id) does not belong to the classified document."
        case .classificationKeyCollision(let key):
            "Classification key \(key) was reused with a different immutable payload."
        case .invalidJSON(let field):
            "Classification field \(field) is not valid JSON of the required shape."
        case .invalidRecord(let reason):
            "Classification record is invalid: \(reason)."
        }
    }
}

/// Sole writer for append-only classification lineage. It validates matter and
/// revision scope before insertion and can atomically update the compatible
/// latest-value JSON projection without touching user-authored document tags.
public final class DocumentClassificationRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func append(_ record: DocumentClassificationRecord) throws -> DocumentClassificationRecord {
        try writer.write { db in
            try Self.append(record, legacyProjectionJSON: nil, db: db).record
        }
    }

    /// Appends a new authoritative attempt and materializes its legacy JSON in
    /// the same transaction. An idempotent retry never rolls the projection back
    /// over a newer classification attempt.
    @discardableResult
    public func appendAndProjectLegacy(
        _ record: DocumentClassificationRecord,
        legacyProjectionJSON: String
    ) throws -> DocumentClassificationRecord {
        try writer.write { db in
            let result = try Self.append(record, legacyProjectionJSON: legacyProjectionJSON, db: db)
            if result.inserted {
                try db.execute(
                    sql: "UPDATE matter_documents SET classification_metadata_json = ?, updated_at = ? WHERE id = ? AND matter_id = ?",
                    arguments: [legacyProjectionJSON, record.createdAt, record.documentID, record.matterID]
                )
                guard db.changesCount == 1 else {
                    throw DocumentClassificationRepositoryError.documentMatterMismatch(record.documentID)
                }
            }
            return result.record
        }
    }

    public func fetchLatest(matterID: String, documentID: String) throws -> DocumentClassificationRecord? {
        try writer.read { db in
            try DocumentClassificationRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM document_classifications
                WHERE matter_id = ? AND document_id = ?
                ORDER BY created_at DESC, rowid DESC
                LIMIT 1
                """,
                arguments: [matterID, documentID]
            )
        }
    }

    public func fetchHistory(matterID: String, documentID: String) throws -> [DocumentClassificationRecord] {
        try writer.read { db in
            try DocumentClassificationRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_classifications
                WHERE matter_id = ? AND document_id = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                arguments: [matterID, documentID]
            )
        }
    }

    private static func append(
        _ record: DocumentClassificationRecord,
        legacyProjectionJSON: String?,
        db: Database
    ) throws -> (record: DocumentClassificationRecord, inserted: Bool) {
        try validate(record, db: db)
        if let legacyProjectionJSON {
            guard jsonValue(legacyProjectionJSON) is [String: Any] else {
                throw DocumentClassificationRepositoryError.invalidJSON("legacy_projection")
            }
        }
        if let existing = try DocumentClassificationRecord.fetchOne(
            db,
            sql: """
            SELECT * FROM document_classifications
            WHERE matter_id = ? AND document_id = ? AND classification_key = ?
            """,
            arguments: [record.matterID, record.documentID, record.classificationKey]
        ) {
            guard samePayload(existing, record) else {
                throw DocumentClassificationRepositoryError.classificationKeyCollision(record.classificationKey)
            }
            return (existing, false)
        }
        try record.insert(db)
        return (record, true)
    }

    private static func validate(_ record: DocumentClassificationRecord, db: Database) throws {
        guard !record.classificationKey.isEmpty,
              !record.inputChecksum.isEmpty,
              !record.modelRepository.isEmpty,
              !record.modelRevision.isEmpty,
              !record.promptVersion.isEmpty,
              !record.samplingStrategy.isEmpty,
              record.samplingVersion > 0,
              !record.calibrationVersion.isEmpty else {
            throw DocumentClassificationRepositoryError.invalidRecord("required lineage field is empty")
        }
        guard let matterID = try String.fetchOne(
            db,
            sql: "SELECT matter_id FROM matter_documents WHERE id = ?",
            arguments: [record.documentID]
        ), matterID == record.matterID else {
            throw DocumentClassificationRepositoryError.documentMatterMismatch(record.documentID)
        }
        guard let revisionIDs = stringArray(record.inputRevisionIDsJSON),
              !revisionIDs.isEmpty,
              Set(revisionIDs).count == revisionIDs.count else {
            throw DocumentClassificationRepositoryError.invalidJSON("input_revision_ids_json")
        }
        for revisionID in revisionIDs {
            guard let documentID = try String.fetchOne(
                db,
                sql: "SELECT document_id FROM document_part_revisions WHERE id = ?",
                arguments: [revisionID]
            ), documentID == record.documentID else {
                throw DocumentClassificationRepositoryError.revisionScopeMismatch(revisionID)
            }
        }
        guard stringArray(record.secondaryCategoriesJSON) != nil else {
            throw DocumentClassificationRepositoryError.invalidJSON("secondary_categories_json")
        }
        guard let confidence = jsonValue(record.confidenceJSON) as? [String: Any],
              let rawConfidence = confidence["raw_confidence"] as? Double,
              rawConfidence.isFinite,
              let abstentionFloor = confidence["abstention_floor"] as? Double,
              abstentionFloor.isFinite,
              (0...1).contains(abstentionFloor),
              let rawCategory = confidence["raw_suggested_primary_category"] as? String,
              !rawCategory.isEmpty else {
            throw DocumentClassificationRepositoryError.invalidJSON("confidence_json")
        }
        guard let evidenceSpans = jsonValue(record.evidenceSpansJSON) as? [[String: Any]] else {
            throw DocumentClassificationRepositoryError.invalidJSON("evidence_spans_json")
        }
        let inputRevisionIDs = Set(revisionIDs)
        for span in evidenceSpans {
            guard let revisionID = span["revision_id"] as? String,
                  inputRevisionIDs.contains(revisionID),
                  let startOffset = span["char_start"] as? Int,
                  let endOffset = span["char_end"] as? Int,
                  let excerpt = span["excerpt"] as? String,
                  let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                  startOffset >= 0,
                  endOffset > startOffset,
                  endOffset <= revision.text.count else {
                throw DocumentClassificationRepositoryError.invalidJSON("evidence_spans_json")
            }
            let start = revision.text.index(revision.text.startIndex, offsetBy: startOffset)
            let end = revision.text.index(revision.text.startIndex, offsetBy: endOffset)
            guard String(revision.text[start..<end]) == excerpt else {
                throw DocumentClassificationRepositoryError.invalidJSON("evidence_spans_json")
            }
        }
        guard stringArray(record.warningsJSON) != nil else {
            throw DocumentClassificationRepositoryError.invalidJSON("warnings_json")
        }
        if record.abstained {
            guard record.primaryCategory == nil,
                  let reason = record.abstentionReason,
                  !reason.isEmpty else {
                throw DocumentClassificationRepositoryError.invalidRecord("abstention requires a reason and no primary category")
            }
        } else {
            guard let primary = record.primaryCategory, !primary.isEmpty,
                  record.abstentionReason == nil,
                  !evidenceSpans.isEmpty else {
                throw DocumentClassificationRepositoryError.invalidRecord("non-abstention requires a primary category and no abstention reason")
            }
        }
    }

    private static func samePayload(
        _ lhs: DocumentClassificationRecord,
        _ rhs: DocumentClassificationRecord
    ) -> Bool {
        lhs.matterID == rhs.matterID
            && lhs.documentID == rhs.documentID
            && lhs.classificationKey == rhs.classificationKey
            && lhs.inputRevisionIDsJSON == rhs.inputRevisionIDsJSON
            && lhs.inputChecksum == rhs.inputChecksum
            && lhs.modelRepository == rhs.modelRepository
            && lhs.modelRevision == rhs.modelRevision
            && lhs.promptVersion == rhs.promptVersion
            && lhs.samplingStrategy == rhs.samplingStrategy
            && lhs.samplingVersion == rhs.samplingVersion
            && lhs.primaryCategory == rhs.primaryCategory
            && lhs.secondaryCategoriesJSON == rhs.secondaryCategoriesJSON
            && lhs.confidenceJSON == rhs.confidenceJSON
            && lhs.calibrationVersion == rhs.calibrationVersion
            && lhs.abstained == rhs.abstained
            && lhs.abstentionReason == rhs.abstentionReason
            && lhs.evidenceSpansJSON == rhs.evidenceSpansJSON
            && lhs.warningsJSON == rhs.warningsJSON
    }

    private static func jsonValue(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private static func stringArray(_ json: String) -> [String]? {
        jsonValue(json) as? [String]
    }
}
