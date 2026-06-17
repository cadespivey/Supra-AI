import Foundation
import GRDB
import SupraCore

public struct ResearchSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "research_sessions"

    public var id: String
    public var matterID: String
    public var title: String
    public var issueText: String
    public var jurisdiction: String
    public var preferredCourtsJSON: String
    public var excludedCourtsJSON: String
    public var dateRangeStart: Date?
    public var dateRangeEnd: Date?
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        title: String,
        issueText: String,
        jurisdiction: String,
        preferredCourtsJSON: String = "[]",
        excludedCourtsJSON: String = "[]",
        dateRangeStart: Date? = nil,
        dateRangeEnd: Date? = nil,
        status: String = ResearchSessionStatus.draft.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.title = title
        self.issueText = issueText
        self.jurisdiction = jurisdiction
        self.preferredCourtsJSON = preferredCourtsJSON
        self.excludedCourtsJSON = excludedCourtsJSON
        self.dateRangeStart = dateRangeStart
        self.dateRangeEnd = dateRangeEnd
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case title
        case issueText = "issue_text"
        case jurisdiction
        case preferredCourtsJSON = "preferred_courts_json"
        case excludedCourtsJSON = "excluded_courts_json"
        case dateRangeStart = "date_range_start"
        case dateRangeEnd = "date_range_end"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}
