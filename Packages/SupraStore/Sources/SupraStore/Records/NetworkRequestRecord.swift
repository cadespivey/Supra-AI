import Foundation
import GRDB

public struct NetworkRequestRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "network_requests"

    public var id: String
    public var timestamp: Date
    public var domain: String
    public var method: String
    public var endpoint: String
    public var approved: Bool
    public var statusCode: Int?
    public var relatedResearchSessionID: String?
    public var blockedReason: String?
    public var errorMessage: String?
    public var requestMetadataJSON: String?
    public var responseMetadataJSON: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        domain: String,
        method: String,
        endpoint: String,
        approved: Bool,
        statusCode: Int? = nil,
        relatedResearchSessionID: String? = nil,
        blockedReason: String? = nil,
        errorMessage: String? = nil,
        requestMetadataJSON: String? = nil,
        responseMetadataJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.method = method
        self.endpoint = endpoint
        self.approved = approved
        self.statusCode = statusCode
        self.relatedResearchSessionID = relatedResearchSessionID
        self.blockedReason = blockedReason
        self.errorMessage = errorMessage
        self.requestMetadataJSON = requestMetadataJSON
        self.responseMetadataJSON = responseMetadataJSON
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case domain
        case method
        case endpoint
        case approved
        case statusCode = "status_code"
        case relatedResearchSessionID = "related_research_session_id"
        case blockedReason = "blocked_reason"
        case errorMessage = "error_message"
        case requestMetadataJSON = "request_metadata_json"
        case responseMetadataJSON = "response_metadata_json"
    }
}
