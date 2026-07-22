import Foundation
import SupraCore

public enum LegalVerificationIssueKind: String, Codable, Hashable, Sendable {
    case unsupportedCitation = "unsupported_citation"
    case missingCitation = "missing_citation"
    case unsupportedQuote = "unsupported_quote"
    /// A quotation that could not be CHECKED because the packet carries no opinion
    /// text to search (e.g. a packet restored after an app restart, which is
    /// persisted without text). Soft: "unverified", never "fabricated".
    case unverifiableQuote = "unverifiable_quote"
    /// A material legal proposition whose cited source could not be evaluated
    /// because complete authority text was unavailable or ambiguous.
    case unverifiableProposition = "unverifiable_proposition"
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
    public var propositions: [CitedProposition]
    public var supportResults: [PropositionSupportResult]

    public init(
        passed: Bool,
        issues: [LegalVerificationIssue],
        retrievedAuthorityIDs: [String],
        citedStrings: [String],
        propositions: [CitedProposition] = [],
        supportResults: [PropositionSupportResult] = []
    ) {
        self.passed = passed
        self.issues = issues
        self.retrievedAuthorityIDs = retrievedAuthorityIDs
        self.citedStrings = citedStrings
        self.propositions = propositions
        self.supportResults = supportResults
    }
}

/// Why a cited authority still lacks verifiable text after local/network
/// hydration. Callers may pass this state into the verifier so its retained
/// reason distinguishes an absent opinion identifier from a failed fetch.
public enum LegalAuthorityTextFailure: String, Codable, Hashable, Sendable {
    case missingText = "missing_text"
    case insufficientText = "insufficient_text"
    case truncatedText = "truncated_text"
    case missingOpinionID = "missing_opinion_id"
    case fetchFailed = "fetch_failed"
    case emptyResponse = "empty_response"
    case cancelled
}

public enum LegalCitationVerifier {
    public static let propositionVerifierName = "SupraLegalPropositionVerifier"
    public static let propositionVerifierVersion = "1.0.0"

