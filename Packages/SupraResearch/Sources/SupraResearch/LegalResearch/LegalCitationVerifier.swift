import Foundation

public enum LegalVerificationIssueKind: String, Codable, Hashable, Sendable {
    case unsupportedCitation = "unsupported_citation"
    case missingCitation = "missing_citation"
    case unsupportedQuote = "unsupported_quote"
    case jurisdictionMismatch = "jurisdiction_mismatch"
    case noRetrievedAuthorities = "no_retrieved_authorities"
}

public struct LegalVerificationIssue: Codable, Hashable, Sendable {
    public var kind: LegalVerificationIssueKind
    public var message: String
    public var excerpt: String?
}

public struct LegalVerificationReport: Codable, Hashable, Sendable {
    public var passed: Bool
    public var issues: [LegalVerificationIssue]
    public var retrievedAuthorityIDs: [String]
    public var citedStrings: [String]

    public init(
        passed: Bool,
        issues: [LegalVerificationIssue],
        retrievedAuthorityIDs: [String],
        citedStrings: [String]
    ) {
        self.passed = passed
        self.issues = issues
        self.retrievedAuthorityIDs = retrievedAuthorityIDs
        self.citedStrings = citedStrings
    }
}

public enum LegalCitationVerifier {
    public static func verify(
        answer: String,
        authorities: [LegalAuthority],
        expectedJurisdiction: String? = nil
    ) -> LegalVerificationReport {
        var issues: [LegalVerificationIssue] = []
        if authorities.isEmpty {
            issues.append(
                LegalVerificationIssue(
                    kind: .noRetrievedAuthorities,
                    message: "No CourtListener authorities were retrieved, so legal propositions cannot be verified.",
                    excerpt: nil
                )
            )
        }

        let extracted = extractCitationLikeStrings(from: answer)
        for citation in extracted where !isCitationSupported(citation, by: authorities) {
            issues.append(
                LegalVerificationIssue(
                    kind: .unsupportedCitation,
                    message: "Citation was not present in the retrieved CourtListener authority packet.",
                    excerpt: citation
                )
            )
        }

        let authorityText = authorities.map {
            [$0.text, $0.snippet, $0.caseName, $0.citation, $0.url].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        for quote in extractQuotedText(from: answer) where quote.count >= 12 {
            if !authorityText.localizedCaseInsensitiveContains(quote) {
                issues.append(
                    LegalVerificationIssue(
                        kind: .unsupportedQuote,
                        message: "Quoted text does not appear verbatim in the retrieved source packet.",
                        excerpt: quote
                    )
                )
            }
        }

        for line in answer.components(separatedBy: .newlines) where looksLikeLegalProposition(line) {
            let lineHasKnownCitation = authorities.contains { authority in
                authority.allCitationStrings.contains { line.localizedCaseInsensitiveContains($0) }
                    || (authority.url.map { line.localizedCaseInsensitiveContains($0) } ?? false)
            }
            if !lineHasKnownCitation {
                issues.append(
                    LegalVerificationIssue(
                        kind: .missingCitation,
                        message: "Legal proposition does not contain a citation to a retrieved authority.",
                        excerpt: line.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }

        if let expectedJurisdiction,
           !expectedJurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !authorities.isEmpty {
            // Per-cited-authority jurisdiction check: flag each citation whose
            // backing authority sits in a different jurisdiction than requested,
            // rather than a single packet-wide any-of (which passed as long as
            // *some* unrelated authority matched).
            var flaggedExcerpts = Set<String>()
            for citation in extracted {
                guard let authority = supportingAuthority(for: citation, among: authorities) else { continue }
                let jurisdictionStrings = [authority.jurisdiction, authority.court, authority.courtID].compactMap { $0 }
                let matchesJurisdiction = jurisdictionStrings.contains { jurisdictionMatches(expectedJurisdiction, $0) }
                if !matchesJurisdiction, flaggedExcerpts.insert(citation).inserted {
                    issues.append(
                        LegalVerificationIssue(
                            kind: .jurisdictionMismatch,
                            message: "The cited authority does not clearly belong to the requested jurisdiction (\(expectedJurisdiction)).",
                            excerpt: citation
                        )
                    )
                }
            }
        }

        return LegalVerificationReport(
            passed: issues.isEmpty,
            issues: issues,
            retrievedAuthorityIDs: authorities.map(\.id),
            citedStrings: extracted
        )
    }

    public static func markdownReport(_ report: LegalVerificationReport) -> String {
        if report.passed {
            return "Verification passed: all detected citations and quotes map to the retrieved source packet."
        }
        var lines = ["Verification warnings:"]
        for issue in report.issues {
            if let excerpt = issue.excerpt, !excerpt.isEmpty {
                lines.append("- \(issue.kind.rawValue): \(issue.message) Excerpt: \(excerpt)")
            } else {
                lines.append("- \(issue.kind.rawValue): \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func extractCitationLikeStrings(from text: String) -> [String] {
        citationMatches(in: text, patterns: reporterCitationPatterns + federalStatutoryCitationPatterns + otherAuthorityCitationPatterns + [caseNameCitationPattern, statutoryCitationPattern])
    }

    /// Federal statutory/regulatory forms whose section sigil ("§") sits between
    /// the reporter abbreviation and the number — e.g. "42 U.S.C. § 1983",
    /// "29 U.S.C.A. § 158", "20 C.F.R. § 404.1520". These are the highest-traffic
    /// citation class in U.S. legal writing and would otherwise evade extraction
    /// (the generic reporter pattern breaks on the "§").
    private static let federalStatutoryCitationPatterns = [
        #"(?i)\b\d{1,4}\s+U\.?\s?S\.?\s?C\.?(?:A\.?)?\s*§+\s*[\w().-]+"#,
        #"(?i)\b\d{1,4}\s+C\.?\s?F\.?\s?R\.?\s*§+\s*[\w().-]+"#
    ]

    /// Other high-traffic authority forms the generic patterns miss: federal
    /// procedural/evidence rules, public laws, the Federal Register, the U.C.C.,
    /// and Restatements. Recognizing them makes a fabricated instance extractable
    /// and therefore subject to the same supported/unsupported matching.
    private static let otherAuthorityCitationPatterns = [
        #"(?i)\bFed\.?\s*R\.?\s*(?:Civ|Crim|App|Evid|Bankr)\.?\s*(?:P\.?)?\s*\d+(?:\([\w]+\))*"#,
        #"(?i)\bPub\.?\s*L\.?\s*(?:No\.?)?\s*\d+[-–]\d+"#,
        #"(?i)\b\d{1,4}\s+Fed\.?\s*Reg\.?\s+[\d,]+"#,
        #"(?i)\bU\.?\s?C\.?\s?C\.?\s*§+\s*[\w().-]+"#,
        #"(?i)\bRestatement\b[^§\n]{0,40}§+\s*[\w().-]+"#
    ]

    private static let reporterCitationPatterns = [
        #"(?i)\b\d{1,4}\s+U\.S\.\s+\d{1,5}\b"#,
        #"(?i)\b\d{1,4}\s+S\.?\s?Ct\.?\s+\d{1,5}\b"#,
        #"(?i)\b\d{1,4}\s+F\.?\s?(?:2d|3d|4th|Supp\.?\s?2d|Supp\.?\s?3d)?\s+\d{1,5}\b"#,
        #"(?i)\b\d{1,4}\s+(?:Cal\.?(?:\s+App\.?)?|N\.Y\.?|So\.?|S\.W\.?|N\.E\.?|P\.?)\s?(?:2d|3d|4th|5th)?\s+\d{1,5}\b"#,
        #"(?i)\b\d{1,4}\s+[A-Z][A-Za-z. ]{1,30}\s+\d{1,5}\b"#,
        #"(?i)\b\d{4}\s+WL\s+\d+\b"#
    ]

    private static let caseNameCitationPattern = #"\b[A-Z][A-Za-z0-9&'.-]*(?:\s+(?:of|the|and|[A-Z][A-Za-z0-9&'.-]*)){0,5}\s+v\.?\s+[A-Z][A-Za-z0-9&'.-]*(?:\s+(?:of|the|and|[A-Z][A-Za-z0-9&'.-]*)){0,5}(?:,\s+\d{1,4}\s+(?:Cal\.?(?:\s+App\.?)?|[A-Z][A-Za-z. ]{1,30})\s?(?:2d|3d|4th|5th)?\s+\d{1,5})?"#
    private static let statutoryCitationPattern = #"(?i)\b(?:[A-Z][A-Za-z. ]+\s+)?(?:Code|Stat\.?|Rev\. Stat\.?|Civ\. Code|Bus\. & Prof\. Code)\s+§+\s*[\w().-]+"#

    private static func citationMatches(in text: String, patterns: [String]) -> [String] {
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                found.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return removeContainedDuplicates(found)
    }

    private static func removeContainedDuplicates(_ values: [String]) -> [String] {
        let unique = Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        return unique.filter { candidate in
            let normalizedCandidate = normalized(candidate)
            return !unique.contains { other in
                let normalizedOther = normalized(other)
                return normalizedOther != normalizedCandidate
                    && normalizedOther.contains(normalizedCandidate)
            }
        }.sorted()
    }

    private static func isCitationSupported(_ citation: String, by authorities: [LegalAuthority]) -> Bool {
        supportingAuthority(for: citation, among: authorities) != nil
    }

    /// The single retrieved authority that backs a citation, or `nil` if none do.
    ///
    /// Matching is deliberately strict so a hallucinated citation cannot be marked
    /// "verified": reporter cites must match a known reporter string exactly, and
    /// case names are compared by significant party tokens (the cited parties must
    /// be a subset of the authority's parties on each side of "v.") — never via
    /// free bidirectional substring containment, which previously let an unrelated
    /// authority "support" a fabricated cite.
    private static func supportingAuthority(for citation: String, among authorities: [LegalAuthority]) -> LegalAuthority? {
        let reporterCitations = citationMatches(in: citation, patterns: reporterCitationPatterns)
        let caseName = caseNamePart(from: citation)
        if !reporterCitations.isEmpty {
            return authorities.first { authority in
                let authorityStrings = authority.allCitationStrings
                let reporterSupported = reporterCitations.allSatisfy { reporter in
                    authorityStrings.contains { known in
                        exactCitationMatch(reporter, known)
                            || citationMatches(in: known, patterns: reporterCitationPatterns).contains {
                                exactCitationMatch(reporter, $0)
                            }
                    }
                }
                // A matching reporter with a non-matching/fabricated case name is
                // not support — require both when the cite carries a case name.
                let caseNameSupported = caseName.map { caseNameTokensSupported($0, by: authorityStrings) } ?? true
                return reporterSupported && caseNameSupported
            }
        }

        // No reporter: a case-name cite is supported only by a strict token match;
        // any other bare cite (e.g. a statute) needs exact normalized equality.
        if let caseName {
            return authorities.first { caseNameTokensSupported(caseName, by: $0.allCitationStrings) }
        }
        return authorities.first { authority in
            authority.allCitationStrings.contains { exactCitationMatch(citation, $0) }
        }
    }

    /// Generic connectives and corporate suffixes that carry no identifying weight
    /// in a case name. Meaningful institutional parties (People, State, County,
    /// City, Commonwealth, United States) are deliberately NOT stripped.
    private static let genericPartyTokens: Set<String> = [
        "the", "of", "and", "a", "an", "in", "re", "ex", "rel",
        "inc", "incorporated", "corp", "corporation", "co", "company",
        "llc", "lp", "llp", "plc", "ltd", "limited", "et", "al"
    ]

    /// True when the cited case name's significant party tokens are a non-empty
    /// subset of some authority string's party tokens on each side of "v.".
    private static func caseNameTokensSupported(_ citedName: String, by authorityStrings: [String]) -> Bool {
        guard let cited = partySides(of: citedName), !cited.left.isEmpty, !cited.right.isEmpty else { return false }
        return authorityStrings.contains { candidate in
            guard let auth = partySides(of: candidate) else { return false }
            return cited.left.isSubset(of: auth.left) && cited.right.isSubset(of: auth.right)
        }
    }

    /// Splits a case name into significant token sets on each side of the "v."
    /// separator, or `nil` if there is no recognizable "X v. Y" structure.
    private static func partySides(of value: String) -> (left: Set<String>, right: Set<String>)? {
        guard let vRange = value.range(of: #"\sv\.?\s|\svs\.?\s"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let left = significantPartyTokens(String(value[..<vRange.lowerBound]))
        // Drop anything after a comma on the right (reporter/pincite tails).
        var rightSide = String(value[vRange.upperBound...])
        if let comma = rightSide.firstIndex(of: ",") {
            rightSide = String(rightSide[..<comma])
        }
        let right = significantPartyTokens(rightSide)
        return (left, right)
    }

    private static func significantPartyTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !genericPartyTokens.contains($0) }
        )
    }

    /// Fuzzy jurisdiction comparison: exact normalized match, or substring overlap
    /// only when both sides are long enough to be meaningful (avoids spurious
    /// 1–3 character matches like "ca" matching "California").
    private static func jurisdictionMatches(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func caseNamePart(from citation: String) -> String? {
        let candidate: String
        if let comma = citation.firstIndex(of: ",") {
            candidate = String(citation[..<comma])
        } else {
            candidate = citation
        }
        guard candidate.range(of: #"\bv\.?\s"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:")))
    }

    private static func exactCitationMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func extractQuotedText(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"["“”]([^"“”]+)["“”]"#) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func looksLikeLegalProposition(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30 else { return false }
        let lower = trimmed.lowercased()
        let markers = [
            "must", "shall", "requires", "required", "element", "standard",
            "holding", "held", "rule", "law", "court", "statute", "claim",
            "burden", "liability", "damages", "jurisdiction", "defense",
            "injunction", "contract", "dismiss", "summary judgment", "standing",
            "limitations", "preempt", "constitutional", "enforceable", "unenforceable"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
