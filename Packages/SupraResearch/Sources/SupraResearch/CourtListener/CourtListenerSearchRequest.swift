import Foundation

public struct CourtListenerSearchRequest: Codable, Equatable, Sendable {
    /// Which CourtListener corpus to search. Opinions are published case law (citable
    /// authority); RECAP is case filings from PACER (who sued whom — a factual record,
    /// NOT authority for a legal proposition).
    public enum SearchType: String, Codable, Sendable {
        case opinion = "o"   // published opinions / case law
        case recap = "r"     // RECAP documents + dockets (PACER filings)
        case docket = "d"    // dockets only
    }

    public let query: String
    public let searchType: SearchType
    public let orderBy: String?
    public let highlight: Bool
    public let cursorURL: URL?
    public let courtIDs: [String]
    public let dateFiledAfter: String?
    public let dateFiledBefore: String?
    public let citation: String?
    /// Party / case-name filters for RECAP/docket search (ignored for opinion search).
    public let partyName: String?
    public let caseName: String?

    public init(
        query: String,
        searchType: SearchType = .opinion,
        orderBy: String? = nil,
        highlight: Bool = true,
        cursorURL: URL? = nil,
        courtIDs: [String] = [],
        dateFiledAfter: String? = nil,
        dateFiledBefore: String? = nil,
        citation: String? = nil,
        partyName: String? = nil,
        caseName: String? = nil
    ) {
        self.query = query
        self.searchType = searchType
        self.orderBy = orderBy
        self.highlight = highlight
        self.cursorURL = cursorURL
        self.courtIDs = courtIDs
        self.dateFiledAfter = dateFiledAfter
        self.dateFiledBefore = dateFiledBefore
        self.citation = citation
        self.partyName = partyName
        self.caseName = caseName
    }

    /// A copy targeting a different corpus, preserving all other fields.
    public func withSearchType(_ type: SearchType) -> CourtListenerSearchRequest {
        CourtListenerSearchRequest(
            query: query, searchType: type, orderBy: orderBy, highlight: highlight,
            cursorURL: cursorURL, courtIDs: courtIDs, dateFiledAfter: dateFiledAfter,
            dateFiledBefore: dateFiledBefore, citation: citation,
            partyName: partyName, caseName: caseName
        )
    }
}
