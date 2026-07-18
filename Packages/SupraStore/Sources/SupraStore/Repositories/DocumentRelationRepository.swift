import Foundation
import GRDB
import SupraCore

public enum DocumentRelationRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case documentMatterMismatch(String)
    case selfRelation(String)
    case invalidEvidenceJSON
    case invalidConfidence(Double)
    case relationIdentityCollision(String)
    case relationNotFound(String)
    case invalidReviewDecision(DocumentRelationReviewState)
    case invalidReviewTransition(from: DocumentRelationReviewState, to: DocumentRelationReviewState)
    case overrideRequiresRejectedRelation(String)

    public var errorDescription: String? {
        switch self {
        case .documentMatterMismatch(let id):
            "Document \(id) does not belong to the selected matter."
        case .selfRelation(let id):
            "Document \(id) cannot be related to itself."
        case .invalidEvidenceJSON:
            "Relation evidence must be a JSON object."
        case .invalidConfidence(let confidence):
            "Relation confidence \(confidence) is outside 0...1."
        case .relationIdentityCollision(let key):
            "Relation key \(key) was reused with different immutable evidence."
        case .relationNotFound(let id):
            "Document relation \(id) was not found in the selected matter."
        case .invalidReviewDecision(let decision):
            "A relation review cannot transition to \(decision.rawValue)."
        case .invalidReviewTransition(let from, let to):
            "A relation review cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .overrideRequiresRejectedRelation(let id):
            "Relation \(id) must be rejected before it can be replaced by an override."
        }
    }
}

