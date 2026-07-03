import Foundation

/// Maps a query's jurisdiction (a human name like "Florida", and any statutory citation) onto Open
/// Legal Codes jurisdiction ids: states become `<postal>-statutes` (e.g. "fl-statutes") and a
/// federal `N U.S.C.` citation becomes `us-usc-title-N`. Returns an ordered, de-duplicated list so
/// the OLC source can try the most specific target first and degrade gracefully when none maps.
public enum StatutoryJurisdictionMapper {
    public static func olcJurisdictionIDs(jurisdiction: String?, citation: String?, terms: String) -> [String] {
        var ids: [String] = []

        // Federal `U.S.C.` titles are the most specific statutory targets. A
        // scheme resolver may provide more than one citation (e.g. DBA + its
        // incorporated Longshore limitations section), so collect every title.
        for source in [citation, terms].compactMap({ $0 }) {
            for title in federalUSCTitles(in: source) {
                ids.append("us-usc-title-\(title)")
            }
        }

        // A state jurisdiction maps to its statutes code.
        if let jurisdiction, let postal = postalCode(forJurisdiction: jurisdiction) {
            ids.append("\(postal.lowercased())-statutes")
        }

        // De-dupe, preserving order.
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Extracts the title number from a federal statutory citation like "42 U.S.C. § 1983".
    static func federalUSCTitle(in text: String) -> Int? {
        federalUSCTitles(in: text).first
    }

    /// Resolves a state reference as it appears in a citation — full name
    /// ("Florida"), postal code ("FL"), or Bluebook abbreviation ("Fla.",
    /// "N.Y.", "W. Va.") — to a two-letter postal code.
    public static func postalCode(forStateReference reference: String) -> String? {
        if let direct = postalCode(forJurisdiction: reference) { return direct }
        let key = reference.lowercased().filter(\.isLetter)
        guard !key.isEmpty else { return nil }
        // Many Bluebook forms reduce to the postal code once periods are
        // stripped ("Ga." → "ga", "N.Y." → "ny"); the rest are in the table.
        if let stripped = postalCode(forJurisdiction: key) { return stripped }
        return bluebookStateToPostal[key]
    }

    /// Bluebook table T10 state abbreviations, keyed with periods/spaces stripped.
    private static let bluebookStateToPostal: [String: String] = [
        "ala": "AL", "ariz": "AZ", "ark": "AR", "cal": "CA", "colo": "CO",
        "conn": "CT", "del": "DE", "fla": "FL", "haw": "HI", "ill": "IL",
        "ind": "IN", "kan": "KS", "mass": "MA", "mich": "MI", "minn": "MN",
        "miss": "MS", "mont": "MT", "neb": "NE", "nev": "NV", "okla": "OK",
        "tenn": "TN", "tex": "TX", "wash": "WA", "wva": "WV", "wis": "WI",
        "wisc": "WI", "wyo": "WY"
    ]

    /// Whether the query itself cites FEDERAL law (U.S.C. or C.F.R.). A federal
    /// cite must reach the federal sources even when the matter sits in a state
    /// jurisdiction — state matters raise federal questions constantly.
    public static func referencesFederalLaw(citation: String?, terms: String) -> Bool {
        let combined = [citation, terms].compactMap { $0 }.joined(separator: " ")
        if !federalUSCTitles(in: combined).isEmpty { return true }
        return combined.range(
            of: #"(?i)\b\d{1,4}\s+c\.?\s?f\.?\s?r\.?\b"#,
            options: .regularExpression
        ) != nil
    }

    static func federalUSCTitles(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(\d{1,2})\s+U\.?\s?S\.?\s?C\.?"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var titles: [Int] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let titleRange = Range(match.range(at: 1), in: text),
                  let title = Int(text[titleRange]), title >= 1, title <= 54 else { return }
            titles.append(title)
        }
        var seen = Set<Int>()
        return titles.filter { seen.insert($0).inserted }
    }

    /// Resolves a jurisdiction label (full state name, postal code, or common abbreviation) to a
    /// two-letter postal code, or nil for federal/court jurisdictions that have no state statutes.
    /// Public so federal-only sources (e.g. eCFR) can skip state-specific queries.
    public static func postalCode(forJurisdiction jurisdiction: String) -> String? {
        let key = jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        if let direct = stateNameToPostal[key] { return direct }
        // Accept a bare postal code ("fl") if it's a real state.
        if key.count == 2, Set(stateNameToPostal.values).contains(key.uppercased()) {
            return key.uppercased()
        }
        return nil
    }

    private static let stateNameToPostal: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "florida": "FL", "georgia": "GA",
        "hawaii": "HI", "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA",
        "kansas": "KS", "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS", "missouri": "MO",
        "montana": "MT", "nebraska": "NE", "nevada": "NV", "new hampshire": "NH", "new jersey": "NJ",
        "new mexico": "NM", "new york": "NY", "north carolina": "NC", "north dakota": "ND", "ohio": "OH",
        "oklahoma": "OK", "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
        "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT",
        "virginia": "VA", "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
        "district of columbia": "DC"
    ]
}
