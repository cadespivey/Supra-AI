import Foundation
import GRDB

public struct DocumentStructureNodeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_structure_nodes"

    public var id: String
    public var documentID: String
    public var revisionID: String
    public var nodeKey: String
    public var parentNodeID: String?
    public var ordinal: Int
    public var kind: String
    public var charStart: Int?
    public var charEnd: Int?
    public var textContent: String?
    public var payloadJSON: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        documentID: String,
        revisionID: String,
        nodeKey: String,
        parentNodeID: String? = nil,
        ordinal: Int,
        kind: String,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        textContent: String? = nil,
        payloadJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.revisionID = revisionID
        self.nodeKey = nodeKey
        self.parentNodeID = parentNodeID
        self.ordinal = ordinal
        self.kind = kind
        self.charStart = charStart
        self.charEnd = charEnd
        self.textContent = textContent
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case revisionID = "revision_id"
        case nodeKey = "node_key"
        case parentNodeID = "parent_node_id"
        case ordinal
        case kind
        case charStart = "char_start"
        case charEnd = "char_end"
        case textContent = "text_content"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}
