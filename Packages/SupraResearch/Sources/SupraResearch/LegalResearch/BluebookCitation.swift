import Foundation

/// Builds a Bluebook-style full citation with an optional pin cite, for the
/// opinion readers' "copy with citation" behavior:
///
///     Rush v. Savchuk, 444 U.S. 320, 328 (1980).
///     SunTrust Bank v. Houghton Mifflin Co., 268 F.3d 1257, 1260–61 (11th Cir. 2001).
///
/// Court abbreviation is best-effort (SCOTUS, federal circuits, federal
/// districts, state high courts, and common state appellate patterns); an
/// unrecognized court degrades to a year-only parenthetical rather than
/// inventing an abbreviation.
public struct BluebookCitation: Sendable, Equatable {
    public var caseName: String
    public var citation: String?
    public var court: String?
    public var courtID: String?
    public var year: Int?

    public init(caseName: String, citation: String?, court: String?, courtID: String? = nil, year: Int?) {
        self.caseName = caseName
        self.citation = citation
        self.court = court
        self.courtID = courtID
        self.year = year
    }

    /// Year from an ISO-ish date string ("1980-01-21" → 1980).
    public static func year(fromDateFiled date: String?) -> Int? {
        guard let date, date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
        return (1600...2200).contains(year) ? year : nil
    }

