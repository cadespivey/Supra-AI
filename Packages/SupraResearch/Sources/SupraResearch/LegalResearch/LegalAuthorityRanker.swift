import Foundation

public struct RankedLegalAuthority: Codable, Hashable, Sendable {
    public var authority: LegalAuthority
    public var score: Int
    public var reasons: [String]
}

public enum LegalAuthorityRanker {
    public static func rank(
        _ authorities: [LegalAuthority],
        for classification: LegalQueryClassification
    ) -> [RankedLegalAuthority] {
        authorities.map { authority in
            score(authority, classification: classification)
        }
        .sorted {
            if $0.score == $1.score {
                return ($0.authority.dateFiled ?? "") > ($1.authority.dateFiled ?? "")
            }
            return $0.score > $1.score
        }
    }

    private static func score(
        _ authority: LegalAuthority,
        classification: LegalQueryClassification
    ) -> RankedLegalAuthority {
        var score = 0
        var reasons: [String] = []

        if let jurisdiction = classification.jurisdiction,
           matchesJurisdiction(authority, requested: jurisdiction) {
            score += 40
            reasons.append("jurisdiction_match")
        }

        if let court = authority.court?.lowercased() {
            if court.contains("supreme") {
                score += 24
                reasons.append("highest_court")
            } else if court.contains("appeals") || court.contains("appellate") || court.contains("circuit") {
                score += 18
                reasons.append("appellate_court")
            } else if court.contains("district") || court.contains("trial") {
                score += 8
                reasons.append("trial_court")
            }
        }

        if let dateFiled = authority.dateFiled {
            score += recencyScore(dateFiled)
            reasons.append("date_filed")
        }

        // Precedential weight: published/precedential opinions outrank
        // unpublished or non-precedential ones, which carry little/no binding
        // force and should not surface above controlling authority.
        let (precedentialDelta, precedentialReason) = precedentialScore(authority.precedentialStatus)
        if let precedentialReason {
            score += precedentialDelta
            reasons.append(precedentialReason)
        }

        // Token-aware matching, not string equality: the lookup is the SHORT name
        // the user typed ("Rush v. Savchuk"); the record carries the full caption.
        // The named case must never be ranked out of the packet it was asked about.
        if let citation = classification.citationLookup,
           LegalCitationMatch.authority(authority, matchesLookup: citation) {
            score += 30
            reasons.append("citation_match")
        }

        let issueTerms = significantTerms(in: classification.legalIssue)
        let haystack = [
            authority.caseName,
            authority.citation,
            authority.snippet,
            authority.text
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        let matchingTerms = issueTerms.filter { haystack.contains($0) }
        if !matchingTerms.isEmpty {
            score += min(20, matchingTerms.count * 3)
            reasons.append("term_relevance")
        }

        if let text = authority.text, text.count > 500 {
            score += 8
            reasons.append("available_text")
        } else if let snippet = authority.snippet, snippet.count > 80 {
            score += 4
            reasons.append("available_snippet")
        }

        if classification.adverseAuthorityRequested {
            let adverseTerms = ["distinguish", "limited", "overrule", "decline", "reject", "contrary"]
            if adverseTerms.contains(where: { haystack.contains($0) }) {
                score += 8
                reasons.append("possible_adverse_discussion")
            }
        }

        return RankedLegalAuthority(authority: authority, score: score, reasons: reasons)
    }

    /// Whether an authority sits in the requested jurisdiction, for ranking purposes.
    ///
    /// Shares `JurisdictionScopeResolver` with `LegalCitationVerifier`, so retrieval
    /// ranking and citation verification answer this question the same way. The
    /// substring comparison this replaces both credited an Arkansas authority in a
    /// Kansas matter (ranking out-of-forum law above controlling law) and denied
    /// "…for the 11th Circuit" a match in an "…for the Eleventh Circuit" matter.
    ///
    /// `.indeterminate` falls back to exact normalized equality — never containment —
    /// mirroring the verifier. An unrecognized court simply earns no jurisdiction
    /// bonus; ranking is advisory, so the conservative direction here is to withhold
    /// score rather than to invent it.
    private static func matchesJurisdiction(_ authority: LegalAuthority, requested: String) -> Bool {
        switch JurisdictionScopeResolver.shared.verdict(
            expected: requested,
            authorityCourt: authority.court,
            authorityJurisdiction: authority.jurisdiction,
            authorityCourtID: authority.courtID
        ) {
        case .withinScope:
            return true
        case .outsideScope:
            return false
        case .indeterminate:
            let requestedKey = normalized(requested)
            let fields = [authority.jurisdiction, authority.court, authority.courtID].compactMap { $0 }
            return fields.contains { normalized($0) == requestedKey }
        }
    }

    /// Maps a CourtListener precedential status to a score delta and a reason.
    /// Returns a `nil` reason when status is unknown/absent so no signal is added.
    private static func precedentialScore(_ status: String?) -> (Int, String?) {
        guard let status = status?.lowercased(), !status.isEmpty else { return (0, nil) }
        if status.contains("unpublished") || status.contains("non-precedential") || status.contains("nonprecedential") {
            return (-20, "non_precedential")
        }
        if status.contains("errata") || status.contains("separate") || status.contains("in-chambers")
            || status.contains("relating-to") || status.contains("unknown") {
            return (-10, "limited_precedential_status")
        }
        if status.contains("published") || status.contains("precedential") {
            return (15, "precedential")
        }
        return (0, nil)
    }

    private static func recencyScore(_ dateFiled: String) -> Int {
        guard let year = Int(dateFiled.prefix(4)) else { return 0 }
        if year >= 2020 { return 12 }
        if year >= 2010 { return 9 }
        if year >= 2000 { return 6 }
        if year >= 1980 { return 3 }
        return 1
    }

    private static func significantTerms(in text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "under", "what", "when",
            "where", "whether", "legal", "law", "case", "cases", "court", "authority"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
