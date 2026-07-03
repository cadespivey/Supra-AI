import Foundation

/// Matches a prompt's citation lookup ("Rush v. Savchuk", "444 U.S. 320",
/// "In re Winship") against a retrieved or saved authority.
///
/// Lawyers type SHORT case names; stored records carry the FULL caption —
/// "Rush v. Savchuk, 444 U.S. 320", first names, "Co."/"Inc." suffixes,
/// "et al." — and captions flip party order on appeal. Whole-string
/// containment therefore misses the very case the user named, so case names
/// match on significant party tokens per side (either orientation), and
/// reporter cites match on normalized containment.
public enum LegalCitationMatch {

    /// True when the lookup reads as a case NAME (party caption, "In re",
    /// "Ex parte") rather than a reporter citation or statute.
    public static func isCaseNameLookup(_ lookup: String) -> Bool {
        if versusRange(in: lookup) != nil { return true }
        let lower = lookup.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("in re ") || lower.hasPrefix("ex parte ")
    }

    /// Whether this authority is the one the lookup refers to.
    public static func authority(_ authority: LegalAuthority, matchesLookup lookup: String) -> Bool {
        let lookup = lookup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookup.isEmpty else { return false }
        let normalizedLookup = normalized(lookup)
        for cite in authority.allCitationStrings {
            let candidate = normalized(cite)
            guard !candidate.isEmpty, !normalizedLookup.isEmpty else { continue }
            if candidate == normalizedLookup { return true }
            // Containment guards against trivial fragments matching everything.
            if min(candidate.count, normalizedLookup.count) >= 6,
               candidate.contains(normalizedLookup) || normalizedLookup.contains(candidate) {
                return true
            }
        }
        if let caseName = authority.caseName, caseNamesMatch(lookup: lookup, caseName: caseName) {
            return true
        }
        return false
    }

    /// Party-token case-name matching. Each side of the looked-up caption must
    /// share at least one significant token with a side of the stored caption,
    /// in either orientation (captions flip on appeal: Thomas v. Peacock below
    /// became Peacock v. Thomas at the Supreme Court).
    static func caseNamesMatch(lookup: String, caseName: String) -> Bool {
        guard let lookupParties = parties(of: lookup) else {
            // "In re X" / bare-name lookup: every significant lookup token must
            // appear in the stored caption. A reporter cite has no significant
            // tokens and can never match here.
            let tokens = significantTokens(in: lookup)
            guard !tokens.isEmpty else { return false }
            let haystack = Set(significantTokens(in: caseName))
            return tokens.allSatisfy(haystack.contains)
        }
        guard !lookupParties.first.isEmpty, !lookupParties.second.isEmpty else { return false }
        guard let nameParties = parties(of: caseName) else {
            let haystack = Set(significantTokens(in: caseName))
            return lookupParties.first.contains(where: haystack.contains)
                && lookupParties.second.contains(where: haystack.contains)
        }
        let first = Set(nameParties.first)
        let second = Set(nameParties.second)
        let straight = lookupParties.first.contains(where: first.contains)
            && lookupParties.second.contains(where: second.contains)
        let flipped = lookupParties.first.contains(where: second.contains)
            && lookupParties.second.contains(where: first.contains)
        return straight || flipped
    }

    // MARK: - Internals

    private static func parties(of caption: String) -> (first: [String], second: [String])? {
        guard let range = versusRange(in: caption) else { return nil }
        let left = String(caption[caption.startIndex..<range.lowerBound])
        let right = String(caption[range.upperBound...])
        return (significantTokens(in: left), significantTokens(in: right))
    }

    private static func versusRange(in caption: String) -> Range<String.Index>? {
        for separator in [" v. ", " vs. ", " v ", " vs "] {
            if let range = caption.range(of: separator, options: .caseInsensitive) {
                return range
            }
        }
        return nil
    }

    /// Lowercased word tokens that identify a party: drops procedural words,
    /// corporate suffixes, numbers (reporter volumes/pages), and short
    /// fragments like initials or "US" left over from a trailing cite.
    public static func significantTokens(in value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= 3
                    && Int(token) == nil
                    && !Self.stopTokens.contains(token)
            }
    }

    private static let stopTokens: Set<String> = [
        "the", "and", "for", "his", "her", "its",
        "inc", "incorporated", "corp", "corporation", "company", "cos",
        "llc", "llp", "ltd", "plc", "bros", "brothers",
        "parte", "petitioner", "petitioners", "respondent", "respondents",
        "appellant", "appellants", "appellee", "appellees",
        "supp", "app", "div", "dist", "dept"
    ]

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
