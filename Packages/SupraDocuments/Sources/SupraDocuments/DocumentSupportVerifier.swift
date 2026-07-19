import Foundation
import SupraCore

/// The exact document passage offered to generation and proposition verification.
/// `sourceID` is stable within the owning matter (normally `matter/chunk`).
public struct DocumentSupportSource: Sendable, Equatable {
    public let sourceID: String
    public let label: String
    public let locator: String
    public let text: String
    public let lowConfidence: Bool

    public init(
        sourceID: String,
        label: String,
        locator: String,
        text: String,
        lowConfidence: Bool = false
    ) {
        self.sourceID = sourceID
        self.label = label
        self.locator = locator
        self.text = text
        self.lowConfidence = lowConfidence
    }
}

/// Proposition-level document verification plus the structural citation details
/// needed by existing UI warning surfaces.
public struct DocumentSupportReport: Sendable, Equatable {
    public let propositions: [CitedProposition]
    public let results: [PropositionSupportResult]
    public let usedLabels: [String]
    public let unresolvedLabels: [String]
    public let appearsUnsupported: Bool
    public let warnings: [String]

    public var verificationStatus: OutputVerificationStatus {
        !results.isEmpty && results.allSatisfy { $0.status == .supported }
            ? .allSupported
            : .needsReview
    }

    public var requiresReview: Bool { verificationStatus != .allSupported }

    /// Persisted with review-required output so clipboard, print, and export
    /// surfaces cannot shed the verification state carried by the UI badge.
    public var warningMarkdown: String {
        guard requiresReview else { return "" }
        let detail = warnings.isEmpty
            ? "Proposition support could not be established from the cited document text."
            : warnings.joined(separator: " ")
        return "> ⚠️ **DOCUMENT SUPPORT NEEDS REVIEW — DO NOT RELY.** \(detail)\n\n"
    }
}

/// A deliberately conservative, deterministic support verifier. It establishes
/// support only for high-overlap extractive paraphrases with matching critical
/// values. It does not ask a model to judge another model's answer.
public enum DocumentSupportVerifier {
    public static let version = "document-support-v1"
    private static let verifierName = "DocumentSupportVerifier"

