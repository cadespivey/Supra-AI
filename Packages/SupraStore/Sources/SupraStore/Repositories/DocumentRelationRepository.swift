import Foundation
import GRDB
import SupraCore

public enum DocumentRelationRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case documentMatterMismatch(String)
    case selfRelation(String)
    case invalidEvidenceJSON
    case invalidConfidence(Double)
    case relationIdentityCollision(String)

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

        return try writer.write { db in
            for documentID in [fromDocumentID, toDocumentID] {
                guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID),
                      document.matterID == matterID else {
                    throw DocumentRelationRepositoryError.documentMatterMismatch(documentID)
                }
            }
            let identity = Self.identity(
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
