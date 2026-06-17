import Foundation
import GRDB

public struct AuditEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "audit_events"

    public var id: String
    public var matterID: String?
    public var timestamp: Date
    public var eventType: String
    public var actor: String
    public var summary: String
    public var relatedTable: String?
    public var relatedID: String?
    public var metadataJSON: String?

    public init(
        id: String = UUID().uuidString,
        matterID: String? = nil,
        timestamp: Date = Date(),
        eventType: String,
        actor: String,
        summary: String,
        relatedTable: String? = nil,
        relatedID: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.timestamp = timestamp
        self.eventType = eventType
        self.actor = actor
        self.summary = summary
        self.relatedTable = relatedTable
        self.relatedID = relatedID
        self.metadataJSON = metadataJSON
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case timestamp
        case eventType = "event_type"
        case actor
        case summary
        case relatedTable = "related_table"
        case relatedID = "related_id"
        case metadataJSON = "metadata_json"
    }
}
