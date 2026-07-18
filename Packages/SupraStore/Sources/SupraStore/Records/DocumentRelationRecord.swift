import Foundation
import GRDB

public struct DocumentRelationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_relations"

    public var id: String
    public var matterID: String
    public var relationKey: String
    public var fromDocumentID: String
    public var toDocumentID: String
    public var kind: String
    public var evidenceJSON: String
    public var confidence: Double?
    public var proposedBy: String?
    public var reviewState: String
    public var reviewedBy: String?
    public var reviewedAt: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        relationKey: String,
        fromDocumentID: String,
        toDocumentID: String,
        kind: String,
        evidenceJSON: String,
        confidence: Double? = nil,
        proposedBy: String? = nil,
        reviewState: String,
        reviewedBy: String? = nil,
        reviewedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.relationKey = relationKey
        self.fromDocumentID = fromDocumentID
        self.toDocumentID = toDocumentID
        self.kind = kind
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.proposedBy = proposedBy
        self.reviewState = reviewState
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case relationKey = "relation_key"
        case fromDocumentID = "from_document_id"
        case toDocumentID = "to_document_id"
        case kind
        case evidenceJSON = "evidence_json"
        case confidence
        case proposedBy = "proposed_by"
        case reviewState = "review_state"
        case reviewedBy = "reviewed_by"
        case reviewedAt = "reviewed_at"
        case createdAt = "created_at"
    }
}
