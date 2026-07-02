import Foundation

public enum LegalVerificationIssueKind: String, Codable, Hashable, Sendable {
    case unsupportedCitation = "unsupported_citation"
    case missingCitation = "missing_citation"
    case unsupportedQuote = "unsupported_quote"
    case jurisdictionMismatch = "jurisdiction_mismatch"
    case noRetrievedAuthorities = "no_retrieved_authorities"
    /// A person/entity name, email, or phone number asserted in a document-grounded
    /// ([S#]) answer that does not appear in the cited source text — i.e. likely
    /// inferred (e.g. a full name reconstructed from an email prefix) rather than read.
    case ungroundedEntity = "ungrounded_entity"
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

        // The model only ever sees the first `maxPacketAuthorities` of the packet, so
        // labels are valid only up to that bound — never the full (possibly larger)
        // retrieved/reconstructed authority list. A label past the visible packet
        // (e.g. [A13] when 12 were shown) points at an authority the model never saw
        // and is a fabricated reference.
        let packetSize = min(authorities.count, LegalResearchPromptBuilder.maxPacketAuthorities)
        for label in Set(packetLabelIndices(in: answer)) where label < 1 || label > packetSize {
            let shown = label == Int.max ? "[A…]" : "[A\(label)]"
            issues.append(
                LegalVerificationIssue(
                    kind: .unsupportedCitation,
                    message: "Cited source label \(shown) does not exist in the source packet.",
                    excerpt: shown
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
            // A proposition is cited if it carries an in-range packet label ([A#]) or
            // a reporter/URL citation that maps to a retrieved authority.
            let lineLabels = packetLabelIndices(in: line).filter { $0 >= 1 && $0 <= packetSize }
            let lineHasReporterCite = authorities.contains { authority in
                authority.allCitationStrings.contains { line.localizedCaseInsensitiveContains($0) }
                    || (authority.url.map { line.localizedCaseInsensitiveContains($0) } ?? false)
            }
            if !lineLabels.isEmpty {
                // A label points at a real packet authority, but the model could
                // attach a valid label to a fabricated paraphrased holding. When the
                // cited authority has substantial (full-opinion) text, require the
                // proposition to actually overlap it; otherwise flag it as unsupported.
                let grounded = lineLabels.contains { propositionGrounded(line, in: authorities[$0 - 1]) }
                if !grounded {
                    issues.append(
                        LegalVerificationIssue(
                            kind: .unsupportedCitation,
                            message: "The cited source does not appear to support this proposition.",
                            excerpt: line.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            } else if !lineHasReporterCite {
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
                // U.S. Supreme Court authority binds every U.S. jurisdiction — it can
                // never be a jurisdiction mismatch, whatever the matter's forum.
                guard !isNationallyBinding(authority) else { continue }
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

        // In-range packet labels count as cited strings, so a label-only answer (the
        // [A#] contract's expected form) is recognized as having a supported citation.
        // Out-of-range / overflow labels are excluded here — they're flagged
        // unsupportedCitation above and must never read as support.
        let labelStrings = Set(packetLabelIndices(in: answer))
            .filter { $0 >= 1 && $0 <= packetSize }
            .map { "[A\($0)]" }

        return LegalVerificationReport(
            passed: issues.isEmpty,
            issues: issues,
            retrievedAuthorityIDs: authorities.map(\.id),
            citedStrings: extracted + labelStrings
        )
    }

    /// Grounding check for DOCUMENT-grounded ([S#]) chat answers: flags person/entity
    /// NAMES, emails, and phone numbers asserted in `answer` that do not appear in the
    /// retrieved `sourceText`. This is what catches the model expanding an email prefix
    /// ("nrust@firm.com") into a full name ("Nancy Rust") it never actually read.
    ///
    /// Deliberately a SOFT signal: the caller surfaces these as an "unverified" warning,
    /// not a suppression, so a correct-but-unstated inference is still shown — just
    /// marked. A name is flagged when any of its significant (multi-letter) tokens is
    /// absent from the source as a whole word; structural/organizational words are
    /// excluded so headings and entity names are not mistaken for people.
    public static func verifyGroundedEntities(answer: String, sourceText: String) -> [LegalVerificationIssue] {
        let sourceWords = wordTokenSet(sourceText)
        let sourceLower = sourceText.lowercased()
        let sourceDigits = sourceLower.filter(\.isNumber)
        var issues: [LegalVerificationIssue] = []
        var seen = Set<String>()

        func flag(_ excerpt: String, _ message: String) {
            guard seen.insert(excerpt.lowercased()).inserted else { return }
            issues.append(LegalVerificationIssue(kind: .ungroundedEntity, message: message, excerpt: excerpt))
        }

        for candidate in personNameCandidates(in: answer) {
            let tokens = significantNameTokens(candidate)
            guard !tokens.isEmpty else { continue }
            if tokens.contains(where: { !sourceWords.contains($0) }) {
                flag(candidate, "This name does not appear verbatim in the cited documents — it may be inferred (e.g. reconstructed from an email prefix or initials). The record does not spell it out; confirm it before relying on it.")
            }
        }

        for email in regexMatches(in: answer, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
            if !sourceLower.contains(email.lowercased()) {
                flag(email, "This email address does not appear in the cited documents.")
            }
        }

        for phone in regexMatches(in: answer, pattern: #"\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#) {
            let digits = phone.filter(\.isNumber)
            if digits.count >= 10, !sourceDigits.contains(digits) {
                flag(phone, "This phone number does not appear in the cited documents.")
            }
        }

        return issues
    }

    /// Whole-word, lowercased alphanumeric token set (≥2 chars) — the haystack a name
    /// token must appear in to count as "present in the record".
    private static func wordTokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
    }

    private static func regexMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Candidate person names: runs of 2–3 capitalized words or initials
    /// ("Nancy Rust", "C. Todd Gallagher"), dropping any run that contains a
    /// structural/organizational word so headings and entity names aren't read as people.
    private static func personNameCandidates(in text: String) -> [String] {
        let pattern = #"\b(?:[A-Z][a-zA-Z]+|[A-Z]\.)(?:\s+(?:[A-Z][a-zA-Z]+|[A-Z]\.)){1,2}\b"#
        return regexMatches(in: text, pattern: pattern).filter { candidate in
            let tokens = candidate.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            return !tokens.contains { entityNonNameTokens.contains($0) }
        }
    }

    private static func significantNameTokens(_ candidate: String) -> [String] {
        candidate.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Words whose presence marks a capitalized run as NOT a personal name — section
    /// headings, roles, and organizational/structural terms.
    private static let entityNonNameTokens: Set<String> = [
        "plaintiff", "plaintiffs", "defendant", "defendants", "appellant", "appellee",
        "attorney", "attorneys", "counsel", "email", "note", "source", "sources", "packet",
        "question", "answer", "analysis", "verification", "review", "summary", "based",
        "certificate", "service", "court", "county", "circuit", "district", "division",
        "credit", "union", "bank", "llc", "inc", "llp", "corp", "corporation", "company",
        "holdings", "partners", "enterprises", "management", "construction", "properties",
        "investments", "group", "fund", "trust", "city", "state", "united", "states",
        "department", "commission", "respectfully", "sincerely", "dear", "exhibit", "docket",
        "parties", "involved", "matter", "legal", "provided", "information", "details",
        "contact", "representing", "thus", "verified"
    ]

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

    /// The numeric indices of source-packet labels (`[A1]`, `[A2]`, …) referenced in
    /// the text. The packet labels authorities by their order, so index `n` maps to
    /// the nth retrieved authority.
    public static func packetLabelIndices(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[A(\d+)\]"#) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            // A label too large to fit in an Int (e.g. [A99999999999999999999]) is
            // still a fabricated, out-of-range reference — map it to a sentinel so the
            // out-of-range guard flags it instead of silently dropping the match.
            return Int(text[range]) ?? Int.max
        }
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
        let citedStatutes = statutoryCitationKeys(in: citation)
        if !citedStatutes.isEmpty {
            return authorities.first { authority in
                let authorityStatutes = statutoryCitationKeys(for: authority)
                return citedStatutes.allSatisfy { cited in
                    authorityStatutes.contains { statutoryCitationMatches(cited, $0) }
                }
            }
        }

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

    private struct StatutoryCitationKey: Hashable {
        var code: String
        var title: String
        var section: String
    }

    private static func statutoryCitationKeys(for authority: LegalAuthority) -> [StatutoryCitationKey] {
        let values = authority.allCitationStrings + [
            authority.id,
            authority.caseName,
            authority.url,
            authority.jurisdiction
        ].compactMap { $0 }
        return Array(Set(values.flatMap(statutoryCitationKeys(in:)))).sorted {
            [$0.code, $0.title, $0.section].joined(separator: "|")
                < [$1.code, $1.title, $1.section].joined(separator: "|")
        }
    }

    private static func statutoryCitationKeys(in value: String) -> [StatutoryCitationKey] {
        var keys: [StatutoryCitationKey] = []
        keys += statutoryCitationKeys(
            in: value,
            pattern: #"(?i)\b(\d{1,4})\s+U\.?\s?S\.?\s?C\.?(?:A\.?)?\s*§+\s*([\w().-]+)"#,
            code: "usc"
        )
        keys += statutoryCitationKeys(
            in: value,
            pattern: #"(?i)\b(\d{1,4})\s+C\.?\s?F\.?\s?R\.?\s*§+\s*([\w().-]+)"#,
            code: "cfr"
        )
        keys += statutoryCitationKeys(
            in: value,
            pattern: #"(?i)\b(?:United States Code|U\.?\s?S\.?\s?Code),?\s+Title\s+(\d{1,4})\b[^§\n\r]*§+\s*([\w().-]+)"#,
            code: "usc"
        )
        keys += statutoryCitationKeys(
            in: value,
            pattern: #"(?i)\b(?:Code of Federal Regulations|C\.?\s?F\.?\s?R\.?),?\s+Title\s+(\d{1,4})\b[^§\n\r]*§+\s*([\w().-]+)"#,
            code: "cfr"
        )
        keys += providerLocatorStatutoryKeys(in: value)
        return Array(Set(keys))
    }

    private static func statutoryCitationKeys(in value: String, pattern: String, code: String) -> [StatutoryCitationKey] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let titleRange = Range(match.range(at: 1), in: value),
                  let sectionRange = Range(match.range(at: 2), in: value)
            else { return nil }
            return StatutoryCitationKey(
                code: code,
                title: String(value[titleRange]),
                section: canonicalStatutorySection(String(value[sectionRange]))
            )
        }
    }

    private static func providerLocatorStatutoryKeys(in value: String) -> [StatutoryCitationKey] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\bus-(usc|cfr)-title-(\d{1,4})\b[^A-Za-z0-9]+(?:chapter-[^/\s]+/)?section-([\w().-]+)"#
        ) else { return [] }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 4,
                  let codeRange = Range(match.range(at: 1), in: value),
                  let titleRange = Range(match.range(at: 2), in: value),
                  let sectionRange = Range(match.range(at: 3), in: value)
            else { return nil }
            return StatutoryCitationKey(
                code: String(value[codeRange]).lowercased(),
                title: String(value[titleRange]),
                section: canonicalStatutorySection(String(value[sectionRange]))
            )
        }
    }

    private static func canonicalStatutorySection(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:")))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func statutoryCitationMatches(_ lhs: StatutoryCitationKey, _ rhs: StatutoryCitationKey) -> Bool {
        lhs.code == rhs.code
            && lhs.title == rhs.title
            && lhs.section == rhs.section
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
    /// Whether the authority binds nationwide (the U.S. Supreme Court), making any
    /// forum-specific jurisdiction expectation moot for it.
    static func isNationallyBinding(_ authority: LegalAuthority) -> Bool {
        if authority.courtID?.lowercased() == "scotus" { return true }
        let court = normalized(authority.court ?? "")
        if court.contains("supreme court of the united states")
            || court == "united states supreme court"
            || court == "us supreme court" {
            return true
        }
        let jurisdiction = normalized(authority.jurisdiction ?? "")
        return jurisdiction.contains("united states supreme court")
            || jurisdiction.contains("supreme court of the united states")
    }

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

    // Content-grounding for a labeled proposition. A valid [A#] proves the model
    // pointed at a real packet authority, but not that the authority supports the
    // proposition. We only judge this when the cited authority carries substantial
    // (full-opinion) text — a bare snippet is too sparse to tell a genuine paraphrase
    // from a fabrication, so it is never over-flagged. A sufficiently specific
    // proposition that shares almost none of its significant terms with the opinion
    // text is the signature of a fabricated paraphrased holding under a valid label.
    private static let groundingMinAuthorityChars = 1200
    private static let groundingMinPropositionTerms = 5
    private static let groundingMinOverlap = 0.2

    private static func propositionGrounded(_ line: String, in authority: LegalAuthority) -> Bool {
        let haystack = [authority.text, authority.snippet, authority.caseName, authority.citation]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        guard haystack.count >= groundingMinAuthorityChars else { return true }
        let terms = significantContentTerms(line)
        guard terms.count >= groundingMinPropositionTerms else { return true }
        let matched = terms.filter { haystack.contains($0) }.count
        return Double(matched) / Double(terms.count) >= groundingMinOverlap
    }

    private static func significantContentTerms(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 5 && !contentStopwords.contains($0) }
        )
    }

    private static let contentStopwords: Set<String> = [
        "court", "courts", "held", "holding", "rule", "rules", "legal", "case", "cases",
        "there", "their", "these", "those", "which", "shall", "would", "could", "should",
        "because", "therefore", "however", "where", "when", "whether", "under", "within",
        "about", "above", "after", "before", "between", "during", "while", "being"
    ]
}
