import Foundation
import GRDB
import SupraCore

/// A single inline citation persisted for an assistant chat message. `kind` is
/// "authority" (legal-research `[A#]`, with a CourtListener `url`) or "source"
/// (matter-document `[S#]`, with a `documentID` + `locatorJSON` page locator), so
/// the chat UI can resolve a tapped marker to its destination.
public struct MessageCitationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "message_citations"

    public var id: String
    public var messageID: String
    public var label: String
    public var kind: String
    public var url: String?
    public var documentID: String?
    public var locatorJSON: String?
    public var displayName: String?
    public var matchText: String?
    public var rank: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        messageID: String,
        label: String,
        kind: String,
        url: String? = nil,
        documentID: String? = nil,
        locatorJSON: String? = nil,
        displayName: String? = nil,
        matchText: String? = nil,
        rank: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.messageID = messageID
        self.label = label
        self.kind = kind
        self.url = url
        self.documentID = documentID
        self.locatorJSON = locatorJSON
        self.displayName = displayName
        self.matchText = matchText
        self.rank = rank
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case label
        case kind
        case url
        case documentID = "document_id"
        case locatorJSON = "locator_json"
        case displayName = "display_name"
        case matchText = "match_text"
        case rank
        case createdAt = "created_at"
    }
}
