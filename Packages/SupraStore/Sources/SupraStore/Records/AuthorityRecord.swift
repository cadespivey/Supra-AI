import Foundation
import GRDB
import SupraCore

public struct AuthorityRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "authorities"

    public var id: String
    public var matterID: String
    public var researchSessionID: String
    public var researchResultID: String
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
    public var absoluteURL: String?
    public var precedentialStatus: String?
    public var reviewState: String
    public var useStatus: String
    public var userNotes: String?
    /// Hydrated full opinion text, persisted only for user-saved authorities (spec
    /// §8.3) — grounds local-first research and the offline [A#] reader.
    public var opinionText: String?
    public var caseSummary: String?
    public var rawMetadataJSON: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        researchSessionID: String,
        researchResultID: String,
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
        absoluteURL: String? = nil,
        precedentialStatus: String? = nil,
        reviewState: String = ResearchResultReviewState.saved.rawValue,
        useStatus: String = AuthorityUseStatus.retrievedFromCourtListener.rawValue,
        userNotes: String? = nil,
        opinionText: String? = nil,
        caseSummary: String? = nil,
        rawMetadataJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.researchSessionID = researchSessionID
        self.researchResultID = researchResultID
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
        self.absoluteURL = absoluteURL
        self.precedentialStatus = precedentialStatus
        self.reviewState = reviewState
        self.useStatus = useStatus
        self.userNotes = userNotes
        self.opinionText = opinionText
        self.caseSummary = caseSummary
        self.rawMetadataJSON = rawMetadataJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case researchSessionID = "research_session_id"
        case researchResultID = "research_result_id"
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
        case absoluteURL = "absolute_url"
        case precedentialStatus = "precedential_status"
        case reviewState = "review_state"
        case useStatus = "use_status"
        case userNotes = "user_notes"
        case opinionText = "opinion_text"
        case caseSummary = "case_summary"
        case rawMetadataJSON = "raw_metadata_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
