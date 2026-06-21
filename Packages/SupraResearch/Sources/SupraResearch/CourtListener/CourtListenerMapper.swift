import Foundation

public enum CourtListenerMapper {
    public static func displayURL(for result: CourtListenerSearchResultDTO) -> URL? {
        guard let absoluteURL = result.absoluteURL else {
            return nil
        }
        return URL(string: absoluteURL, relativeTo: CourtListenerEndpoint.baseURL)?.absoluteURL
    }

    /// The best parallel citation for display, sanitized of highlight markup.
    /// CourtListener returns parallel citations in no particular order, so a SCOTUS
    /// case can surface a specialty reporter (e.g. "Fla. L. Weekly Fed. S") ahead of
    /// the official U.S. Reports. We rank by reporter authority and prefer the
    /// official/most-citable one.
    public static func preferredCitation(for result: CourtListenerSearchResultDTO) -> String? {
        var candidates = CourtListenerText.cleanList(result.citation)
        if let neutral = CourtListenerText.clean(result.neutralCite) {
            candidates.append(neutral)
        }
        if let lexis = CourtListenerText.clean(result.lexisCite) {
            candidates.append(lexis)
        }
        guard !candidates.isEmpty else { return nil }
        // Stable: `min(by:)` keeps the first of equal-ranked citations.
        return candidates.min { reporterRank($0) < reporterRank($1) }
    }

    /// Lower is more authoritative/preferred. Official reporters beat regional
    /// reporters, which beat specialty loose-leaf / vendor-neutral database cites.
    static func reporterRank(_ citation: String) -> Int {
        func matches(_ pattern: String) -> Bool {
            citation.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // Loose-leaf / news services / vendor database cites are least preferred.
        if matches(#"L\.?\s*Weekly"#) || matches(#"U\.?\s*S\.?\s*L\.?\s*W"#)
            || matches(#"\bWL\b"#) || matches(#"LEXIS"#) {
            return 9
        }
        // U.S. Reports (official SCOTUS reporter): "526 U.S. 434".
        if matches(#"\d+\s+U\.?\s?S\.?\s+\d"#) { return 0 }
        // Supreme Court Reporter / Lawyers' Edition.
        if matches(#"\bS\.?\s?Ct\.?\b"#) { return 1 }
        if matches(#"\bL\.?\s?Ed\.?\b"#) { return 2 }
        // Federal Reporter / Federal Supplement / Fed. Appx.
        if matches(#"\bF\.?\s?(4th|3d|2d|Supp\.?|App)"#) || matches(#"\bF\.\s+\d"#) { return 3 }
        // Regional reporters (Atlantic, Pacific, North/South Eastern/Western, Southern).
        if matches(#"\b(A|P|N\.?E|N\.?W|S\.?E|S\.?W|So)\.?\s?(2d|3d)?\s+\d"#) { return 4 }
        return 6
    }
}