/// Matter-scoped, proposal-first relation persistence. Similarity and exact
/// matches can only create `proposed` rows; review transitions land with the
/// dedicated review workflow so confidence can never silently choose an
/// operative document.
public final class DocumentRelationRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func propose(
        matterID: String,
        fromDocumentID: String,
        toDocumentID: String,
        kind: DocumentRelationKind,
        evidenceJSON: String,
        confidence: Double? = nil,
        proposedBy: DocumentRelationProposer
    ) throws -> DocumentRelationRecord {
        return try writer.write { db in
            try Self.propose(
                db: db,
                matterID: matterID,
                fromDocumentID: fromDocumentID,
                toDocumentID: toDocumentID,
                kind: kind,
                evidenceJSON: evidenceJSON,
                confidence: confidence,
                proposedBy: proposedBy
            )
        }
    }

    /// Performs the only legal mutation of a relation row. The transition,
    /// audit event, and visible invalidation of outputs citing either document
    /// share one transaction so a crash cannot expose a reviewed relation
    /// without its provenance consequences.
    @discardableResult
    public func review(
        matterID: String,
        id: String,
        decision: DocumentRelationReviewState,
        reviewedBy: String,
        reviewedAt: Date = Date()
    ) throws -> DocumentRelationRecord {
        guard decision == .confirmed || decision == .rejected else {
            throw DocumentRelationRepositoryError.invalidReviewDecision(decision)
        }
        return try writer.write { db in
            guard let existing = try DocumentRelationRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_relations WHERE matter_id = ? AND id = ?",
                arguments: [matterID, id]
            ) else {
                throw DocumentRelationRepositoryError.relationNotFound(id)
            }
            let current = DocumentRelationReviewState(rawValue: existing.reviewState) ?? .proposed
            guard current == .proposed else {
                throw DocumentRelationRepositoryError.invalidReviewTransition(
                    from: current,
                    to: decision
                )
            }

            try db.execute(
                sql: """
                UPDATE document_relations
                SET review_state = ?, reviewed_by = ?, reviewed_at = ?
                WHERE matter_id = ? AND id = ? AND review_state = ?
                """,
                arguments: [
                    decision.rawValue, reviewedBy, reviewedAt, matterID, id,
                    DocumentRelationReviewState.proposed.rawValue,
                ]
            )
            guard db.changesCount == 1,
                  let reviewed = try DocumentRelationRecord.fetchOne(db, key: id) else {
                throw DocumentRelationRepositoryError.invalidReviewTransition(
                    from: current,
                    to: decision
                )
            }

            let metadata = try Self.auditMetadata([
                "schema_version": 1,
                "old_review_state": current.rawValue,
                "new_review_state": decision.rawValue,
                "relation_kind": existing.kind,
                "from_document_id": existing.fromDocumentID,
                "to_document_id": existing.toDocumentID,
                "evidence_json": existing.evidenceJSON,
            ])
            try AuditEventRecord(
                matterID: matterID,
                timestamp: reviewedAt,
                eventType: "document_relation_reviewed",
                actor: reviewedBy,
                summary: "\(decision == .confirmed ? "Confirmed" : "Rejected") \(existing.kind) document relation",
                relatedTable: DocumentRelationRecord.databaseTableName,
                relatedID: id,
                metadataJSON: metadata
            ).insert(db)

            try Self.invalidateOutputsCitingRelation(reviewed, reviewedAt: reviewedAt, db: db)
            return reviewed
        }
    }

    /// Creates a distinct user-authored proposal to replace a retained rejected
    /// row. The immutable old and new evidence are recorded together; confirmation
    /// still travels through `review` so no override can silently become operative.
    @discardableResult
    public func proposeUserOverride(
        matterID: String,
        replacingRelationID: String,
        fromDocumentID: String,
        toDocumentID: String,
        kind: DocumentRelationKind,
        evidenceJSON: String,
        actor: String,
        createdAt: Date = Date()
    ) throws -> DocumentRelationRecord {
        try writer.write { db in
            guard let replaced = try DocumentRelationRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_relations WHERE matter_id = ? AND id = ?",
                arguments: [matterID, replacingRelationID]
            ) else {
                throw DocumentRelationRepositoryError.relationNotFound(replacingRelationID)
            }
            guard replaced.reviewState == DocumentRelationReviewState.rejected.rawValue else {
                throw DocumentRelationRepositoryError.overrideRequiresRejectedRelation(replacingRelationID)
            }
            let override = try Self.propose(
                db: db,
                matterID: matterID,
                fromDocumentID: fromDocumentID,
                toDocumentID: toDocumentID,
                kind: kind,
                evidenceJSON: evidenceJSON,
                confidence: nil,
                proposedBy: .user
            )
            let metadata = try Self.auditMetadata([
                "schema_version": 1,
                "replaced_relation_id": replaced.id,
                "old_evidence_json": replaced.evidenceJSON,
                "new_evidence_json": override.evidenceJSON,
                "new_relation_kind": override.kind,
                "new_from_document_id": override.fromDocumentID,
                "new_to_document_id": override.toDocumentID,
            ])
            try AuditEventRecord(
                matterID: matterID,
                timestamp: createdAt,
                eventType: "document_relation_override_created",
                actor: actor,
                summary: "Created user override for rejected \(replaced.kind) relation",
                relatedTable: DocumentRelationRecord.databaseTableName,
                relatedID: override.id,
                metadataJSON: metadata
            ).insert(db)
            return override
        }
    }

    public func fetchAll(matterID: String) throws -> [DocumentRelationRecord] {
        try writer.read { db in
            try DocumentRelationRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_relations
                WHERE matter_id = ?
                ORDER BY relation_key, kind, created_at, id
                """,
                arguments: [matterID]
            )
        }
    }

    public func fetchConfirmed(matterID: String) throws -> [DocumentRelationRecord] {
        try writer.read { db in
            try DocumentRelationRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_relations
                WHERE matter_id = ? AND review_state = ?
                ORDER BY relation_key, kind, created_at, id
                """,
                arguments: [matterID, DocumentRelationReviewState.confirmed.rawValue]
            )
        }
    }

    public func fetch(matterID: String, id: String) throws -> DocumentRelationRecord? {
        try writer.read { db in
            try DocumentRelationRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_relations WHERE matter_id = ? AND id = ?",
                arguments: [matterID, id]
            )
        }
    }

    private static func propose(
        db: Database,
        matterID: String,
        fromDocumentID: String,
        toDocumentID: String,
        kind: DocumentRelationKind,
        evidenceJSON: String,
        confidence: Double?,
        proposedBy: DocumentRelationProposer
    ) throws -> DocumentRelationRecord {
        guard fromDocumentID != toDocumentID else {
            throw DocumentRelationRepositoryError.selfRelation(fromDocumentID)
        }
        if let confidence, !(0...1).contains(confidence) {
            throw DocumentRelationRepositoryError.invalidConfidence(confidence)
        }
        guard let evidenceData = evidenceJSON.data(using: .utf8),
              let evidence = try? JSONSerialization.jsonObject(with: evidenceData),
              evidence is [String: Any] else {
            throw DocumentRelationRepositoryError.invalidEvidenceJSON
        }
        for documentID in [fromDocumentID, toDocumentID] {
            guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID),
                  document.matterID == matterID else {
                throw DocumentRelationRepositoryError.documentMatterMismatch(documentID)
            }
        }
        let identity = identity(
            fromDocumentID: fromDocumentID,
            toDocumentID: toDocumentID,
            kind: kind
        )
        if let existing = try DocumentRelationRecord.fetchOne(
            db,
            sql: """
            SELECT * FROM document_relations
            WHERE matter_id = ? AND relation_key = ? AND kind = ?
            """,
            arguments: [matterID, identity.key, kind.rawValue]
        ) {
            guard existing.fromDocumentID == identity.from,
                  existing.toDocumentID == identity.to,
                  existing.evidenceJSON == evidenceJSON,
                  existing.confidence == confidence,
                  existing.proposedBy == proposedBy.rawValue else {
                throw DocumentRelationRepositoryError.relationIdentityCollision(identity.key)
            }
            return existing
        }
        let record = DocumentRelationRecord(
            matterID: matterID,
            relationKey: identity.key,
            fromDocumentID: identity.from,
            toDocumentID: identity.to,
            kind: kind.rawValue,
            evidenceJSON: evidenceJSON,
            confidence: confidence,
            proposedBy: proposedBy.rawValue,
            reviewState: DocumentRelationReviewState.proposed.rawValue
        )
        try record.insert(db)
        return record
    }

    private static func invalidateOutputsCitingRelation(
        _ relation: DocumentRelationRecord,
        reviewedAt: Date,
        db: Database
    ) throws {
        let reason = "document_relation_reviewed:relation=\(relation.id):state=\(relation.reviewState)"
        try db.execute(
            sql: """
            UPDATE structured_output_versions
            SET assurance_state = ?, stale_reason = ?, updated_at = ?
            WHERE assurance_state IS NOT ?
              AND id IN (
                  SELECT structured_output_version_id
                  FROM document_output_sources
                  WHERE document_id IN (?, ?)
                    AND structured_output_version_id IS NOT NULL
              )
              AND structured_output_id IN (
                  SELECT id FROM structured_outputs WHERE matter_id = ?
              )
            """,
            arguments: [
                OutputAssuranceState.stale.rawValue,
                reason,
                reviewedAt,
                OutputAssuranceState.stale.rawValue,
                relation.fromDocumentID,
                relation.toDocumentID,
                relation.matterID,
            ]
        )
        try db.execute(
            sql: """
            UPDATE structured_outputs
            SET status = ?, updated_at = ?
            WHERE matter_id = ?
              AND deleted_at IS NULL
              AND active_version_id IN (
                  SELECT structured_output_version_id
                  FROM document_output_sources
                  WHERE document_id IN (?, ?)
                    AND structured_output_version_id IS NOT NULL
              )
            """,
            arguments: [
                StructuredOutputStatus.needsReview.rawValue,
                reviewedAt,
                relation.matterID,
                relation.fromDocumentID,
                relation.toDocumentID,
            ]
        )
    }

    private static func auditMetadata(_ object: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private static func identity(
        fromDocumentID: String,
        toDocumentID: String,
        kind: DocumentRelationKind
    ) -> (from: String, to: String, key: String) {
        if kind.isSymmetric {
            let ordered = [fromDocumentID, toDocumentID].sorted()
            return (ordered[0], ordered[1], "\(ordered[0])|\(ordered[1])")
        }
        return (fromDocumentID, toDocumentID, "\(fromDocumentID)->\(toDocumentID)")
    }
}
