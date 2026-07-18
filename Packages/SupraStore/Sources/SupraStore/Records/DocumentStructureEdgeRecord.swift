import Foundation
import GRDB

public struct DocumentStructureEdgeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_structure_edges"

    public var id: String
    public var matterID: String
    public var fromNodeID: String
    public var toNodeID: String
    public var kind: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        fromNodeID: String,
        toNodeID: String,
        kind: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.kind = kind
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case kind
        case createdAt = "created_at"
    }
}
