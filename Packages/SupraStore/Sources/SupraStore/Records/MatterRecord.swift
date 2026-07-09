import Foundation
import GRDB

public struct MatterRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "matters"

    public var id: String
    public var name: String
    public var jurisdiction: String
    public var partyPerspective: String
    public var court: String?
    public var judge: String?
    public var docketNumber: String?
    public var practiceArea: String?
    public var clientNames: String?
    public var matterDescription: String?
    public var internalMatterID: String?
    /// LEDES `CLIENT_ID` — the client's identifier for e-billing (Milestone 4).
    public var clientID: String?
    /// LEDES `CLIENT_MATTER_ID` — the client's matter identifier for e-billing (Milestone 4).
    public var clientMatterID: String?
    public var notes: String?
    /// Position for the sidebar's manual sort mode; nil = never manually placed.
    public var sortOrder: Int?
    /// When the matter was pinned to the top of the sidebar; nil = not pinned.
    public var pinnedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        jurisdiction: String = "Unspecified",
        partyPerspective: String = "neutral",
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        clientNames: String? = nil,
        matterDescription: String? = nil,
        internalMatterID: String? = nil,
        clientID: String? = nil,
        clientMatterID: String? = nil,
        notes: String? = nil,
        sortOrder: Int? = nil,
        pinnedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.jurisdiction = jurisdiction
        self.partyPerspective = partyPerspective
        self.court = court
        self.judge = judge
        self.docketNumber = docketNumber
        self.practiceArea = practiceArea
        self.clientNames = clientNames
        self.matterDescription = matterDescription
        self.internalMatterID = internalMatterID
        self.clientID = clientID
        self.clientMatterID = clientMatterID
        self.notes = notes
        self.sortOrder = sortOrder
        self.pinnedAt = pinnedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case jurisdiction
        case partyPerspective = "party_perspective"
        case court
        case judge
        case docketNumber = "docket_number"
        case practiceArea = "practice_area"
        case clientNames = "client_names"
        case matterDescription = "matter_description"
        case internalMatterID = "internal_matter_id"
        case clientID = "client_id"
        case clientMatterID = "client_matter_id"
        case notes
        case sortOrder = "sort_order"
        case pinnedAt = "pinned_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
