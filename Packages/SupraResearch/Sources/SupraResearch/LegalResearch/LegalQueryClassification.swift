import Foundation

public struct LegalQueryClassification: Codable, Hashable, Sendable {
    public var jurisdiction: String?
    public var courtLevel: String?
    public var legalIssue: String
    public var proceduralPosture: String?
    public var desiredAuthorityType: LegalAuthorityType
    public var dateSensitivity: String?
    public var courtIDs: [String]
    public var dateFiledAfter: String?
    public var dateFiledBefore: String?
    public var bindingAuthorityRequired: Bool
    public var adverseAuthorityRequested: Bool
    public var citationLookup: String?
    public var jurisdictionContext: String?

    public init(
        jurisdiction: String? = nil,
        courtLevel: String? = nil,
        legalIssue: String,
        proceduralPosture: String? = nil,
        desiredAuthorityType: LegalAuthorityType = .case,
        dateSensitivity: String? = nil,
        courtIDs: [String] = [],
        dateFiledAfter: String? = nil,
        dateFiledBefore: String? = nil,
        bindingAuthorityRequired: Bool = false,
        adverseAuthorityRequested: Bool = false,
        citationLookup: String? = nil,
        jurisdictionContext: String? = nil
    ) {
        self.jurisdiction = jurisdiction
        self.courtLevel = courtLevel
        self.legalIssue = legalIssue
        self.proceduralPosture = proceduralPosture
        self.desiredAuthorityType = desiredAuthorityType
        self.dateSensitivity = dateSensitivity
        self.courtIDs = courtIDs
        self.dateFiledAfter = dateFiledAfter
        self.dateFiledBefore = dateFiledBefore
        self.bindingAuthorityRequired = bindingAuthorityRequired
        self.adverseAuthorityRequested = adverseAuthorityRequested
        self.citationLookup = citationLookup
        self.jurisdictionContext = jurisdictionContext
    }

    public var needsJurisdictionForAuthority: Bool {
        jurisdiction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

public enum LegalQueryClassifier {
    public static func classify(_ prompt: String) -> LegalQueryClassification {
        let lower = prompt.lowercased()
        let citation = firstCitation(in: prompt)
        let jurisdictionMatch = firstJurisdiction(in: prompt)
        let courtIDs = firstCourtIDs(in: prompt)
        let dateRange = dateRange(in: prompt)
        let desiredType: LegalAuthorityType
        if lower.contains("docket") {
            desiredType = .docket
        } else if lower.contains("statute") || lower.contains("code section") || lower.contains("§")
            || lower.contains("u.s.c") || lower.contains("c.f.r") || lower.contains("limitations period")
            || lower.contains("statute of limitations") || lower.contains("deadline") {
            desiredType = .statute
        } else {
            desiredType = .case
        }

        return LegalQueryClassification(
            jurisdiction: jurisdictionMatch?.name,
            courtLevel: firstCourtLevel(in: lower),
            legalIssue: searchIssue(from: prompt, jurisdiction: jurisdictionMatch?.name),
            proceduralPosture: firstProceduralPosture(in: lower),
            desiredAuthorityType: desiredType,
            dateSensitivity: dateSensitivity(in: lower),
            courtIDs: courtIDs,
            dateFiledAfter: dateRange.after,
            dateFiledBefore: dateRange.before,
            bindingAuthorityRequired: lower.contains("binding") || lower.contains("controlling"),
            adverseAuthorityRequested: lower.contains("adverse") || lower.contains("limiting authority") || lower.contains("red flag"),
            citationLookup: citation
        )
    }

    public static func firstCitation(in text: String) -> String? {
        let patterns = [
            #"(?i)\b\d{1,4}\s+U\.?\s?S\.?\s?C\.?(?:A\.?)?\s*§+\s*[\w().-]+"#,
            #"(?i)\b\d{1,4}\s+C\.?\s?F\.?\s?R\.?\s*§+\s*[\w().-]+"#,
            #"(?i)\b\d{1,4}\s+U\.S\.\s+\d{1,5}\b"#,
            #"(?i)\b\d{1,4}\s+S\.?\s?Ct\.?\s+\d{1,5}\b"#,
            #"(?i)\b\d{1,4}\s+F\.?\s?(?:2d|3d|4th|Supp\.?\s?2d|Supp\.?\s?3d)?\s+\d{1,5}\b"#,
            #"(?i)\b\d{1,4}\s+(?:Cal\.?(?:\s+App\.?)?|N\.Y\.?|So\.?|S\.W\.?|N\.E\.?|P\.?)\s?(?:2d|3d|4th|5th)?\s+\d{1,5}\b"#,
            #"(?i)\b\d{1,4}\s+[A-Z][A-Za-z. ]{1,30}\s+\d{1,5}\b"#,
            #"(?i)\b\d{4}\s+WL\s+\d+\b"#,
            #"\b[A-Z][A-Za-z0-9&'.-]*(?:\s+(?:of|the|and|[A-Z][A-Za-z0-9&'.-]*)){0,5}\s+v\.?\s+[A-Z][A-Za-z0-9&'.-]*(?:\s+(?:of|the|and|[A-Z][A-Za-z0-9&'.-]*)){0,5}(?:,\s+\d{1,4}\s+(?:Cal\.?(?:\s+App\.?)?|[A-Z][A-Za-z. ]{1,30})\s?(?:2d|3d|4th|5th)?\s+\d{1,5})?"#,
            #"(?i)\b(?:[A-Z][A-Za-z. ]+\s+)?(?:Code|Stat\.?|Rev\. Stat\.?|Civ\. Code|Bus\. & Prof\. Code)\s+§+\s*[\w().-]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let swiftRange = Range(match.range, in: text) {
                return cleanedCitationMatch(String(text[swiftRange]))
            }
        }
        return nil
    }

    private static func cleanedCitationMatch(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:"))
        )
        let leadingCommands = [
            "please find ",
            "find ",
            "research ",
            "verify ",
            "check ",
            "analyze ",
            "discuss ",
            "summarize ",
            "locate "
        ]
        for command in leadingCommands {
            if cleaned.range(of: command, options: [.caseInsensitive, .anchored]) != nil {
                cleaned.removeFirst(command.count)
                return trimmedCitationTail(cleaned)
            }
        }
        return trimmedCitationTail(cleaned)
    }

