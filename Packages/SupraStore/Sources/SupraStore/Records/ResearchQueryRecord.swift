import Foundation
import GRDB
import SupraCore

public struct ResearchQueryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "research_queries"

    public var id: String
    public var researchSessionID: String
    public var queryText: String
    public var queryIndex: Int
    public var courtFilter: String?
    public var dateFiledAfter: Date?
    public var dateFiledBefore: Date?
    public var status: String
    public var resultCount: Int?
    public var nextURL: String?
    public var executedAt: Date?
    public var requestMetadataJSON: String?
    public var responseMetadataJSON: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        researchSessionID: String,
        queryText: String,
        queryIndex: Int,
        courtFilter: String? = nil,
        dateFiledAfter: Date? = nil,
        dateFiledBefore: Date? = nil,
        status: String = ResearchQueryStatus.draft.rawValue,
        resultCount: Int? = nil,
        nextURL: String? = nil,
        executedAt: Date? = nil,
        requestMetadataJSON: String? = nil,
        responseMetadataJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.researchSessionID = researchSessionID
        self.queryText = queryText
        self.queryIndex = queryIndex
        self.courtFilter = courtFilter
        self.dateFiledAfter = dateFiledAfter
        self.dateFiledBefore = dateFiledBefore
        self.status = status
        self.resultCount = resultCount
        self.nextURL = nextURL
        self.executedAt = executedAt
        self.requestMetadataJSON = requestMetadataJSON
        self.responseMetadataJSON = responseMetadataJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case researchSessionID = "research_session_id"
        case queryText = "query_text"
        case queryIndex = "query_index"
        case courtFilter = "court_filter"
        case dateFiledAfter = "date_filed_after"
        case dateFiledBefore = "date_filed_before"
        case status
        case resultCount = "result_count"
        case nextURL = "next_url"
        case executedAt = "executed_at"
        case requestMetadataJSON = "request_metadata_json"
        case responseMetadataJSON = "response_metadata_json"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
