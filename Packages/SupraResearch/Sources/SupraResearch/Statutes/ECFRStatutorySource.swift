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
            var provisions: [StatutoryProvision] = []
            var fetchedText = 0
            for result in response.results.prefix(query.limit) {
                // Fetch the full official section text for the top hits (capped to stay
                // inside the client's local rate budget); ground from the excerpt only
                // when the fetch is unavailable.
                var fullText: String?
                if fetchedText < Self.maxSectionTextFetches,
                   let title = result.hierarchy.title, let section = result.hierarchy.section,
                   let date = result.startsOn,
                   let xml = try? await client.fetchSectionText(
                       title: title, part: result.hierarchy.part, section: section, date: date
                   ) {
                    let cleaned = Self.stripHTML(xml)
                    if !cleaned.isEmpty {
                        fetchedText += 1
                        fullText = cleaned.count > Self.maxSectionTextLength
                            ? String(cleaned.prefix(Self.maxSectionTextLength)) + "…"
                            : cleaned
                    }
                }
                if let provision = Self.provision(from: result, fullText: fullText) {
                    provisions.append(provision)
                }
            }
            return StatutoryLookupResult(provisions: provisions)
        } catch {
            return StatutoryLookupResult(note: "eCFR lookup was unavailable for this query.")
        }
    }

    /// The most section-text fetches per lookup — bounds latency AND keeps a lookup
    /// (search + fetches) inside the client's local per-minute rate budget.
    static let maxSectionTextFetches = 2
    /// Cap stored section text (some sections run very long).
    static let maxSectionTextLength = 8_000

    static func provision(from result: ECFRSearchResult, fullText: String? = nil) -> StatutoryProvision? {
        guard let titleNumber = result.hierarchy.title, let section = result.hierarchy.section else { return nil }
        let citation = "\(titleNumber) CFR § \(section)"
        let heading = result.headings.section.map(stripHTML)
        let excerpt = result.fullTextExcerpt.map(stripHTML) ?? heading ?? ""
        let body = fullText ?? excerpt
        return StatutoryProvision(
            sourceID: "ecfr",
            sourceName: "eCFR",
            weightTier: .currencyVerifiable,
            jurisdictionID: "us-cfr-title-\(titleNumber)",
            jurisdictionName: "Code of Federal Regulations, Title \(titleNumber)",
            citation: citation,
            heading: heading,
            snippet: excerpt.isEmpty ? String(body.prefix(280)) : excerpt,
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

    /// Reduces provider HTML/XML (eCFR search highlights, eCFR versioner section XML,
    /// govinfo's rendered /htm pages) to clean text: non-content blocks are dropped
    /// entirely (a govinfo page carries a real <head>/<style>), tags become spaces so
    /// adjacent elements don't weld into one word, and entities are decoded (statute
    /// text is full of `&#167;`/`&amp;`).
    public static func stripHTML(_ value: String) -> String {
        var text = value.replacingOccurrences(
            of: #"(?is)<(head|style|script)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = CourtListenerText.decodeEntities(text)
        return text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ?\n ?"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
