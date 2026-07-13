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
            return try result(.unverifiable, ["Proposition \(proposition.id) has no citation in the same proposition."])
        }

        var citedSources: [DocumentSupportSource] = []
        for label in proposition.citationLabels {
            guard let source = sourceByLabel[label] else {
                return try result(.unverifiable, ["Proposition \(proposition.id) cites unresolved source \(label)."])
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
            guard let excerpt = supportingExcerpt(for: proposition.text, in: source.text) else { continue }
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

        return try result(.unsupported, ["No cited source text supports proposition \(proposition.id)."])
    }

    /// Extracts sentence/row propositions and binds citations only within the same
    /// sentence or Markdown table row. A citation on a neighboring sentence cannot
    /// retroactively support an uncited claim.
    static func extractPropositions(from answer: String) -> [CitedProposition] {
        var spans: [(text: String, range: NSRange)] = []
        let nsAnswer = answer as NSString
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

            let lineRange = NSRange(location: lineStart, length: lineLength)
            guard let sentenceRegex = try? NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+|$)"#) else { continue }
            for match in sentenceRegex.matches(in: answer, range: lineRange) {
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

    private static func supportingExcerpt(for proposition: String, in sourceText: String) -> String? {
        let propositionTokens = significantTokens(in: proposition)
        guard propositionTokens.count >= 2 else { return nil }
        let propositionCritical = criticalTokens(in: proposition)
        let propositionNegated = containsNegation(proposition)

        let nsSource = sourceText as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let sentenceRegex = try? NSRegularExpression(pattern: #"[^.!?\n]+(?:[.!?]+|\n|$)"#)
        let candidates = sentenceRegex?.matches(in: sourceText, range: fullRange).compactMap { match -> String? in
            let candidate = nsSource.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        } ?? []
        let searchCandidates = candidates.isEmpty ? [sourceText] : candidates

        var best: (text: String, coverage: Double)?
        for candidate in searchCandidates {
            let sourceTokens = Set(significantTokens(in: candidate))
            let sourceCritical = criticalTokens(in: candidate)
            guard propositionCritical.isSubset(of: sourceCritical) else { continue }
            guard propositionNegated == containsNegation(candidate) else { continue }

            let matched = propositionTokens.filter(sourceTokens.contains).count
            let coverage = Double(matched) / Double(propositionTokens.count)
            guard coverage >= 0.72 else { continue }
            if best == nil || coverage > best!.coverage { best = (candidate, coverage) }
        }
        return best?.text
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
        )
        let compact = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let patterns = [
            #"\bignore\b.{0,80}\b(instruction|prompt|system|developer|assistant)\b"#,
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
