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
    public var notes: String?
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
        notes: String? = nil,
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
        self.notes = notes
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
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