    private static func trimmedCitationTail(_ value: String) -> String {
        var cleaned = value
        let stopPhrases = [
            " for ",
            " about ",
            " regarding ",
            " re ",
            " on ",
            " under "
        ]
        for phrase in stopPhrases {
            if let range = cleaned.range(of: phrase, options: [.caseInsensitive]) {
                cleaned = String(cleaned[..<range.lowerBound])
                break
            }
        }
        return cleaned.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:"))
        )
    }

    private struct JurisdictionMatch {
        var name: String
        var courtIDs: [String]
        var aliases: [String]
    }

    private static func firstJurisdiction(in prompt: String) -> JurisdictionMatch? {
        let lower = prompt.lowercased()
        return jurisdictionMatches.first { match in
            match.aliases.contains { alias in
                lower.range(of: alias, options: [.caseInsensitive, .regularExpression]) != nil
            }
        }
    }

    private static func firstCourtIDs(in prompt: String) -> [String] {
        let lower = prompt.lowercased()
        var ids: [String] = []
        for match in jurisdictionMatches {
            if match.aliases.contains(where: { lower.range(of: $0, options: [.caseInsensitive, .regularExpression]) != nil }) {
                ids.append(contentsOf: match.courtIDs)
            }
        }
        for court in courtIDAliases {
            if court.aliases.contains(where: { lower.range(of: $0, options: [.caseInsensitive, .regularExpression]) != nil }) {
                ids.append(court.id)
            }
        }
        return Array(Set(ids)).sorted()
    }

    private static func firstCourtLevel(in lower: String) -> String? {
        if lower.contains("supreme court") { return "supreme" }
        if lower.contains("court of appeals") || lower.contains("circuit") { return "appellate" }
        if lower.contains("district court") || lower.contains("trial court") { return "trial" }
        return nil
    }

    private static func firstProceduralPosture(in lower: String) -> String? {
        let postures = [
            "summary judgment", "motion to dismiss", "preliminary injunction",
            "temporary restraining order", "appeal", "class certification",
            "default judgment", "directed verdict"
        ]
        return postures.first { lower.contains($0) }
    }

    private static func dateSensitivity(in lower: String) -> String? {
        if lower.contains("current") || lower.contains("latest") || lower.contains("recent") {
            return "current_or_recent"
        }
        if lower.contains("after ") || lower.contains("since ") {
            return "date_limited"
        }
        return nil
    }

    private static func dateRange(in prompt: String) -> (after: String?, before: String?) {
        let lower = prompt.lowercased()
        if lower.contains("current") || lower.contains("latest") || lower.contains("recent") {
            let year = Calendar(identifier: .gregorian).component(.year, from: Date()) - 10
            return ("\(year)-01-01", nil)
        }
        if let range = firstMatch(#"(?i)\b(?:from|between)\s+(\d{4})(?:-\d{2}-\d{2})?\s+(?:to|and|through|-)\s+(\d{4})(?:-\d{2}-\d{2})?\b"#, in: prompt),
           range.count >= 3 {
            return (normalizeDate(range[1], lowerBound: true), normalizeDate(range[2], lowerBound: false))
        }
        var after: String?
        var before: String?
        if let match = firstMatch(#"(?i)\b(?:after|since)\s+(\d{4}(?:-\d{2}-\d{2})?)\b"#, in: prompt),
           match.count >= 2 {
            after = normalizeDate(match[1], lowerBound: true)
        }
        if let match = firstMatch(#"(?i)\b(?:before|through|until)\s+(\d{4}(?:-\d{2}-\d{2})?)\b"#, in: prompt),
           match.count >= 2 {
            before = normalizeDate(match[1], lowerBound: false)
        }
        return (after, before)
    }

    private static func searchIssue(from prompt: String, jurisdiction: String?) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let removablePatterns = [
            #"(?i)\bfind\s+(?:binding|controlling|adverse|recent|current)?\s*(?:authority|case law|cases)?\b"#,
            #"(?i)\bresearch\b"#,
            #"(?i)\b(?:after|since|before|through|until)\s+\d{4}(?:-\d{2}-\d{2})?\b"#,
            #"(?i)\b(?:from|between)\s+\d{4}(?:-\d{2}-\d{2})?\s+(?:to|and|through|-)\s+\d{4}(?:-\d{2}-\d{2})?\b"#
        ]
        if let jurisdiction {
            text = text.replacingOccurrences(of: jurisdiction, with: "", options: [.caseInsensitive])
        }
        for pattern in removablePatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? prompt.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func normalizeDate(_ value: String, lowerBound: Bool) -> String {
        if value.count == 4 {
            return lowerBound ? "\(value)-01-01" : "\(value)-12-31"
        }
        return value
    }

    private static let jurisdictionMatches: [JurisdictionMatch] = [
        JurisdictionMatch(name: "California", courtIDs: ["cal", "calctapp"], aliases: [#"\bcalifornia\b"#, #"\bca\b"#, #"\bcal\.\b"#]),
        JurisdictionMatch(name: "New York", courtIDs: ["ny", "nyappdiv"], aliases: [#"\bnew york\b"#, #"\bny\b"#, #"\bn\.y\.\b"#]),
        JurisdictionMatch(name: "Delaware", courtIDs: ["del", "delch"], aliases: [#"\bdelaware\b"#, #"\bdel\.\b"#]),
        JurisdictionMatch(name: "Florida", courtIDs: ["fla", "fladistctapp"], aliases: [#"\bflorida\b"#, #"\bfla\.\b"#, #"\bfl\b"#]),
        JurisdictionMatch(name: "Texas", courtIDs: ["tex", "texapp"], aliases: [#"\btexas\b"#, #"\btex\.\b"#, #"\btx\b"#]),
        JurisdictionMatch(name: "District of Columbia", courtIDs: ["dc", "dcctapp"], aliases: [#"\bdistrict of columbia\b"#, #"\bd\.c\.\b"#]),
        JurisdictionMatch(name: "Ninth Circuit", courtIDs: ["ca9"], aliases: [#"\bninth circuit\b"#, #"\b9th cir\.?\b"#, #"\bca9\b"#]),
        JurisdictionMatch(name: "Second Circuit", courtIDs: ["ca2"], aliases: [#"\bsecond circuit\b"#, #"\b2d cir\.?\b"#, #"\b2nd cir\.?\b"#, #"\bca2\b"#]),
        JurisdictionMatch(name: "Fifth Circuit", courtIDs: ["ca5"], aliases: [#"\bfifth circuit\b"#, #"\b5th cir\.?\b"#, #"\bca5\b"#]),
        JurisdictionMatch(name: "Eleventh Circuit", courtIDs: ["ca11"], aliases: [#"\beleventh circuit\b"#, #"\b11th cir\.?\b"#, #"\bca11\b"#]),
        JurisdictionMatch(name: "Federal Circuit", courtIDs: ["cafc"], aliases: [#"\bfederal circuit\b"#, #"\bcafc\b"#]),
        JurisdictionMatch(name: "United States Supreme Court", courtIDs: ["scotus"], aliases: [#"\bunited states supreme court\b"#, #"\bu\.s\. supreme court\b"#, #"\bscotus\b"#])
    ]

    private static let courtIDAliases: [(id: String, aliases: [String])] = [
        ("cand", [#"\bn\.d\. cal\.?\b"#, #"\bnorthern district of california\b"#]),
        ("cacd", [#"\bc\.d\. cal\.?\b"#, #"\bcentral district of california\b"#]),
        ("caed", [#"\be\.d\. cal\.?\b"#, #"\beastern district of california\b"#]),
        ("casd", [#"\bs\.d\. cal\.?\b"#, #"\bsouthern district of california\b"#]),
        ("nysd", [#"\bs\.d\.n\.y\.?\b"#, #"\bsouthern district of new york\b"#]),
        ("nyed", [#"\be\.d\.n\.y\.?\b"#, #"\beastern district of new york\b"#]),
        ("ded", [#"\bd\. del\.?\b"#, #"\bdistrict of delaware\b"#]),
        ("txsd", [#"\bs\.d\. tex\.?\b"#, #"\bsouthern district of texas\b"#]),
        ("flsd", [#"\bs\.d\. fla\.?\b"#, #"\bsouthern district of florida\b"#])
    ]
}