    public static func verify(
        answer: String,
        authorities: [LegalAuthority],
        expectedJurisdiction: String? = nil,
        namedAuthorityLookup: String? = nil,
        requiresSupportedAuthority: Bool = false,
        sourceFailuresByAuthorityID: [String: LegalAuthorityTextFailure] = [:]
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
        // A quote can only be REFUTED against FULL opinion text — a 280-char
        // snippet is a window into the opinion, not the opinion, and a packet
        // restored without text (persisted packets are audit-safe) has nothing
        // to search. Per quote: the [A#] labels on the quote's own line say
        // which authorities it claims to come from. A hard "fabricated" verdict
        // requires every claimed source to carry full text; otherwise the
        // honest verdict is "unverifiable".
        let fullTextLabels = Set((0..<packetSize).compactMap { index -> Int? in
            let text = authorities[index].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : index + 1
        })
        let packetFullyTexted = packetSize > 0 && fullTextLabels.count == packetSize
        let answerLines = answer.components(separatedBy: .newlines)
        for quote in extractQuotedText(from: answer) where quote.count >= 12 {
            if !authorityText.localizedCaseInsensitiveContains(quote) {
                let line = answerLines.first { $0.localizedCaseInsensitiveContains(quote) }
                let lineLabels = line.map { packetLabelIndices(in: $0).filter { $0 >= 1 && $0 <= packetSize } } ?? []
                let refutable = lineLabels.isEmpty
                    ? packetFullyTexted
                    : lineLabels.allSatisfy(fullTextLabels.contains)
                issues.append(
                    refutable
                        ? LegalVerificationIssue(
                            kind: .unsupportedQuote,
                            message: "Quoted text does not appear verbatim in the retrieved source packet.",
                            excerpt: quote
                        )
                        : LegalVerificationIssue(
                            kind: .unverifiableQuote,
                            message: "The cited authority's full opinion text is not in the packet, so this quotation is UNVERIFIED (not necessarily fabricated). Open the cited authority or re-run /research to restore its text, then /verify again.",
                            excerpt: quote
                        )
                )
            }
        }

        let propositions = resolvedPropositions(in: answer, authorities: authorities)
        let verifiedAt = Date()
        let supportResults = propositions.map { proposition in
            evaluate(
                proposition: proposition,
                authorities: authorities,
                sourceFailuresByAuthorityID: sourceFailuresByAuthorityID,
                timestamp: verifiedAt
            )
        }
        for (proposition, result) in zip(propositions, supportResults) where result.status != .supported {
            let kind: LegalVerificationIssueKind
            let message: String
            if proposition.citationLabels.isEmpty {
                kind = .missingCitation
                message = "Legal proposition does not contain a citation to a retrieved authority."
            } else if result.status == .unsupported {
                kind = .unsupportedCitation
                message = result.reasons.first ?? "The cited source does not support this proposition."
            } else {
                kind = .unverifiableProposition
                message = result.reasons.first ?? "The cited source could not be verified."
            }
            issues.append(
                LegalVerificationIssue(
                    kind: kind,
                    message: message,
                    excerpt: proposition.text
                )
            )
        }
        if requiresSupportedAuthority,
           !supportResults.contains(where: { $0.status == .supported }),
           !issues.contains(where: { $0.kind == .missingCitation }) {
            issues.append(
                LegalVerificationIssue(
                    kind: .missingCitation,
                    message: "This legal route requires at least one proposition supported by retained authority evidence.",
                    excerpt: nil
                )
            )
        }

        if let expectedJurisdiction,
           !expectedJurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !authorities.isEmpty {
            // Per-cited-authority jurisdiction check: flag each citation whose
            // backing authority sits in a different jurisdiction than requested,
            // rather than a single packet-wide any-of (which passed as long as
            // *some* unrelated authority matched).
            // A question that NAMES its authority is about that case wherever it sits,
            // so the matter's forum must not veto quoting it — nor the line of
            // authority it belongs to. That exemption is scoped to those authorities
            // here rather than by disabling the whole check at the call site.
            let exemptAuthorityIDs = jurisdictionExemptAuthorityIDs(
                namedAuthorityLookup: namedAuthorityLookup,
                among: authorities
            )
            var flaggedExcerpts = Set<String>()
            for citation in extracted {
                guard let authority = supportingAuthority(for: citation, among: authorities) else { continue }
                guard !exemptAuthorityIDs.contains(authority.id) else { continue }
                if let message = jurisdictionMismatchMessage(for: authority, expected: expectedJurisdiction),
                   flaggedExcerpts.insert(citation).inserted {
                    issues.append(
                        LegalVerificationIssue(
                            kind: .jurisdictionMismatch,
                            message: message,
                            excerpt: citation
                        )
                    )
                }
            }
            // Packet labels are the primary legal-output citation contract. A
            // label-only answer must receive the same per-authority jurisdiction
            // check as a conventional reporter citation.
            for proposition in propositions {
                for label in proposition.citationLabels {
                    for index in packetLabelIndices(in: label) where index >= 1 && index <= packetSize {
                        let authority = authorities[index - 1]
                        guard !exemptAuthorityIDs.contains(authority.id) else { continue }
                        if let message = jurisdictionMismatchMessage(for: authority, expected: expectedJurisdiction),
                           flaggedExcerpts.insert(label).inserted {
                            issues.append(LegalVerificationIssue(
                                kind: .jurisdictionMismatch,
                                message: message,
                                excerpt: label
                            ))
                        }
                    }
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
            passed: issues.isEmpty && supportResults.allSatisfy { $0.status == .supported },
            issues: issues,
            retrievedAuthorityIDs: authorities.map(\.id),
            citedStrings: extracted + labelStrings,
            propositions: propositions,
            supportResults: supportResults
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
        verifyGroundedEntities(answer: answer, sourceTexts: [sourceText])
    }

    /// Per-source overload: a name must ground within a SINGLE packed source. Tokens
    /// drawn from two different documents are not a name the record states.
    ///
    /// Email and phone grounding stays pooled across sources — those are exact-value
    /// matches with no cross-source assembly to exploit, and narrowing them would only
    /// add false flags.
    public static func verifyGroundedEntities(answer: String, sourceTexts: [String]) -> [LegalVerificationIssue] {
        // PDF text extraction splits words at line-break hyphens and soft hyphens
        // ("Ritche-\nson"); the model reads through the split, so each source
        // contributes its rejoined text as a separate sequence too, or a name plainly
        // on the page gets flagged as inferred.
        let rejoinedSources = sourceTexts.map(dehyphenatedText)
        let nameSequences = (sourceTexts + rejoinedSources).map(tokenSequence)
        let sourceLower = (sourceTexts + rejoinedSources).joined(separator: "\n").lowercased()
        let sourceDigits = sourceTexts.joined(separator: "\n").lowercased().filter(\.isNumber)
        var issues: [LegalVerificationIssue] = []
        var seen = Set<String>()

        func flag(_ excerpt: String, _ message: String) {
            guard seen.insert(excerpt.lowercased()).inserted else { return }
            issues.append(LegalVerificationIssue(kind: .ungroundedEntity, message: message, excerpt: excerpt))
        }

        for candidate in personNameCandidates(in: answer) {
            let tokens = significantNameTokens(candidate)
            guard !tokens.isEmpty else { continue }
            if !tokensCooccur(tokens, inAnyOf: nameSequences) {
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

    /// Rejoins words that PDF extraction split at a line-break hyphen, and strips
    /// invisible soft hyphens.
    private static func dehyphenatedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(
                of: #"([A-Za-z])-[ \t]*\n[ \t]*([A-Za-z])"#,
                with: "$1$2",
                options: .regularExpression
            )
    }

    /// Whole-word, lowercased alphanumeric token set (≥2 chars) — the haystack a name
    /// token must appear in to count as "present in the record".
    /// The source's significant word tokens in reading order, using the same rule as
    /// `significantNameTokens` so the two sides are comparable.
    private static func tokenSequence(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Whether all of a name's tokens occur close together, in either order, within one
    /// source sequence.
    ///
    /// Replaces a flat set-membership test that let "Nancy" in a caption and "Rust"
    /// forty pages later ground "Nancy Rust". The window is deliberately not strict
    /// adjacency: captions and signature blocks invert the name ("Rust, Nancy") and
    /// carry middle initials ("Nancy P. Rust"), both of which are genuine groundings,
    /// so the rule is bounded co-occurrence rather than order.
    private static func tokensCooccur(_ tokens: [String], inAnyOf sequences: [[String]]) -> Bool {
        let needed = Set(tokens)
        guard !needed.isEmpty else { return false }
        // Room for the tokens themselves plus a couple of intervening words (a middle
        // initial is dropped by the >= 2 character filter, but suffixes and connectors
        // such as "Jr" or "and" are not).
        let span = needed.count + 3
        for sequence in sequences where sequence.count >= needed.count {
            for start in 0...(sequence.count - needed.count) {
                let end = min(start + span, sequence.count)
                if needed.isSubset(of: Set(sequence[start..<end])) { return true }
            }
        }
        return false
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

    /// Material legal propositions split on sentence boundaries. Ranges are
    /// character offsets in the original output and remain stable for identical
    /// output bytes. Only labels attached to the same sentence are retained.
    public static func extractCitedPropositions(from answer: String) -> [CitedProposition] {
        var propositions: [CitedProposition] = []
        for range in sentenceRanges(in: answer) {
            let substring = String(answer[range])
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeLegalProposition(trimmed) else { continue }

            let leading = substring.prefix { $0.isWhitespace }.count
            let trailing = substring.reversed().prefix { $0.isWhitespace }.count
            let rawLower = answer.distance(from: answer.startIndex, to: range.lowerBound)
            let rawUpper = answer.distance(from: answer.startIndex, to: range.upperBound)
            let lower = rawLower + leading
            let upper = max(lower, rawUpper - trailing)
            let ordinal = propositions.count + 1
            propositions.append(
                CitedProposition(
                    id: "legal-proposition-\(ordinal)-\(lower)",
                    text: trimmed,
                    citationLabels: orderedUniqueLabels(in: trimmed),
                    outputRange: lower..<upper
                )
            )
        }
        return propositions
    }

    /// Zero-based packet indices referenced by in-range labels, reporter/case
    /// citations, or an exact authority URL in the supplied answer.
    public static func citedAuthorityIndices(
        in answer: String,
        authorities: [LegalAuthority]
    ) -> [Int] {
        let packetSize = min(authorities.count, LegalResearchPromptBuilder.maxPacketAuthorities)
        var indices = Set(
            packetLabelIndices(in: answer)
                .filter { $0 >= 1 && $0 <= packetSize }
                .map { $0 - 1 }
        )
        for citation in extractCitationLikeStrings(from: answer) {
            if let authority = supportingAuthority(for: citation, among: Array(authorities.prefix(packetSize))),
               let index = authorities[..<packetSize].firstIndex(where: { $0.id == authority.id }) {
                indices.insert(index)
            }
        }
        for index in 0..<packetSize {
            if let url = authorities[index].url,
               !url.isEmpty,
               answer.localizedCaseInsensitiveContains(url) {
                indices.insert(index)
            }
        }
        return indices.sorted()
    }

    /// Complete-enough source text for a proposition decision. Case search
    /// snippets and explicit context truncation are not full authority text.
    public static func hasVerifiableSourceText(_ authority: LegalAuthority) -> Bool {
        inferredTextFailure(for: authority) == nil
    }

    public static func inferredTextFailure(
        for authority: LegalAuthority
    ) -> LegalAuthorityTextFailure? {
        guard let rawText = authority.text else { return .missingText }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .missingText }
        if authority.textKind == .searchSnippet { return .insufficientText }
        let lower = text.lowercased()
        if lower.contains("[text truncated to fit the context window]")
            || lower.contains("[truncated]")
            || lower.contains("… [truncated") {
            return .truncatedText
        }

        let minimumCharacters: Int
        switch authority.authorityType {
        case .case, .docket:
            minimumCharacters = 80
        case .statute:
            minimumCharacters = 40
        case .unknown:
            minimumCharacters = 100
        }
        guard text.count >= minimumCharacters else { return .insufficientText }

        return nil
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
        keys += stateStatutoryKeys(in: value)
        return Array(Set(keys))
    }

    /// State-code cites: the answer's Bluebook form ("Fla. Stat. § 768.28",
    /// "Cal. Civ. Code § 1942") and the packet's provider label ("Florida
    /// Statutes § 768.28", "California Civil Code § 1942") must normalize to the
    /// SAME key, or every correctly-cited state statute reads as unsupported.
    private static func stateStatutoryKeys(in value: String) -> [StatutoryCitationKey] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b([A-Z][A-Za-z.]*(?:\s+[A-Z][A-Za-z.]*)?)\s+((?:[A-Za-z&.']{1,14}\s+){0,3}?)(Stats?\.?|Statutes|Codes?|Laws?)(?:\s+Ann\.?)?\s*§+\s*([\w().-]+)"#
        ) else { return [] }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 5,
                  let stateRange = Range(match.range(at: 1), in: value),
                  let middleRange = Range(match.range(at: 2), in: value),
                  let nounRange = Range(match.range(at: 3), in: value),
                  let sectionRange = Range(match.range(at: 4), in: value)
            else { return nil }
            let stateWords = String(value[stateRange]).split(separator: " ").map(String.init)
            let middleWords = String(value[middleRange]).split(separator: " ").map(String.init)

            // The greedy state group may swallow a code word ("Cal. Civ." before
            // "Code") — resolve the full reference first, then the first word
            // alone, treating the leftovers as part of the code name.
            var postal: String?
            var extraMiddle: [String] = []
            if let full = StatutoryJurisdictionMapper.postalCode(forStateReference: stateWords.joined(separator: " ")) {
                postal = full
            } else if let firstWord = stateWords.first,
                      let first = StatutoryJurisdictionMapper.postalCode(forStateReference: firstWord) {
                postal = first
                extraMiddle = Array(stateWords.dropFirst())
            }
            // Not recognizably a state cite — leave it to the other match paths.
            guard let postal else { return nil }

            // Code-name words match on 3-letter stems so "Civ." meets "Civil"
            // and "Gen. Stat." meets "General Statutes".
            var stems: [String] = []
            for word in extraMiddle + middleWords {
                let letters: String = word.lowercased().filter { $0.isLetter }
                guard letters.count >= 3, letters != "and", letters != "the", letters != "ann" else { continue }
                stems.append(String(letters.prefix(3)))
            }
            let noun = String(value[nounRange]).lowercased()
            let family = noun.hasPrefix("stat") ? "stat" : (noun.hasPrefix("code") ? "code" : "law")
            return StatutoryCitationKey(
                code: "state-\(postal.lowercased())",
                title: (stems + [family]).joined(),
                section: canonicalStatutorySection(String(value[sectionRange]))
            )
        }
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

    /// The authorities exempt from the jurisdiction check because the question named
    /// one of them: the named authority's exact ID plus packet records the same
    /// lookup strictly resolves to (aliases — e.g. the same opinion appearing twice
    /// under different provider IDs). Nothing else: an authority that merely shares
    /// the named case's court or a forum derived from it is out-of-forum authority
    /// like any other (Phase 3C, review finding #2 — the forum-neighborhood
    /// expansion silently exempted, via the symmetric federal-family relation, even
    /// a state supreme court "sharing" a federal circuit's footprint).
    ///
    /// The exemption used to be expressed by the caller passing no expected
    /// jurisdiction at all, which switched a HARD gate off for every authority in the
    /// answer. Since a named-case lookup can be *synthesized* from prior turns by the
    /// anaphora heuristic, a misfire silently disabled jurisdiction verification
    /// wholesale (I-FIXME-1). Anchoring the exemption to authorities the lookup
    /// actually resolves to bounds the damage in both regimes: a lookup that resolves
    /// to nothing exempts nothing, and a lookup that resolves exempts only that case.
    private static func jurisdictionExemptAuthorityIDs(
        namedAuthorityLookup: String?,
        among authorities: [LegalAuthority]
    ) -> Set<String> {
        guard
            let lookup = namedAuthorityLookup?.trimmingCharacters(in: .whitespacesAndNewlines),
            !lookup.isEmpty,
            supportingAuthority(for: lookup, among: authorities) != nil
        else {
            return []
        }
        // Every packet record the lookup independently, strictly resolves to is the
        // same case under an alias; membership uses the same strict matcher as
        // citation support, never containment or forum derivation.
        return Set(
            authorities
                .filter { supportingAuthority(for: lookup, among: [$0]) != nil }
                .map(\.id)
        )
    }

    /// The jurisdiction-mismatch message for a cited authority, or `nil` when the
    /// authority's relationship to the requested forum is acceptable.
    ///
    /// Decided from the directional `AuthorityRelationship` (Phase 3C) — this hard
    /// gate consumes the typed relation and states its accepted set explicitly,
    /// rather than a generic "within scope" boolean:
    ///
    /// - Accepted: the same court, controlling superior authority, the same federal
    ///   family, the same state, and a FEDERAL authority sitting in an expected STATE
    ///   forum (it applies that state's law — flagging every such cite would bury
    ///   real mismatches in noise).
    /// - Flagged: a state authority inside an expected federal forum's footprint (a
    ///   state court is not part of the federal hierarchy), subject-matter-dependent
    ///   authority (the Federal Circuit) because this pipeline establishes no subject
    ///   matter — fail closed — and anything outside scope.
    /// - `.indeterminate` falls back to *exact* normalized equality — never
    ///   containment — so an unrecognized court is flagged rather than waved through.
    ///
    /// The ranker chooses its own accepted set in `LegalAuthorityRanker`; the two
    /// consumers deliberately do not share a generic definition.
    private static func jurisdictionMismatchMessage(
        for authority: LegalAuthority,
        expected: String
    ) -> String? {
        switch JurisdictionScopeResolver.shared.relationship(
            expected: expected,
            authorityCourt: authority.court,
            authorityJurisdiction: authority.jurisdiction,
            authorityCourtID: authority.courtID
        ) {
        case .sameCourt, .controllingSuperior, .sameFederalFamily, .sameStateNoncontrolling:
            return nil
        case .geographicallyRelated(.federalAuthorityInExpectedState):
            return nil
        case .geographicallyRelated(.stateAuthorityInExpectedFederalFootprint):
            return "The cited authority is a state-court decision; it is not part of the requested federal jurisdiction's hierarchy (\(expected))."
        case .subjectMatterDependent:
            return "The cited authority's jurisdiction is subject-matter limited (e.g., the Federal Circuit), and no qualifying subject matter is established for the requested jurisdiction (\(expected))."
        case .outsideScope:
            return "The cited authority does not clearly belong to the requested jurisdiction (\(expected))."
        case .indeterminate:
            let expectedKey = normalized(expected)
            let fields = [authority.jurisdiction, authority.court, authority.courtID].compactMap { $0 }
            return fields.contains { normalized($0) == expectedKey }
                ? nil
                : "The cited authority does not clearly belong to the requested jurisdiction (\(expected))."
        }
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
        // A sentence that affirmatively invokes an authority is itself a
        // material legal proposition even when it uses a verb outside the
        // marker vocabulary (for example, "the dissent would enforce ...").
        // Treating those sentences as prose would let a well-formed [A#] label
        // evade proposition-level support verification.
        if !packetLabelIndices(in: trimmed).isEmpty
            || !extractCitationLikeStrings(from: trimmed).isEmpty {
            return true
        }
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

    private static func resolvedPropositions(
        in answer: String,
        authorities: [LegalAuthority]
    ) -> [CitedProposition] {
        extractCitedPropositions(from: answer).map { proposition in
            guard proposition.citationLabels.isEmpty else { return proposition }
            let indices = citedAuthorityIndices(in: proposition.text, authorities: authorities)
            guard !indices.isEmpty else { return proposition }
            return CitedProposition(
                id: proposition.id,
                text: proposition.text,
                citationLabels: indices.map { "[A\($0 + 1)]" },
                outputRange: proposition.outputRange
            )
        }
    }

    private static func orderedUniqueLabels(in text: String) -> [String] {
        var seen = Set<Int>()
        return packetLabelIndices(in: text).compactMap { index in
            guard seen.insert(index).inserted else { return nil }
            return index == Int.max ? "[A…]" : "[A\(index)]"
        }
    }

    private static func evaluate(
        proposition: CitedProposition,
        authorities: [LegalAuthority],
        sourceFailuresByAuthorityID: [String: LegalAuthorityTextFailure],
        timestamp: Date
    ) -> PropositionSupportResult {
        let packetSize = min(authorities.count, LegalResearchPromptBuilder.maxPacketAuthorities)
        let rawIndices = proposition.citationLabels.compactMap { label -> Int? in
            packetLabelIndices(in: label).first
        }
        if rawIndices.contains(where: { $0 < 1 || $0 > packetSize }) {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unsupported,
                reasons: ["A cited source label does not exist in the source packet."],
                evidence: [],
                timestamp: timestamp
            )
        }
        let indices = Array(Set(rawIndices.map { $0 - 1 })).sorted()
        guard !indices.isEmpty else {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unverifiable,
                reasons: ["The proposition has no resolvable cited authority."],
                evidence: [],
                timestamp: timestamp
            )
        }

        let propositionTerms = significantContentTerms(proposition.text)
        guard propositionTerms.count >= 2 else {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unverifiable,
                reasons: ["The proposition is too ambiguous for deterministic support verification."],
                evidence: [],
                timestamp: timestamp
            )
        }

        var evidence: [SupportEvidence] = []
        var unsupportedReasons: [String] = []
        var unverifiableReasons: [String] = []
        for index in indices {
            let authority = authorities[index]
            let label = "[A\(index + 1)]"
            if let failure = sourceFailuresByAuthorityID[authority.id]
                ?? inferredTextFailure(for: authority) {
                unverifiableReasons.append("\(label) lacks verifiable authority text (\(failure.rawValue)).")
                continue
            }
            let text = authority.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !InstructionShapeDetector.isBlocking(text) else {
                unverifiableReasons.append("\(label) contains instruction-shaped text and cannot be treated as authority evidence.")
                continue
            }
            guard !hasMaterialContradiction(to: proposition.text, in: text) else {
                unsupportedReasons.append("\(label) contains materially contradictory treatment of the proposition.")
                continue
            }
            let match = bestEvidenceMatch(for: proposition.text, terms: propositionTerms, in: text)
            let requiredMatches = min(3, propositionTerms.count)
            guard match.matchedTerms >= requiredMatches, match.coverage >= 0.45 else {
                unsupportedReasons.append("\(label) does not contain enough proposition-specific support.")
                continue
            }
            guard negationPolarity(in: proposition.text) == negationPolarity(in: match.excerpt) else {
                unsupportedReasons.append("\(label) contradicts the proposition's affirmative/negative meaning.")
                continue
            }
            guard !isQualifiedOrNonholdingSupport(match.excerpt, for: proposition.text) else {
                unsupportedReasons.append("\(label) supplies dicta, dissent, or expressly unresolved treatment rather than the claimed holding.")
                continue
            }
            guard isOrderedSubsequence(
                orderedCriticalValues(in: proposition.text),
                of: orderedCriticalValues(in: match.excerpt)
            ) else {
                unsupportedReasons.append("\(label) reassigns or omits a proposition-critical value.")
                continue
            }
            evidence.append(
                SupportEvidence(
                    sourceID: authority.id,
                    sourceLabel: label,
                    locator: evidenceLocator(for: authority),
                    retainedExcerpt: String(match.excerpt.prefix(1_000)),
                    verifierName: propositionVerifierName,
                    verifierVersion: propositionVerifierVersion
                )
            )
        }

        if !unsupportedReasons.isEmpty {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unsupported,
                reasons: unsupportedReasons,
                evidence: evidence,
                timestamp: timestamp
            )
        }
        if !unverifiableReasons.isEmpty {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unverifiable,
                reasons: unverifiableReasons,
                evidence: evidence,
                timestamp: timestamp
            )
        }
        guard !evidence.isEmpty else {
            return makeSupportResult(
                propositionID: proposition.id,
                status: .unverifiable,
                reasons: ["No complete supporting evidence could be retained."],
                evidence: [],
                timestamp: timestamp
            )
        }
        return makeSupportResult(
            propositionID: proposition.id,
            status: .supported,
            reasons: ["Every cited authority supports the proposition."],
            evidence: evidence,
            timestamp: timestamp
        )
    }

    private struct EvidenceMatch {
        var excerpt: String
        var matchedTerms: Int
        var coverage: Double
    }

    private static func bestEvidenceMatch(
        for proposition: String,
        terms: Set<String>,
        in sourceText: String
    ) -> EvidenceMatch {
        var candidates: [String] = []
        for range in sentenceRanges(in: sourceText) {
            let trimmed = sourceText[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { candidates.append(String(trimmed)) }
        }
        if candidates.isEmpty { candidates = [sourceText] }
        return candidates.map { excerpt in
            let sourceTerms = significantContentTerms(excerpt)
            let matched = terms.intersection(sourceTerms).count
            return EvidenceMatch(
                excerpt: excerpt,
                matchedTerms: matched,
                coverage: terms.isEmpty ? 0 : Double(matched) / Double(terms.count)
            )
        }.max { lhs, rhs in
            if lhs.coverage == rhs.coverage { return lhs.matchedTerms < rhs.matchedTerms }
            return lhs.coverage < rhs.coverage
        } ?? EvidenceMatch(excerpt: sourceText, matchedTerms: 0, coverage: 0)
    }

    private static func negationPolarity(in text: String) -> Bool {
        let pattern = #"(?i)\b(?:does|do|did|is|are|was|were|must|shall|can|could|would|should)\s+not\b|\bcannot\b|\bno\s+(?!later\b)|\bneither\b|\bnor\b|\bnever\b|\bwithout\b|\bdeclin(?:e|es|ed|ing)\s+to\b|\breject(?:s|ed|ing)?\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }


    private static func hasMaterialContradiction(to proposition: String, in sourceText: String) -> Bool {
        let terms = significantContentTerms(proposition)
        guard terms.count >= 2 else { return false }
        let propositionNegated = negationPolarity(in: proposition)
        return sentenceRanges(in: sourceText).contains { range in
            let sentence = String(sourceText[range])
            guard negationPolarity(in: sentence) != propositionNegated else { return false }
            let matched = terms.intersection(significantContentTerms(sentence)).count
            return matched >= min(3, terms.count)
                && Double(matched) / Double(terms.count) >= 0.45
        }
    }

    /// Internal rather than private so the holding-vs-dicta rule can be tested directly. Reaching
    /// it through `verify(...)` requires an excerpt that first clears citation resolution, term
    /// overlap, negation polarity and contradiction — so an end-to-end test of this rule passes or
    /// fails for reasons that have nothing to do with it.
    static func isQualifiedOrNonholdingSupport(_ excerpt: String, for proposition: String) -> Bool {
        guard matches(proposition, holdingClaimPattern) else { return false }
        return nonholdingMarkerPatterns.contains { matches(excerpt, $0) }
    }

    /// A proposition that asserts a holding or an obligation. Word-bounded: the substring form
    /// treated "threshold" as a holding claim, and "stakeholder" and "withholding" alike.
    private static let holdingClaimPattern =
        #"\b(hold|holds|held|holding|require|requires|required|requirement|must)\b"#

    /// Phrases that mark treatment as something other than the holding.
    ///
    /// Word-bounded, so "dictates" is no longer dicta and "mighty" is no longer a hedge. Two
    /// needles from the substring list are deliberately GONE rather than bounded:
    ///
    /// - `whether` — appellate courts phrase the question presented that way constantly, so it
    ///   appears inside express holdings ("We hold that whether X is a question of fact").
    /// - `might` — ordinary hedging that survives into a holding ("however slight the prejudice
    ///   might be").
    ///
    /// Both marked genuine holdings as dicta far more often than they caught real dicta. The
    /// narrower phrases that follow capture what those two were reaching for — a court expressly
    /// declining to resolve the question — without sweeping in every hedge.
    private static let nonholdingMarkerPatterns = [
        #"\bdicta\b"#,
        #"\bdictum\b"#,
        #"\bdissent(s|ed|ing)?\b"#,
        #"\bdeclines? to decide\b"#,
        #"\bdo(es)? not decide\b"#,
        #"\bneed not (decide|reach)\b"#,
        #"\bwithout deciding\b"#,
        #"\barguendo\b"#,
    ]

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func orderedCriticalValues(in text: String) -> [String] {
        // Reporter volumes/pages and statutory section numbers identify the
        // authority; they are not facts asserted by the proposition. Remove
        // recognized citation forms before enforcing value ordering so a cite
        // such as `321 Cal. App. 5th 654` does not require those numbers to
        // appear in the opinion excerpt. Currency, percentages, dates, and
        // other proposition values remain in the text and stay fail-closed.
        var valueBearingText = text
        let authorityCitations = citationMatches(
            in: text,
            patterns: reporterCitationPatterns
                + federalStatutoryCitationPatterns
                + otherAuthorityCitationPatterns
                + [statutoryCitationPattern]
        )
        for citation in authorityCitations.sorted(by: { $0.count > $1.count }) {
            valueBearingText = valueBearingText.replacingOccurrences(
                of: citation,
                with: " ",
                options: [.caseInsensitive]
            )
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(?:[$€£]\s*\d[\d,.]*|\b\d[\d,.]*(?:%|percent)?\b|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b)"#
        ) else { return [] }
        let range = NSRange(valueBearingText.startIndex..<valueBearingText.endIndex, in: valueBearingText)
        return regex.matches(in: valueBearingText, range: range).compactMap { match in
            Range(match.range, in: valueBearingText).map {
                valueBearingText[$0].lowercased().replacingOccurrences(of: " ", with: "")
            }
        }
    }

    private static func isOrderedSubsequence(_ required: [String], of available: [String]) -> Bool {
        guard !required.isEmpty else { return true }
        var nextIndex = 0
        for value in required {
            guard nextIndex < available.count,
                  let match = available[nextIndex...].firstIndex(of: value)
            else { return false }
            nextIndex = match + 1
        }
        return true
    }

    /// Legal-aware deterministic sentence ranges. Foundation's generic sentence
    /// tokenizer splits `Foo v. Bar` after `v.`, detaching `[A1]` from the very
    /// proposition it cites. This scanner treats common reporter/caption
    /// abbreviations and single-letter reporter components as non-boundaries.
    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex

        func appendRange(endingAt end: String.Index) {
            if start < end { ranges.append(start..<end) }
        }

        while index < text.endIndex {
            let character = text[index]
            let after = text.index(after: index)
            if character == "\n" {
                appendRange(endingAt: index)
                start = after
                index = after
                continue
            }
            guard character == "." || character == "?" || character == "!" else {
                index = after
                continue
            }

            var next = after
            while next < text.endIndex, text[next].isWhitespace, text[next] != "\n" {
                next = text.index(after: next)
            }
            let isEnd = next == text.endIndex
            let nextStartsSentence = isEnd || text[next].isUppercase || text[next] == "#" || text[next] == "-"
            let abbreviation = character == "." && isLegalAbbreviation(before: index, in: text)
            if nextStartsSentence && !abbreviation {
                appendRange(endingAt: after)
                start = next
                index = next
            } else {
                index = after
            }
        }
        appendRange(endingAt: text.endIndex)
        return ranges
    }

    private static func isLegalAbbreviation(
        before period: String.Index,
        in text: String
    ) -> Bool {
        var lower = period
        while lower > text.startIndex {
            let prior = text.index(before: lower)
            guard text[prior].isLetter else { break }
            lower = prior
        }
        let token = text[lower..<period].lowercased()
        if token.count == 1 { return true }
        return legalSentenceAbbreviations.contains(token)
    }

    private static let legalSentenceAbbreviations: Set<String> = [
        "v", "vs", "inc", "corp", "co", "llc", "ltd", "no", "nos", "cir", "ct",
        "app", "supp", "cal", "stat", "rev", "civ", "crim", "evid", "fed", "reg",
        "prof", "dept", "assn", "bros", "ex", "rel", "et", "al"
    ]

    private static func evidenceLocator(for authority: LegalAuthority) -> String {
        [authority.citation, authority.url, authority.caseName, authority.id]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? authority.id
    }

    private static func makeSupportResult(
        propositionID: String,
        status: PropositionSupportStatus,
        reasons: [String],
        evidence: [SupportEvidence],
        timestamp: Date
    ) -> PropositionSupportResult {
        do {
            return try PropositionSupportResult(
                propositionID: propositionID,
                status: status,
                reasons: reasons,
                evidence: evidence,
                timestamp: timestamp
            )
        } catch {
            // A construction failure can only make the result less trusted.
            // The fallback shape is valid by the SupraCore contract.
            return try! PropositionSupportResult(
                propositionID: propositionID,
                status: .unverifiable,
                reasons: ["Verifier could not retain complete support evidence."],
                evidence: [],
                timestamp: timestamp
            )
        }
    }

    private static func significantContentTerms(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 5 && !contentStopwords.contains($0) }
                .map(canonicalContentTerm)
                .filter { $0.count >= 4 && !contentStopwords.contains($0) }
        )
    }

    /// Small deterministic morphology normalizer for the lexical verifier.
    /// This intentionally handles only common English suffixes; it is enough to
    /// keep faithful variants such as "describe/describes" and
    /// "reject/rejected" from becoming false negatives without introducing an
    /// opaque language-model judgment into the fail-closed gate.
    private static func canonicalContentTerm(_ token: String) -> String {
        if token.count > 7, token.hasSuffix("ing") {
            return String(token.dropLast(3))
        }
        if token.count > 6, token.hasSuffix("ed") {
            return String(token.dropLast(2))
        }
        if token.count > 6, token.hasSuffix("es"), !token.hasSuffix("sses") {
            return String(token.dropLast(1))
        }
        if token.count > 5, token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private static let contentStopwords: Set<String> = [
        "court", "courts", "held", "holding", "rule", "rules", "legal", "case", "cases",
        "there", "their", "these", "those", "which", "shall", "would", "could", "should",
        "because", "therefore", "however", "where", "when", "whether", "under", "within",
        "about", "above", "after", "before", "between", "during", "while", "being",
        "citing", "according", "source", "authority"
    ]
}
