import Foundation

/// Builds the source-packet authority list for a statutory question: statutory provisions LEAD
/// (they're the primary law the user asked about, carrying their currency caveat), then the
/// top-ranked case law fills the remaining slots, capped to the packet size. Lives in
/// SupraResearch so it can use `RankedLegalAuthority`'s in-module initializer.
public enum StatutoryPacketMerge {
    /// Statutes lead the packet; the score is illustrative — the order is constructed here, not
    /// re-sorted downstream.
    static let statutoryLeadScore = 1_000

    public static func merge(
        statutoryProvisions: [StatutoryProvision],
        rankedCases: [RankedLegalAuthority],
        jurisdictionLabel: String?,
        cap: Int,
        citation: String? = nil,
        queryTerms: String = ""
    ) -> [RankedLegalAuthority] {
        guard cap > 0 else { return [] }
        let citableProvisions = statutoryProvisions.filter(\.isCitableAuthority)
        guard !citableProvisions.isEmpty else { return Array(rankedCases.prefix(cap)) }

        // Provisions are RANKED against the question before any of them may
        // lead the packet: the leading authority is presented to the model as
        // "the governing text", so a tangential regulation that happened to
        // arrive first must never outrank the provision the user actually
        // cited. Ties keep the orchestrator's source-tier order.
        let scored = citableProvisions
            .map { (provision: $0, relevance: relevance(of: $0, citation: citation, queryTerms: queryTerms)) }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.relevance == rhs.element.relevance
                    ? lhs.offset < rhs.offset
                    : lhs.element.relevance > rhs.element.relevance
            }
            .map(\.element)

        // Reserve at most ~half the packet for statutes so case law isn't fully evicted.
        let statuteBudget = max(1, cap - cap / 2)
        let statRanked = scored.prefix(statuteBudget).map { entry in
            RankedLegalAuthority(
                authority: entry.provision.asLegalAuthority(jurisdictionLabel: jurisdictionLabel),
                score: Self.statutoryLeadScore,
                reasons: ["statutory provision · \(entry.provision.sourceName)\(entry.provision.weightTier == .convenience ? " (unverified currency)" : "")"]
            )
        }
        let caseSlots = max(0, cap - statRanked.count)
        return Array(statRanked) + Array(rankedCases.prefix(caseSlots))
    }

    /// How strongly a provision answers THIS question: an exact citation match
    /// dominates; otherwise significant query-term overlap in the provision's
    /// citation, heading, and snippet.
    static func relevance(of provision: StatutoryProvision, citation: String?, queryTerms: String) -> Int {
        var score = 0
        if let citation {
            // Token-boundary matching, per cited fragment (the citation target
            // can be a "; "-joined blob of several cites): every numeric token
            // of a cited fragment must appear as a WHOLE token of the
            // provision's citation. Substring containment would let § 672.20
            // +100 the neighboring § 672.201, and a joined blob would
            // manufacture digit runs that match unrelated sections.
            let ownTokens = Set(numericTokens(provision.citation))
            if !ownTokens.isEmpty {
                for fragment in citation.components(separatedBy: ";") {
                    let citedTokens = numericTokens(fragment)
                    if !citedTokens.isEmpty, citedTokens.allSatisfy(ownTokens.contains) {
                        score += 100
                        break
                    }
                }
            }
        }
        let haystack = [provision.citation, provision.heading, provision.snippet]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        // Ordered dedupe (a Set's iteration order would jitter run to run).
        var seen = Set<String>()
        var terms: [String] = []
        for word in queryTerms.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        where word.count >= 4 && seen.insert(word).inserted {
            terms.append(word)
            if terms.count == 12 { break }
        }
        let matches = terms.filter { haystack.contains($0) }.count
        score += min(20, matches * 4)
        return score
    }

    /// Digit-bearing tokens of a citation ("18 U.S.C. § 1001" → ["18", "1001"];
    /// reporter-abbreviation letters carry no digits and drop out).
    static func numericTokens(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
    }
}
