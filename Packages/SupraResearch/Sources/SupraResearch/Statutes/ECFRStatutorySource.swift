import Foundation

/// `StatutorySource` backed by eCFR (the official Code of Federal Regulations). It's the
/// `.currencyVerifiable` tier: free and key-less like OLC, but it stamps a real effective date per
/// section, so for the same provision it OUTRANKS OLC in the orchestrator's tier-weighted merge.
/// Federal-only — it skips state-specific queries (those belong to OLC's `<state>-statutes`).
public struct ECFRStatutorySource: StatutorySource {
    public let id = "ecfr"
    public let displayName = "eCFR (Code of Federal Regulations)"
    public let weightTier: SourceWeightTier = .currencyVerifiable
    public let providesCurrency = true

    private let client: any ECFRClientProtocol

    public init(client: any ECFRClientProtocol) {
        self.client = client
    }

    public func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult {
        // eCFR covers federal regulations only. Skip when the query names a specific state.
        if let jurisdiction = query.jurisdiction,
           StatutoryJurisdictionMapper.postalCode(forJurisdiction: jurisdiction) != nil {
            return StatutoryLookupResult()
        }
        do {
            let response = try await client.search(query: query.terms, limit: query.limit)
            let provisions = response.results.prefix(query.limit).compactMap(Self.provision(from:))
            return StatutoryLookupResult(provisions: Array(provisions))
        } catch {
            return StatutoryLookupResult(note: "eCFR lookup was unavailable for this query.")
        }
    }

    static func provision(from result: ECFRSearchResult) -> StatutoryProvision? {
        guard let titleNumber = result.hierarchy.title, let section = result.hierarchy.section else { return nil }
        let citation = "\(titleNumber) CFR § \(section)"
        let heading = result.headings.section.map(stripHTML)
        let body = result.fullTextExcerpt.map(stripHTML) ?? heading ?? ""
        return StatutoryProvision(
            sourceID: "ecfr",
            sourceName: "eCFR",
            weightTier: .currencyVerifiable,
            jurisdictionID: "us-cfr-title-\(titleNumber)",
            jurisdictionName: "Code of Federal Regulations, Title \(titleNumber)",
            citation: citation,
            heading: heading,
            snippet: body,
            text: body,
            url: sectionURL(title: titleNumber, section: section),
            locatorPath: section,
            effectiveDate: result.startsOn,   // a real effective date → no currency caveat needed
            currencyCaveat: nil
        )
    }

    static func sectionURL(title: String, section: String) -> String {
        "https://www.ecfr.gov/current/title-\(title)/section-\(section)"
    }

    /// eCFR highlights matches with `<strong>` tags; strip them (and any other tags) for clean text.
    static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