    public static func verify(
        answer: String,
        sources: [DocumentSupportSource],
        scopeFullyIndexed: Bool,
        timestamp: Date = Date()
    ) throws -> DocumentSupportReport {
        try Task.checkCancellation()
        let propositions = extractPropositions(from: answer)
        let usedLabels = CitationCoverage.usedLabels(in: answer)
        let sourceByLabel = Dictionary(sources.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let unresolvedLabels = usedLabels.filter { sourceByLabel[$0] == nil }
        let appearsUnsupported = appearsToBeRefusal(answer)

        var results: [PropositionSupportResult] = []
        var warnings: [String] = []

        if propositions.isEmpty {
            let reason = appearsUnsupported
                ? "A refusal cannot prove absence across the retrieved packet."
                : "No material proposition could be extracted for verification."
            results.append(try PropositionSupportResult(
                propositionID: "document-proposition-0",
                status: .unverifiable,
                reasons: [reason],
                evidence: [],
                timestamp: timestamp
            ))
            warnings.append(reason)
        } else {
            for proposition in propositions {
                try Task.checkCancellation()
                let decision = try evaluate(
                    proposition,
                    sourceByLabel: sourceByLabel,
                    scopeFullyIndexed: scopeFullyIndexed,
                    timestamp: timestamp
                )
                results.append(decision)
                if decision.status != .supported {
                    warnings.append(contentsOf: decision.reasons)
                }
            }
        }

        if !unresolvedLabels.isEmpty {
            warnings.append("Answer cites sources that do not resolve: \(unresolvedLabels.joined(separator: ", ")).")
        }
        if !appearsUnsupported && usedLabels.isEmpty {
            warnings.append("Answer has no inline citations.")
        }
        if !scopeFullyIndexed {
            warnings.append("Generated from an incompletely indexed scope.")
        }

        return DocumentSupportReport(
            propositions: propositions,
            results: results,
            usedLabels: usedLabels,
            unresolvedLabels: unresolvedLabels,
            appearsUnsupported: appearsUnsupported,
            warnings: orderedUnique(warnings)
        )
    }

    private static func evaluate(
        _ proposition: CitedProposition,
        sourceByLabel: [String: DocumentSupportSource],
        scopeFullyIndexed: Bool,
        timestamp: Date
    ) throws -> PropositionSupportResult {
        func result(
            _ status: PropositionSupportStatus,
            _ reasons: [String],
            evidence: [SupportEvidence] = []
        ) throws -> PropositionSupportResult {
            try PropositionSupportResult(
                propositionID: proposition.id,
                status: status,
                reasons: reasons,
                evidence: evidence,
                timestamp: timestamp
            )
        }

        guard scopeFullyIndexed else {
            return try result(.unverifiable, ["Proposition \(proposition.id) came from an incompletely indexed scope."])
        }
        guard !proposition.citationLabels.isEmpty else {
            return try result(.unverifiable, ["Proposition \(quotedSnippet(proposition.text)) has no citation in the same proposition."])
        }

        var citedSources: [DocumentSupportSource] = []
        for label in proposition.citationLabels {
            try Task.checkCancellation()
            guard let source = sourceByLabel[label] else {
                return try result(.unverifiable, ["Proposition \(quotedSnippet(proposition.text)) cites unresolved source \(label)."])
            }
            guard !source.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return try result(.unverifiable, ["Source \(label) lacks stable text, identity, or locator evidence."])
            }
            guard !source.lowConfidence else {
                return try result(.unverifiable, ["Source \(label) has low-confidence OCR text."])
            }
            guard !source.text.contains("…[source text truncated to fit the context window]") else {
                return try result(.unverifiable, ["Source \(label) was truncated in the generation packet."])
            }
            guard !containsInstructionLikeContent(source.text) else {
                return try result(.unverifiable, ["Source \(label) contains instruction-like content and is treated as untrusted data."])
            }
            citedSources.append(source)
        }

        for source in citedSources {
            try Task.checkCancellation()
            guard try !hasMaterialContradiction(to: proposition.text, in: source.text) else {
                return try result(.unsupported, ["Cited source text contains materially contradictory evidence for \(quotedSnippet(proposition.text))."])
            }
            guard let excerpt = try supportingExcerpt(for: proposition.text, in: source.text) else { continue }
            let evidence = SupportEvidence(
                sourceID: source.sourceID,
                sourceLabel: source.label,
                locator: source.locator,
                retainedExcerpt: excerpt,
                verifierName: verifierName,
                verifierVersion: version
            )
            return try result(.supported, ["Cited source text supports the proposition."], evidence: [evidence])
        }

        return try result(.unsupported, ["No cited source text supports \(quotedSnippet(proposition.text))."])
    }

