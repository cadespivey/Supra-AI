import Foundation

/// `StatutorySource` backed by Open Legal Codes — the lowest (`.convenience`) tier: free and
/// unlimited, but lazily crawled with no verifiable currency. Every provision carries a currency
/// caveat, and any crawl failure degrades to "no provisions + a note" so the answer flow never
/// breaks (the case-law path is unaffected).
public struct OpenLegalCodesStatutorySource: StatutorySource {
    public let id = "open-legal-codes"
    public let displayName = "Open Legal Codes"
    public let weightTier: SourceWeightTier = .convenience
    public let providesCurrency = false

    private let client: any OpenLegalCodesClientProtocol
    /// Best-effort full-text hydration for the top hits (the rest ground from their snippet).
    private let hydrateLimit: Int

    public init(client: any OpenLegalCodesClientProtocol, hydrateLimit: Int = 2) {
        self.client = client
        self.hydrateLimit = hydrateLimit
    }

    public func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult {
        let jurisdictionIDs = StatutoryJurisdictionMapper.olcJurisdictionIDs(
            jurisdiction: query.jurisdiction, citation: query.citation, terms: query.terms
        )
        guard !jurisdictionIDs.isEmpty else { return StatutoryLookupResult() }

        var lastNote: String?
        var provisions: [StatutoryProvision] = []
        for jurisdictionID in jurisdictionIDs {
            let remainingLimit = max(0, query.limit - provisions.count)
            guard remainingLimit > 0 else { break }
            do {
                let results = try await client.searchCode(
                    jurisdictionID: jurisdictionID, query: query.terms, limit: remainingLimit, relatedResearchSessionID: nil
                )
                let hits = Array(results.results.prefix(remainingLimit))
                guard !hits.isEmpty else { continue }

                let jurisdictionName = results.jurisdictionName ?? jurisdictionID
                for (index, hit) in hits.enumerated() {
                    provisions.append(StatutoryProvision(
                        sourceID: id,
                        sourceName: displayName,
                        weightTier: weightTier,
                        jurisdictionID: jurisdictionID,
                        jurisdictionName: jurisdictionName,
                        citation: citation(for: hit),
                        heading: hit.heading,
                        snippet: hit.snippet,
                        text: await text(for: hit, jurisdictionID: jurisdictionID, hydrate: index < hydrateLimit),
                        url: hit.url,
                        locatorPath: hit.path,
                        effectiveDate: nil,
                        currencyCaveat: Self.caveat(jurisdictionName: jurisdictionName)
                    ))
                }
            } catch let error as OpenLegalCodesError {
                if error.isTransient {
                    lastNote = "Open Legal Codes could not return \(jurisdictionID) right now (\(error.localizedDescription))."
                }
                continue
            } catch {
                continue
            }
        }
        if !provisions.isEmpty {
            return StatutoryLookupResult(provisions: provisions)
        }
        return StatutoryLookupResult(note: lastNote)
    }

    private func citation(for hit: OLCSearchHit) -> String {
        if let num = hit.num, !num.isEmpty { return num }
        return hit.path
    }

    /// The grounding text: full section text when hydration succeeds, else the search snippet/heading.
    private func text(for hit: OLCSearchHit, jurisdictionID: String, hydrate: Bool) async -> String {
        let fallback = (hit.snippet?.isEmpty == false ? hit.snippet : nil) ?? hit.heading ?? ""
        guard hydrate else { return fallback }
        if let section = try? await client.fetchSection(jurisdictionID: jurisdictionID, path: hit.path, relatedResearchSessionID: nil),
           !section.text.isEmpty {
            return section.text
        }
        return fallback
    }

    static func caveat(jurisdictionName: String) -> String {
        "From Open Legal Codes (free, crawled, no verified currency). Confirm this section against the official \(jurisdictionName) before relying on it."
    }
}
