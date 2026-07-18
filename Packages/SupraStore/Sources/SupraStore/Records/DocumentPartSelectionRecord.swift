import Foundation
import GRDB

/// Append-only decision selecting one immutable revision as a part's materialized text.
public struct DocumentPartSelectionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_part_selections"

    public var id: String
    public var documentID: String
    public var partIndex: Int
    public var selectedRevisionID: String
    public var selectionKey: String
    public var selectedBy: String
    public var policyVersion: Int?
    public var decisionJSON: String
    public var supersedesSelectionID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        documentID: String,
        partIndex: Int,
        selectedRevisionID: String,
        selectionKey: String,
        selectedBy: String,
        policyVersion: Int? = nil,
        decisionJSON: String,
        supersedesSelectionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.partIndex = partIndex
        self.selectedRevisionID = selectedRevisionID
        self.selectionKey = selectionKey
        self.selectedBy = selectedBy
        self.policyVersion = policyVersion
        self.decisionJSON = decisionJSON
        self.supersedesSelectionID = supersedesSelectionID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case partIndex = "part_index"
        case selectedRevisionID = "selected_revision_id"
        case selectionKey = "selection_key"
        case selectedBy = "selected_by"
        case policyVersion = "policy_version"
        case decisionJSON = "decision_json"
        case supersedesSelectionID = "supersedes_selection_id"
        case createdAt = "created_at"
    }
}