    /// Extracts sentence/row propositions and binds citations only within the same
    /// sentence or Markdown table row. A citation on a neighboring sentence cannot
    /// retroactively support an uncited claim. Periods that punctuate initials or
    /// legal abbreviations ("Steven W. Ritcheson", "Fed. R. Civ. P.") are spelling,
    /// not boundaries — splitting there would decapitate a claim from its citation.
    static func extractPropositions(from answer: String) -> [CitedProposition] {
        var spans: [(text: String, range: NSRange)] = []
        let nsAnswer = answer as NSString
        // Length-preserving, so ranges found in the masked string index the original.
        let maskedAnswer = maskingNonBoundaryPeriods(answer)
        var lineStart = 0

        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let lineLength = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { lineStart += lineLength + 1 }

            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  trimmed != "---",
                  !isTableDecoration(trimmed),
                  !isTableHeader(trimmed)
            else { continue }

            if trimmed.contains("|") {
                spans.append((trimmed, NSRange(location: lineStart, length: lineLength)))
                continue
            }

            // A list introducer ("The attorneys of record are:") only announces the
            // cited items that follow; it carries no independently citable fact.
            if trimmed.hasSuffix(":") { continue }

            let lineRange = NSRange(location: lineStart, length: lineLength)
            guard let sentenceRegex = try? NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+|$)"#) else { continue }
            for match in sentenceRegex.matches(in: maskedAnswer, range: lineRange) {
                let raw = nsAnswer.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { spans.append((raw, match.range)) }
            }
        }

        var propositions: [CitedProposition] = []
        for span in spans {
            let labels = CitationCoverage.usedLabels(in: span.text)
            let material = materialText(span.text)
            guard isMaterial(material) else { continue }
            propositions.append(CitedProposition(
                id: "document-proposition-\(propositions.count + 1)",
                text: material,
                citationLabels: labels,
                outputRange: span.range.location..<(span.range.location + span.range.length)
            ))
        }
        return propositions
    }

    private static func supportingExcerpt(for proposition: String, in sourceText: String) throws -> String? {
        let propositionTokens = significantTokens(in: proposition)
        guard propositionTokens.count >= 2 else { return nil }
        let propositionCritical = criticalTokens(in: proposition)
        let propositionCriticalOrder = orderedBoundCriticalTokens(in: proposition)
        let propositionDates = canonicalDates(in: proposition)
        let propositionOrder = orderedMaterialTokens(in: proposition)
        let propositionQualifiers = limitingQualifiers(in: proposition)
        let propositionNegated = containsNegation(proposition)

        // Candidates come from the rejoined (de-hyphenated) text with abbreviation
        // periods masked, so "Ritche-\nson" reads as one word and "W." does not end
        // a sentence. The mask is length-preserving; substrings come from the
        // readable text so evidence excerpts keep their real periods.
        let readableSource = dehyphenated(sourceText)
        let maskedSource = maskingNonBoundaryPeriods(readableSource)
        let nsSource = readableSource as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let sentenceRegex = try? NSRegularExpression(pattern: #"[^.!?\n]+(?:[.!?]+|\n|$)"#)
        var candidates = sentenceRegex?.matches(in: maskedSource, range: fullRange).compactMap { match -> String? in
            let candidate = nsSource.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        } ?? []
        candidates.append(contentsOf: lineBlockCandidates(in: readableSource))
        let searchCandidates = candidates.isEmpty ? [readableSource] : candidates

        var best: (text: String, extraTokenCount: Int)?
        for candidate in searchCandidates {
            try Task.checkCancellation()
            let sourceTokens = significantTokens(in: candidate)
            let sourceCritical = criticalTokens(in: candidate)
            let sourceDates = canonicalDates(in: candidate)
            guard propositionCritical.isSubset(of: sourceCritical) else { continue }
            guard isPlainOrderedSubsequence(
                propositionCriticalOrder,
                of: orderedBoundCriticalTokens(in: candidate)
            ) else { continue }
            guard propositionDates.isSubset(of: sourceDates) else { continue }
            guard propositionNegated == containsNegation(candidate) else { continue }
            guard limitingQualifiers(in: candidate).isSubset(of: propositionQualifiers) else { continue }
            guard multiset(sourceTokens, contains: propositionTokens) else { continue }
            guard isOrderedSubsequence(
                propositionOrder,
                of: orderedMaterialTokens(in: candidate)
            ) else { continue }

            let extraTokenCount = sourceTokens.count - propositionTokens.count
            if best == nil || extraTokenCount < best!.extraTokenCount {
                best = (candidate, extraTokenCount)
            }
        }
        return best?.text
    }

    /// Every normalized material token in the proposition must be accounted for
    /// by the cited sentence. This deliberately rejects a mostly-extractive
    /// sentence with even one new factual clause.
    private static func multiset(_ available: [String], contains required: [String]) -> Bool {
        var counts = available.reduce(into: [String: Int]()) { partial, token in
            partial[token, default: 0] += 1
        }
        for token in required {
            guard let count = counts[token], count > 0 else { return false }
            counts[token] = count - 1
        }
        return true
    }

    /// Preserve the order of word-bearing material tokens while allowing dates
    /// to move into a chronology table's leading Date column. Reversing actors in
    /// an otherwise identical sentence therefore fails closed.
    private static func orderedMaterialTokens(in text: String) -> [String] {
        normalizedWords(in: text).filter { token in
            (!stopWords.contains(token) || relationshipMarkers.contains(token))
                && !token.contains(where: \.isNumber)
                && !token.contains("@")
                && !token.hasPrefix("$")
        }
    }

    private static func limitingQualifiers(in text: String) -> Set<String> {
        Set(normalizedWords(in: text).filter { token in
            limitingQualifierTokens.contains(token)
        })
    }

    /// Currency and identity-bearing values must occur in the same order as the
    /// proposition so equal value sets cannot be reassigned to different actors.
    private static func orderedBoundCriticalTokens(in text: String) -> [String] {
        normalizedWords(in: text).filter { token in
            token.hasPrefix("$") || token.contains("@")
        }
    }

    private static func isPlainOrderedSubsequence(_ required: [String], of available: [String]) -> Bool {
        guard !required.isEmpty else { return true }
        var nextAvailableIndex = 0
        for token in required {
            guard nextAvailableIndex < available.count,
                  let matchIndex = available[nextAvailableIndex...].firstIndex(of: token)
            else { return false }
            nextAvailableIndex = matchIndex + 1
        }
        return true
    }

    private static func isOrderedSubsequence(_ required: [String], of available: [String]) -> Bool {
        guard !required.isEmpty else { return true }
        var nextAvailableIndex = 0
        var matchedIndices: [Int] = []

        for requiredToken in required {
            guard nextAvailableIndex < available.count,
                  let matchIndex = available[nextAvailableIndex...].firstIndex(of: requiredToken)
            else { return false }
            matchedIndices.append(matchIndex)
            nextAvailableIndex = matchIndex + 1
        }

        guard let first = matchedIndices.first, let last = matchedIndices.last else { return false }
        let requiredRelationships = required.filter(relationshipMarkers.contains)
        let availableRelationships = available[first...last].filter(relationshipMarkers.contains)
        return requiredRelationships == availableRelationships
    }

    private static let relationshipMarkers: Set<String> = [
        "after", "against", "before", "between", "by", "from", "through", "to", "under", "via",
    ]

    private static let limitingQualifierTokens: Set<String> = [
        "allegedly", "claim", "conditional", "contingent", "could", "estimat", "expected",
        "if", "may", "might", "only", "pending", "possible", "possibly", "purported",
        "reported", "subject", "unless", "would",
    ]

    /// Normalize the date forms emitted by document Q&A and chronology output so
    /// a token-set collision such as March 8 versus August 3 cannot pass merely
    /// because both contain the numbers 3 and 8.
    private static func canonicalDates(in text: String) -> Set<String> {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var values = Set<String>()

        func capture(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return nsText.substring(with: range)
        }

        func insert(year: Int, month: Int, day: Int) {
            guard (1...12).contains(month), (1...31).contains(day) else { return }
            values.insert(String(format: "%04d-%02d-%02d", year, month, day))
        }

        if let iso = try? NSRegularExpression(pattern: #"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b"#) {
            for match in iso.matches(in: text, range: fullRange) {
                guard let year = capture(match, 1).flatMap(Int.init),
                      let month = capture(match, 2).flatMap(Int.init),
                      let day = capture(match, 3).flatMap(Int.init)
                else { continue }
                insert(year: year, month: month, day: day)
            }
        }

        if let slash = try? NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#) {
            for match in slash.matches(in: text, range: fullRange) {
                guard let month = capture(match, 1).flatMap(Int.init),
                      let day = capture(match, 2).flatMap(Int.init),
                      let year = capture(match, 3).flatMap(Int.init)
                else { continue }
                insert(year: year, month: month, day: day)
            }
        }

        let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let namedPattern = #"\b("# + monthNames + #")\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s*(\d{4})\b"#
        if let named = try? NSRegularExpression(pattern: namedPattern, options: .caseInsensitive) {
            for match in named.matches(in: text, range: fullRange) {
                guard let monthName = capture(match, 1)?.lowercased(),
                      let month = months[monthName].flatMap(Int.init),
                      let day = capture(match, 2).flatMap(Int.init),
                      let year = capture(match, 3).flatMap(Int.init)
                else { continue }
                insert(year: year, month: month, day: day)
            }
        }

        return values
    }

    // MARK: - Text structure helpers

    /// Length-preserving mask for periods that punctuate single-letter initials
    /// ("Steven W. Ritcheson") or common legal abbreviations ("Fed. R. Civ. P.
    /// 12(b)(6)", "Inc."): they are spelling, not sentence boundaries. Because every
    /// replacement is one UTF-16 unit for one, ranges found in the masked string are
    /// valid in the string it was made from. Masking can only merge sentences —
    /// a merged candidate must satisfy strictly more containment, never less.
    private static let maskedPeriod = "\u{F8FF}"
    private static let nonBoundaryPeriodRegexes: [NSRegularExpression] = {
        let abbreviations = [
            "Mr", "Mrs", "Ms", "Dr", "Jr", "Sr", "Esq", "Hon",
            "v", "vs", "No", "Nos", "Inc", "Corp", "Ltd", "Co", "LLC", "LLP", "PLC",
            "Fed", "Civ", "Crim", "Proc", "Evid", "Bankr", "Sec", "Stat", "Supp",
            "Cir", "Ct", "App", "Dist", "Div", "Ch", "Art", "Cl", "Ex", "Exh",
            "Id", "Cf", "Reg", "Rev", "St", "Ave", "Blvd", "Rd", "Ste", "Dept",
        ]
        let patterns = [
            #"(?<=\b[A-Za-z])\."#,
            "(?<=\\b(?:" + abbreviations.joined(separator: "|") + "))\\.",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static func maskingNonBoundaryPeriods(_ text: String) -> String {
        var masked = text
        for regex in nonBoundaryPeriodRegexes {
            masked = regex.stringByReplacingMatches(
                in: masked,
                range: NSRange(location: 0, length: (masked as NSString).length),
                withTemplate: maskedPeriod
            )
        }
        return masked
    }

    /// PDF text extraction splits words at line-break hyphens and soft hyphens
    /// ("Ritche-\nson"). Readers — and the model — see one word, so support
    /// candidates are built from the rejoined text.
    private static func dehyphenated(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(
                of: #"([A-Za-z])-[ \t]*\n[ \t]*([A-Za-z])"#,
                with: "$1$2",
                options: .regularExpression
            )
    }

    /// Caption and signature blocks state one fact across several short adjacent
    /// lines ("Steven W. Ritcheson (SBN 174062)" / "Attorney for Plaintiff" /
    /// "OPTIMUM VECTOR DYNAMICS LLC, …, Plaintiff,"). Sentence candidates cannot see
    /// across those line breaks, so bounded windows of consecutive short lines are
    /// also offered as candidates. A long (prose) line breaks the run, and the span
    /// and size limits keep distant facts from being smeared into one context; every
    /// window remains subject to the same ordering and containment guards.
    private static let blockWindowLineLimit = 12
    private static let blockWindowCharacterLimit = 900
    private static let blockEligibleLineLength = 100

    private static func lineBlockCandidates(in sourceText: String) -> [String] {
        let lines = sourceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var candidates: [String] = []
        var run: [String] = []
        func flushRun() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            for windowSize in 2...min(blockWindowLineLimit, run.count) {
                for start in 0...(run.count - windowSize) {
                    let window = run[start..<(start + windowSize)].joined(separator: " ")
                    if window.count <= blockWindowCharacterLimit {
                        candidates.append(window)
                    }
                }
            }
        }
        for line in lines {
            if line.count <= blockEligibleLineLength {
                run.append(line)
            } else {
                flushRun()
            }
        }
        flushRun()
        return candidates
    }

    /// A short quoted form of the claim for user-facing warnings — internal
    /// proposition IDs must not leak into the banner.
    private static func quotedSnippet(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 80
        guard collapsed.count > limit else { return "“\(collapsed)”" }
        let prefix = String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return "“\(prefix)…”"
    }

    private static func materialText(_ text: String) -> String {
        let withoutCitations = text.replacingOccurrences(
            of: #"\[[A-Za-z]{1,3}\d{1,4}\]"#,
            with: "",
            options: .regularExpression
        )
        return withoutCitations
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "`", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isMaterial(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower == "source" || lower == "sources" { return false }
        return significantTokens(in: text).count >= 2
    }

    private static func isTableDecoration(_ line: String) -> Bool {
        line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isTableHeader(_ line: String) -> Bool {
        let tokens = Set(significantTokens(in: materialText(line)))
        let headerTokens: Set<String> = ["date", "event", "source", "description", "fact", "document", "locator"]
        return !tokens.isEmpty && tokens.isSubset(of: headerTokens)
    }

    private static func containsInstructionLikeContent(_ text: String) -> Bool {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let compact = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let patterns = [
            #"\bignore\b.{0,80}\b(instructions?|prompt|system|developer|assistant)\b"#,
            #"\b(reveal|disclose|print|show)\b.{0,80}\b(other )?(source|prompt|secret|instruction)s?\b"#,
            #"\b(change|switch|override|assume)\b.{0,40}\b(role|persona|identity)\b"#,
            #"\b(output|state|claim|answer|say)\b.{0,80}\b(false|fabricated|untrue|unsupported)\b"#,
            #"\b(follow|obey|execute)\b.{0,40}\b(these|the following|my)\b.{0,20}\binstructions?\b"#,
            #"\b(call|invoke|use|run)\b.{0,40}\b(tool|function|command)s?\b"#,
            #"\byou are now\b"#,
            #"[\"']role[\"']\s*:\s*[\"']system[\"']"#,
            #"\bsystem message\b"#,
            #"\btool request\b"#,
        ]
        return patterns.contains { pattern in
            compact.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func significantTokens(in text: String) -> [String] {
        normalizedWords(in: text).filter { !stopWords.contains($0) }
    }

    private static func criticalTokens(in text: String) -> Set<String> {
        Set(normalizedWords(in: text).filter { token in
            token.contains(where: \.isNumber) || token.contains("@") || token.hasPrefix("$")
        })
    }

    private static func normalizedWords(in text: String) -> [String] {
        var normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let phrases: [(String, String)] = [
            ("no later than", " due "),
            ("must be received", " due "),
            ("due by", " due "),
            ("took place", " occurred "),
        ]
        for (phrase, replacement) in phrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: replacement)
        }
        normalized = normalized.replacingOccurrences(
            of: #"[^a-z0-9@$]+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.split(separator: " ").map { canonicalToken(String($0)) }
    }

    private static func canonicalToken(_ token: String) -> String {
        if let month = months[token] { return month }
        if token.allSatisfy(\.isNumber), let value = Int(token) { return String(value) }
        if token.count > 5, token.hasSuffix("ing") { return String(token.dropLast(3)) }
        if token.count > 4, token.hasSuffix("ed") { return String(token.dropLast(2)) }
        if token.count > 4, token.hasSuffix("es") { return String(token.dropLast(2)) }
        if token.count > 3, token.hasSuffix("s") { return String(token.dropLast()) }
        return token
    }

    private static func containsNegation(_ text: String) -> Bool {
        let tokens = Set(normalizedWords(in: text))
        return !tokens.isDisjoint(with: ["no", "not", "never", "without", "none"])
    }

    private static func hasMaterialContradiction(to proposition: String, in sourceText: String) throws -> Bool {
        let terms = Set(significantTokens(in: proposition))
        guard terms.count >= 2 else { return false }
        let propositionNegated = containsNegation(proposition)
        let readableSource = dehyphenated(sourceText)
        let maskedSource = maskingNonBoundaryPeriods(readableSource)
        let nsSource = readableSource as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?\n]+(?:[.!?]+|\n|$)"#) else {
            return false
        }
        for match in regex.matches(in: maskedSource, range: fullRange) {
            try Task.checkCancellation()
            let sentence = nsSource.substring(with: match.range)
            guard containsNegation(sentence) != propositionNegated else { continue }
            let matched = terms.intersection(significantTokens(in: sentence)).count
            if matched >= min(3, terms.count),
               Double(matched) / Double(terms.count) >= 0.6 {
                return true
            }
        }
        return false
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func appearsToBeRefusal(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        return lower.contains("do not support an answer")
            || lower.contains("does not support an answer")
            || lower.contains("sources do not contain")
            || lower.contains("cannot answer")
    }

    private static let months: [String: String] = [
        "january": "1", "jan": "1", "february": "2", "feb": "2",
        "march": "3", "mar": "3", "april": "4", "apr": "4",
        "may": "5", "june": "6", "jun": "6", "july": "7", "jul": "7",
        "august": "8", "aug": "8", "september": "9", "sep": "9", "sept": "9",
        "october": "10", "oct": "10", "november": "11", "nov": "11",
        "december": "12", "dec": "12",
    ]

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "by", "for",
        "from", "had", "has", "have", "in", "is", "it", "its", "of", "on", "or",
        "that", "the", "their", "there", "this", "to", "was", "were", "will", "with",
    ]
}