    /// The reporter's first page ("444 U.S. 320" → 320).
    public var firstPage: Int? {
        guard let citation,
              let match = citation.range(of: #"(\d{1,5})\s*$"#, options: .regularExpression) else { return nil }
        return Int(citation[match].trimmingCharacters(in: .whitespaces))
    }

    /// The full citation, with `pinPages` (start, end) rendered Bluebook-style
    /// ("328" or "328–29"). A pin equal only to the first page still prints.
    public func formatted(pinPages: (Int, Int)? = nil) -> String {
        var parts: [String] = [Self.cleanedCaseName(caseName)]
        if let citation, !citation.isEmpty {
            var cite = citation
            if let pinPages {
                cite += ", " + Self.pinRange(pinPages)
            }
            parts.append(cite)
        }
        var result = parts.joined(separator: ", ")
        let paren = [courtAbbreviation, year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " ")
        if !paren.isEmpty {
            result += " (\(paren))"
        }
        return result + "."
    }

    /// "328" for a single page; "328–29" Bluebook-collapsed for a span.
    static func pinRange(_ pages: (Int, Int)) -> String {
        let (start, end) = pages
        guard end > start else { return String(start) }
        let startString = String(start)
        let endString = String(end)
        // Collapse the shared prefix ("328–29", "1257–61"), but never to fewer
        // than two digits of the end page.
        if endString.count == startString.count {
            var sharedPrefix = 0
            for (a, b) in zip(startString, endString) {
                if a == b { sharedPrefix += 1 } else { break }
            }
            let keep = max(2, endString.count - sharedPrefix)
            return "\(startString)–\(endString.suffix(keep))"
        }
        return "\(startString)–\(endString)"
    }

    /// Strips a citation tail that rode into the caption ("Rush v. Savchuk,
    /// 444 U.S. 320" → "Rush v. Savchuk") and re-cases an ALL-CAPS filing
    /// caption into cite style.
    static func cleanedCaseName(_ name: String) -> String {
        let stripped = name.replacingOccurrences(
            of: #",\s*\d{1,4}\s+[A-Za-z. ]{1,30}\s+\d{1,5}.*$"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return recasedCaption(stripped)
    }

    /// Captions arrive in filing style — often ALL CAPS. A citation is title
    /// case ("Adams v. Fritz Martin Cabinetry LLC"), so a predominantly
    /// uppercase caption is re-cased; anything mixed-case passes through
    /// untouched (re-casing would destroy "SunTrust" or "McDonald's").
    static func recasedCaption(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        guard letters.count >= 4 else { return name }
        let uppercase = letters.filter(\.isUppercase).count
        // 0.7, not higher: CourtListener captions arrive as "FLAGG BROS., INC.,
        // Et Al. v. BROOKS Et Al." — the mixed "Et Al." particles dilute the
        // ratio of an otherwise ALL-CAPS caption. Ordinary mixed-case captions
        // sit far below this line ("SunTrust Bank v. …" ≈ 0.25).
        guard Double(uppercase) / Double(letters.count) > 0.7 else { return name }

        let words = name.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let recased = words.enumerated().map { index, word in
            recasedWord(word, isFirst: index == 0)
        }
        var caption = recased.joined(separator: " ")
        // Procedural phrases keep their Bluebook lowercase particle.
        caption = caption.replacingOccurrences(of: "In Re ", with: "In re ")
        caption = caption.replacingOccurrences(of: "Ex Parte ", with: "Ex parte ")
        caption = caption.replacingOccurrences(of: "Ex Rel", with: "ex rel")
        return caption
    }

    private static func recasedWord(_ word: String, isFirst: Bool) -> String {
        let key = word.filter(\.isLetter).uppercased()
        // The versus particle.
        if key == "V" || key == "VS" { return word.lowercased() }
        // Small words stay lowercase mid-caption ("Bank of America", "et al.").
        let smallWords: Set<String> = ["OF", "THE", "AND", "IN", "ON", "AT", "FOR", "A", "AN", "TO", "BY", "RE", "ET", "AL", "EX", "REL"]
        if !isFirst, smallWords.contains(key) { return word.lowercased() }
        // Initialisms with periods keep their capitals ("U.S.", "J.B.", "P.A.").
        if word.range(of: #"^\(?(?:[A-Za-z]\.){2,},?\)?$"#, options: .regularExpression) != nil {
            return word.uppercased()
        }
        // Entity designators, agency acronyms, and roman numerals keep their
        // capitals — "SEC V. SMITH" must not become "Sec v. Smith".
        let keepUppercase: Set<String> = [
            "LLC", "LLP", "PLLC", "LP", "PLC", "NA", "FSB", "USA", "DCA",
            "NLRB", "FTC", "SEC", "FCC", "FDA", "EPA", "EEOC", "FBI", "IRS",
            "INS", "ICE", "DOJ", "DHS", "HHS", "HUD", "OSHA", "TVA", "NCAA",
            "NAACP", "ACLU", "AFL", "CIO", "UPS", "IBM", "ATT"
        ]
        if keepUppercase.contains(key) { return word.uppercased() }
        if key.count >= 2, key.allSatisfy({ "IVXLC".contains($0) }) { return word.uppercased() }
        // Default: capitalize each hyphen-separated segment.
        return word.lowercased()
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { segment -> String in
                guard let first = segment.first else { return String(segment) }
                return first.uppercased() + segment.dropFirst()
            }
            .joined(separator: "-")
    }

    // MARK: - Court abbreviation

    public var courtAbbreviation: String? {
        Self.courtAbbreviation(court: court, courtID: courtID, citation: citation)
    }

    public static func courtAbbreviation(court: String?, courtID: String?, citation: String?) -> String? {
        // U.S. Supreme Court: the U.S./S. Ct. reporter speaks for itself — no
        // court in the parenthetical.
        if courtID?.lowercased() == "scotus" { return nil }
        let name = court ?? ""
        let lower = name.lowercased()
        if lower.contains("supreme court of the united states") || lower == "united states supreme court" {
            return nil
        }
        if let citation,
           citation.range(of: #"(?i)\b\d{1,4}\s+(U\.?\s?S\.?|S\.?\s?Ct\.?)\s+\d"#, options: .regularExpression) != nil {
            return nil
        }

        // Federal circuits.
        if let id = courtID?.lowercased() {
            switch id {
            case "cadc": return "D.C. Cir."
            case "cafc": return "Fed. Cir."
            default:
                if id.hasPrefix("ca"), let number = Int(id.dropFirst(2)), (1...11).contains(number) {
                    return "\(ordinal(number)) Cir."
                }
            }
        }
        if let match = lower.range(of: #"court of appeals for the ([a-z. ]+?) circuit"#, options: .regularExpression) {
            let word = String(lower[match]).components(separatedBy: " the ").last?
                .replacingOccurrences(of: " circuit", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            if word.contains("district of columbia") || word == "d.c." { return "D.C. Cir." }
            if word == "federal" { return "Fed. Cir." }
            if let number = ordinalNumber(fromWord: word) { return "\(ordinal(number)) Cir." }
        }

        // Federal districts: "District Court for the Middle District of Florida"
        // → "M.D. Fla."; "District of Massachusetts" (undivided) → "D. Mass."
        if let match = lower.range(
            of: #"district court for the (?:(northern|southern|eastern|western|middle|central) district of ([a-z ]+)|district of ([a-z ]+))"#,
            options: .regularExpression
        ) {
            let fragment = String(lower[match])
            let division = ["northern": "N.", "southern": "S.", "eastern": "E.", "western": "W.", "middle": "M.", "central": "C."]
                .first { fragment.contains("the \($0.key) district") }?.value
            let state = fragment.components(separatedBy: " district of ").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if let stateAbbr = bluebookState(state) {
                return "\(division ?? "")D. \(stateAbbr)"
            }
        }

        // State high courts: "Supreme Court of Florida" → "Fla."
        if let match = lower.range(of: #"supreme court of ([a-z ]+)$"#, options: .regularExpression) {
            let state = String(lower[match]).replacingOccurrences(of: "supreme court of ", with: "")
            if let stateAbbr = bluebookState(state) { return stateAbbr }
        }
        // Florida DCAs use the FLORIDA-style abbreviation ("Fla. 1st DCA") —
        // the convention Florida practitioners cite by — not the generic
        // Bluebook "Fla. Dist. Ct. App." form. District from the court name;
        // an unidentifiable district degrades to the generic form.
        if lower.contains("district court of appeal"), lower.contains("florida") || lower.contains("fla.") {
            if let district = floridaDCADistrict(in: lower) {
                return "Fla. \(district) DCA"
            }
            return "Fla. Dist. Ct. App."
        }
        if let match = lower.range(of: #"court of appeals? of ([a-z ]+)$"#, options: .regularExpression) {
            let state = String(lower[match]).components(separatedBy: " of ").last ?? ""
            if let stateAbbr = bluebookState(state) { return "\(stateAbbr) Ct. App." }
        }

        // Unknown: better a year-only parenthetical than a made-up abbreviation.
        return nil
    }

    /// The DCA district ("1st", "2d", …, "6th") from a court name, matching
    /// spelled ordinals ("First District") or digits ("1st District").
    private static func floridaDCADistrict(in lower: String) -> String? {
        let florida: [(word: String, abbreviation: String)] = [
            ("first", "1st"), ("second", "2d"), ("third", "3d"),
            ("fourth", "4th"), ("fifth", "5th"), ("sixth", "6th")
        ]
        for entry in florida where lower.contains(entry.word) {
            return entry.abbreviation
        }
        if let match = lower.range(of: #"\b([1-6])(?:st|nd|rd|th)\b"#, options: .regularExpression),
           let digit = lower[match].first(where: \.isNumber) {
            return ["1": "1st", "2": "2d", "3": "3d", "4": "4th", "5": "5th", "6": "6th"][String(digit)]
        }
        return nil
    }

    private static func ordinal(_ number: Int) -> String {
        switch number {
        case 1: "1st"
        case 2: "2d"
        case 3: "3d"
        default: "\(number)th"
        }
    }

    private static func ordinalNumber(fromWord word: String) -> Int? {
        let words = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
            "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11
        ]
        return words[word.trimmingCharacters(in: .whitespaces)]
    }

    /// Bluebook T10 state abbreviations (full-name keyed).
    static func bluebookState(_ name: String) -> String? {
        let table: [String: String] = [
            "alabama": "Ala.", "alaska": "Alaska", "arizona": "Ariz.", "arkansas": "Ark.",
            "california": "Cal.", "colorado": "Colo.", "connecticut": "Conn.", "delaware": "Del.",
            "florida": "Fla.", "georgia": "Ga.", "hawaii": "Haw.", "idaho": "Idaho",
            "illinois": "Ill.", "indiana": "Ind.", "iowa": "Iowa", "kansas": "Kan.",
            "kentucky": "Ky.", "louisiana": "La.", "maine": "Me.", "maryland": "Md.",
            "massachusetts": "Mass.", "michigan": "Mich.", "minnesota": "Minn.",
            "mississippi": "Miss.", "missouri": "Mo.", "montana": "Mont.", "nebraska": "Neb.",
            "nevada": "Nev.", "new hampshire": "N.H.", "new jersey": "N.J.", "new mexico": "N.M.",
            "new york": "N.Y.", "north carolina": "N.C.", "north dakota": "N.D.", "ohio": "Ohio",
            "oklahoma": "Okla.", "oregon": "Or.", "pennsylvania": "Pa.", "rhode island": "R.I.",
            "south carolina": "S.C.", "south dakota": "S.D.", "tennessee": "Tenn.",
            "texas": "Tex.", "utah": "Utah", "vermont": "Vt.", "virginia": "Va.",
            "washington": "Wash.", "west virginia": "W. Va.", "wisconsin": "Wis.", "wyoming": "Wyo."
        ]
        return table[name.trimmingCharacters(in: .whitespaces)]
    }
}

/// Locates the reporter page in force at a character offset, from the star
/// pagination CourtListener's plain text carries ("*328" / "[*328]" markers).
/// Returns nil when the text carries no plausible markers — callers omit the
/// pin cite rather than guess.
public enum StarPagination {
    /// The page at `offset`, i.e. the last marker at or before it. `firstPage`
    /// (from the citation) sanity-bounds markers so a stray "*3" footnote
    /// symbol can't read as page 3 of a 320-first-page reporter.
    /// Marker families, in one pass:
    /// - `*152` / `[*152]` — star pagination (Harvard/Columbia-sourced text)
    /// - `Page 436 U. S. 152` — Justia-style reporter page headers, which is
    ///   what old SCOTUS records carry once their HTML is stripped to text
    /// - a bare `-152-` alone on a line — centered page numbers
    static let markerPattern =
        #"\[?\*\s?(\d{1,5})\]?"# + "|" +
        #"(?i)\bpage\s+\d{1,4}\s+[a-z][a-z0-9. ]{0,12}?\s+(\d{1,5})\b"# + "|" +
        #"(?m)^\s*-\s?(\d{1,5})\s?-\s*$"#

    public static func page(at offset: Int, in text: String, firstPage: Int? = nil) -> Int? {
        guard offset >= 0, !text.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return nil }
        let bound = min(offset, (text as NSString).length)
        let range = NSRange(location: 0, length: bound)
        var page: Int?
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            for group in 1..<match.numberOfRanges {
                guard let valueRange = Range(match.range(at: group), in: text),
                      let value = Int(text[valueRange]) else { continue }
                if let firstPage, value < firstPage || value > firstPage + 2_000 { continue }
                page = value
                break
            }
        }
        return page
    }

    /// Pin range for a selection: pages at its start and end offsets.
    public static func pages(
        forSelectionAt location: Int,
        length: Int,
        in text: String,
        firstPage: Int? = nil
    ) -> (Int, Int)? {
        guard let start = page(at: location, in: text, firstPage: firstPage) else { return nil }
        let end = page(at: location + max(0, length), in: text, firstPage: firstPage) ?? start
        return (start, max(start, end))
    }
}
