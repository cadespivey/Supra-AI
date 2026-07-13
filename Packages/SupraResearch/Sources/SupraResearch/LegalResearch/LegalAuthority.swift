import Foundation

public enum LegalAuthoritySource: String, Codable, Hashable, Sendable {
    case courtlistener
    /// Statutory text from Open Legal Codes (lowest-weight, currency-caveated). Add a new case
    /// here when wiring another statutory provider (e.g. `govinfo`, `openlaws`).
    case openlegalcodes
    /// Federal regulations from the official eCFR (currency-verifiable — carries an effective date).
    case ecfr
    /// Federal statutory materials from govinfo.
    case govinfo
}

public enum LegalAuthorityType: String, Codable, Hashable, Sendable {
    case `case`
    case statute
    case docket
    case unknown
}

public enum LegalAuthorityTextKind: String, Codable, Hashable, Sendable {
    case searchSnippet = "search_snippet"
    case fullText = "full_text"
    case statutoryText = "statutory_text"
}

public struct LegalAuthority: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: LegalAuthoritySource
    public var authorityType: LegalAuthorityType
    public var caseName: String?
    public var citation: String?
    public var citations: [String]
    public var court: String?
    public var courtID: String?
    public var jurisdiction: String?
    public var dateFiled: String?
    public var precedentialStatus: String?
    public var url: String?
    public var snippet: String?
    public var text: String?
    /// Provenance of `text`. Optional for backward-compatible packet decoding;
    /// newly retrieved/saved authorities set it explicitly.
    public var textKind: LegalAuthorityTextKind?
    public var clusterId: String?
    public var opinionId: String?
    public var docketNumber: String?

    public init(
        id: String,
        source: LegalAuthoritySource = .courtlistener,
        authorityType: LegalAuthorityType,
        caseName: String? = nil,
        citation: String? = nil,
        citations: [String] = [],
        court: String? = nil,
        courtID: String? = nil,
        jurisdiction: String? = nil,
        dateFiled: String? = nil,
        precedentialStatus: String? = nil,
        url: String? = nil,
        snippet: String? = nil,
        text: String? = nil,
        textKind: LegalAuthorityTextKind? = nil,
        clusterId: String? = nil,
        opinionId: String? = nil,
        docketNumber: String? = nil
    ) {
        self.id = id
        self.source = source
        self.authorityType = authorityType
        self.caseName = caseName
        self.citation = citation
        self.citations = citations
        self.court = court
        self.courtID = courtID
        self.jurisdiction = jurisdiction
        self.dateFiled = dateFiled
        self.precedentialStatus = precedentialStatus
        self.url = url
        self.snippet = snippet
        self.text = text
        self.textKind = textKind
        self.clusterId = clusterId
        self.opinionId = opinionId
        self.docketNumber = docketNumber
    }

    public var allCitationStrings: [String] {
        var values = citations
        if let citation, !citation.isEmpty {
            values.insert(citation, at: 0)
        }
        if let caseName, !caseName.isEmpty {
            values.append(caseName)
        }
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public enum LegalAuthorityNormalizer {
    public static func normalize(_ result: CourtListenerSearchResultDTO) -> LegalAuthority {
        let opinion = result.opinions.first
        let opinionID = opinion?.id.map(String.init)
        let clusterID = result.clusterID.map(String.init)
        let id = opinionID.map { "courtlistener:opinion:\($0)" }
            ?? clusterID.map { "courtlistener:cluster:\($0)" }
            ?? "courtlistener:result:\(stableResultID(for: result))"

        var citations = CourtListenerText.cleanList(result.citation)
        if let neutral = clean(result.neutralCite) {
            citations.append(neutral)
        }
        if let lexis = clean(result.lexisCite) {
            citations.append(lexis)
        }

        let textParts = [
            clean(result.syllabus),
            clean(result.posture),
            clean(result.proceduralHistory),
            clean(opinion?.snippet)
        ].compactMap { $0 }

        return LegalAuthority(
            id: id,
            authorityType: result.docketID == nil ? .case : .case,
            caseName: clean(result.caseName) ?? clean(result.caseNameFull),
            citation: CourtListenerMapper.preferredCitation(for: result),
            citations: Array(Set(citations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(),
            court: clean(result.court) ?? clean(result.courtCitationString),
            courtID: clean(result.courtID),
            jurisdiction: clean(result.courtID) ?? clean(result.courtCitationString) ?? clean(result.court),
            dateFiled: clean(result.dateFiled),
            precedentialStatus: clean(result.status),
            url: CourtListenerMapper.displayURL(for: result)?.absoluteString,
            snippet: clean(opinion?.snippet),
            text: textParts.isEmpty ? nil : textParts.joined(separator: "\n\n"),
            textKind: textParts.isEmpty ? nil : .searchSnippet,
            clusterId: clusterID,
            opinionId: opinionID,
            docketNumber: clean(result.docketNumber)
        )
    }

    public static func normalize(_ response: CourtListenerSearchResponse) -> [LegalAuthority] {
        response.results.map(normalize(_:))
    }

    private static func clean(_ value: String?) -> String? {
        CourtListenerText.clean(value)
    }

    private static func stableResultID(for result: CourtListenerSearchResultDTO) -> String {
        let basis = [
            result.caseName,
            result.citation.first,
            result.courtID,
            result.dateFiled,
            result.docketNumber
        ].compactMap { $0 }.joined(separator: "|")
        var hash: UInt64 = 1469598103934665603
        for byte in basis.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
