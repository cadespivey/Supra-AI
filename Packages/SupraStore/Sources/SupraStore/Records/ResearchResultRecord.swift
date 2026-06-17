import Foundation
import GRDB
import SupraCore

public struct ResearchResultRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "research_results"

    public var id: String
    public var researchQueryID: String
    public var courtlistenerID: String?
    public var clusterID: String?
    public var opinionID: String?
    public var caseName: String
    public var caseNameFull: String?
    public var citationJSON: String
    public var preferredCitation: String?
    public var court: String?
    public var courtID: String?
    public var dateFiled: Date?
    public var docketNumber: String?
    public var snippet: String?
    public var absoluteURL: String?
    public var reviewState: String
    public var rawResultJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        researchQueryID: String,
        courtlistenerID: String? = nil,
        clusterID: String? = nil,
        opinionID: String? = nil,
        caseName: String,
        caseNameFull: String? = nil,
        citationJSON: String = "[]",
        preferredCitation: String? = nil,
        court: String? = nil,
        courtID: String? = nil,
        dateFiled: Date? = nil,
        docketNumber: String? = nil,
        snippet: String? = nil,
        absoluteURL: String? = nil,
        reviewState: String = ResearchResultReviewState.unreviewed.rawValue,
        rawResultJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.researchQueryID = researchQueryID
        self.courtlistenerID = courtlistenerID
        self.clusterID = clusterID
        self.opinionID = opinionID
        self.caseName = caseName
        self.caseNameFull = caseNameFull
        self.citationJSON = citationJSON
        self.preferredCitation = preferredCitation
        self.court = court
        self.courtID = courtID
        self.dateFiled = dateFiled
        self.docketNumber = docketNumber
        self.snippet = snippet
        self.absoluteURL = absoluteURL
        self.reviewState = reviewState
        self.rawResultJSON = rawResultJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case researchQueryID = "research_query_id"
        case courtlistenerID = "courtlistener_id"
        case clusterID = "cluster_id"
        case opinionID = "opinion_id"
        case caseName = "case_name"
        case caseNameFull = "case_name_full"
        case citationJSON = "citation_json"
        case preferredCitation = "preferred_citation"
        case court
        case courtID = "court_id"
        case dateFiled = "date_filed"
        case docketNumber = "docket_number"
        case snippet
        case absoluteURL = "absolute_url"
        case reviewState = "review_state"
        case rawResultJSON = "raw_result_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
