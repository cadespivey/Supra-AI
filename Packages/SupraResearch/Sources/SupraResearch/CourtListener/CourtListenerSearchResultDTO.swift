import Foundation

public struct CourtListenerSearchResultDTO: Codable, Equatable, Sendable {
    public let absoluteURL: String?
    public let caseName: String?
    public let caseNameFull: String?
    public let citation: [String]
    public let citeCount: Int?
    public let clusterID: Int?
    public let court: String?
    public let courtCitationString: String?
    public let courtID: String?
    public let dateFiled: String?
    public let docketNumber: String?
    public let docketID: Int?
    public let judge: String?
    public let lexisCite: String?
    public let neutralCite: String?
    public let opinions: [CourtListenerOpinionDTO]
    public let posture: String?
    public let proceduralHistory: String?
    public let source: String?
    public let status: String?
    public let suitNature: String?
    public let syllabus: String?
    public let meta: JSONValue?
    public let rawResultJSON: String

    public init(
        absoluteURL: String? = nil,
        caseName: String? = nil,
        caseNameFull: String? = nil,
        citation: [String] = [],
        citeCount: Int? = nil,
        clusterID: Int? = nil,
        court: String? = nil,
        courtCitationString: String? = nil,
        courtID: String? = nil,
        dateFiled: String? = nil,
        docketNumber: String? = nil,
        docketID: Int? = nil,
        judge: String? = nil,
        lexisCite: String? = nil,
        neutralCite: String? = nil,
        opinions: [CourtListenerOpinionDTO] = [],
        posture: String? = nil,
        proceduralHistory: String? = nil,
        source: String? = nil,
        status: String? = nil,
        suitNature: String? = nil,
        syllabus: String? = nil,
        meta: JSONValue? = nil,
        rawResultJSON: String = "{}"
    ) {
        self.absoluteURL = absoluteURL
        self.caseName = caseName
        self.caseNameFull = caseNameFull
        self.citation = citation
        self.citeCount = citeCount
        self.clusterID = clusterID
        self.court = court
        self.courtCitationString = courtCitationString
        self.courtID = courtID
        self.dateFiled = dateFiled
        self.docketNumber = docketNumber
        self.docketID = docketID
        self.judge = judge
        self.lexisCite = lexisCite
        self.neutralCite = neutralCite
        self.opinions = opinions
        self.posture = posture
        self.proceduralHistory = proceduralHistory
        self.source = source
        self.status = status
        self.suitNature = suitNature
        self.syllabus = syllabus
        self.meta = meta
        self.rawResultJSON = rawResultJSON
    }

    init(copying result: CourtListenerSearchResultDTO, rawResultJSON: String) {
        self.init(
            absoluteURL: result.absoluteURL,
            caseName: result.caseName,
            caseNameFull: result.caseNameFull,
            citation: result.citation,
            citeCount: result.citeCount,
            clusterID: result.clusterID,
            court: result.court,
            courtCitationString: result.courtCitationString,
            courtID: result.courtID,
            dateFiled: result.dateFiled,
            docketNumber: result.docketNumber,
            docketID: result.docketID,
            judge: result.judge,
            lexisCite: result.lexisCite,
            neutralCite: result.neutralCite,
            opinions: result.opinions,
            posture: result.posture,
            proceduralHistory: result.proceduralHistory,
            source: result.source,
            status: result.status,
            suitNature: result.suitNature,
            syllabus: result.syllabus,
            meta: result.meta,
            rawResultJSON: rawResultJSON
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            absoluteURL: try container.decodeIfPresent(String.self, forKey: .absoluteURL),
            caseName: try container.decodeIfPresent(String.self, forKey: .caseName),
            caseNameFull: try container.decodeIfPresent(String.self, forKey: .caseNameFull),
            citation: try container.decodeIfPresent([String].self, forKey: .citation) ?? [],
            citeCount: try container.decodeIfPresent(Int.self, forKey: .citeCount),
            clusterID: try container.decodeIfPresent(Int.self, forKey: .clusterID),
            court: try container.decodeIfPresent(String.self, forKey: .court),
            courtCitationString: try container.decodeIfPresent(String.self, forKey: .courtCitationString),
            courtID: try container.decodeIfPresent(String.self, forKey: .courtID),
            dateFiled: try container.decodeIfPresent(String.self, forKey: .dateFiled),
            docketNumber: try container.decodeIfPresent(String.self, forKey: .docketNumber),
            docketID: try container.decodeIfPresent(Int.self, forKey: .docketID),
            judge: try container.decodeIfPresent(String.self, forKey: .judge),
            lexisCite: try container.decodeIfPresent(String.self, forKey: .lexisCite),
            neutralCite: try container.decodeIfPresent(String.self, forKey: .neutralCite),
            opinions: try container.decodeIfPresent([CourtListenerOpinionDTO].self, forKey: .opinions) ?? [],
            posture: try container.decodeIfPresent(String.self, forKey: .posture),
            proceduralHistory: try container.decodeIfPresent(String.self, forKey: .proceduralHistory),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            status: try container.decodeIfPresent(String.self, forKey: .status),
            suitNature: try container.decodeIfPresent(String.self, forKey: .suitNature),
            syllabus: try container.decodeIfPresent(String.self, forKey: .syllabus),
            meta: try container.decodeIfPresent(JSONValue.self, forKey: .meta)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case absoluteURL = "absolute_url"
        case caseName
        case caseNameFull
        case citation
        case citeCount
        case clusterID = "cluster_id"
        case court
        case courtCitationString = "court_citation_string"
        case courtID = "court_id"
        case dateFiled
        case docketNumber
        case docketID = "docket_id"
        case judge
        case lexisCite
        case neutralCite
        case opinions
        case posture
        case proceduralHistory = "procedural_history"
        case source
        case status
        case suitNature
        case syllabus
        case meta
        case rawResultJSON = "raw_result_json"
    }
}
