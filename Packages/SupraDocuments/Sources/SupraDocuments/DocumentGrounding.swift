import Foundation
import SupraCore

/// A single grounding source offered to the model and recorded in the appendix
/// (plan §8). `label` is the inline citation marker, e.g. "S1".
public struct GroundingSource: Sendable, Equatable {
    public var label: String
    public var documentName: String
    public var locatorDisplay: String
    public var text: String
    public var excerpt: String
    public var lowConfidence: Bool

    public init(label: String, documentName: String, locatorDisplay: String, text: String, excerpt: String, lowConfidence: Bool = false) {
        self.label = label
        self.documentName = documentName
        self.locatorDisplay = locatorDisplay
        self.text = text
        self.excerpt = excerpt
        self.lowConfidence = lowConfidence
    }
}

public enum DocumentAnswerMode: String, Sendable, Codable {
    case short
    case memo

    /// The structured output type used to persist an answer in this mode.
    public var outputType: StructuredOutputType {
        self == .memo ? .documentQAMemo : .documentQA
    }
}

/// Builds Q&A and chronology prompts that require inline citations to the
/// provided sources (plan §8.3, §8.4, §9).
public enum DocumentQAPromptBuilder {
    public static func buildQAPrompt(question: String, sources: [GroundingSource], mode: DocumentAnswerMode) -> String {
        var lines: [String] = []
        lines.append("You are a legal document assistant. Answer the QUESTION using ONLY the SOURCES below.")
        lines.append("Rules:")
        lines.append("- Cite every factual claim inline with its source label in square brackets, e.g. [\(sources.first?.label ?? "S1")].")
        lines.append("- Do not use outside knowledge. If the sources do not contain the answer, reply exactly: \"The provided sources do not support an answer to this question.\"")
        if mode == .memo {
            lines.append("- Write a formal memo with short headed sections (Question Presented, Short Answer, Analysis), still citing inline.")
        } else {
            lines.append("- Be short and direct.")
        }
        lines.append("")
        lines.append("SOURCES:")
        for source in sources {
            lines.append("[\(source.label)] \(source.documentName) (\(source.locatorDisplay)):")
            lines.append(source.text)
            lines.append("")
        }
        lines.append("QUESTION: \(question)")
        lines.append("")
        lines.append("ANSWER:")
        return lines.joined(separator: "\n")
    }
}

/// Post-generation citation checks (plan §8.4).
public struct CitationCheckResult: Sendable, Equatable {
    public var usedLabels: [String]
    public var unresolvedLabels: [String]
    public var hasInlineCitations: Bool
    public var appearsUnsupported: Bool
    public var citedLowConfidenceLabels: [String]
    public var citedFromIncompleteScope: Bool

    /// The answer needs review when it is a substantive answer that lacks inline
    /// citations or cites labels that do not resolve, or when generated from an
    /// incomplete scope. An explicit "sources do not support" answer is valid only
    /// when it cites nothing resolvable — a substantive answer that merely contains
    /// a refusal-like phrase must not skip the citation checks.
    public var requiresReview: Bool {
        // Hallucinated/unresolved citation labels always force review, even if the
        // text also contains a refusal-like phrase.
        if !unresolvedLabels.isEmpty { return true }
        // A genuine refusal cites nothing resolvable.
        if appearsUnsupported && usedLabels.isEmpty { return citedFromIncompleteScope }
        return !hasInlineCitations || citedFromIncompleteScope
    }

    public var warnings: [String] {
        var result: [String] = []
        if !unresolvedLabels.isEmpty { result.append("Answer cites sources that do not resolve: \(unresolvedLabels.joined(separator: ", ")).") }
        if !appearsUnsupported && !hasInlineCitations { result.append("Answer has no inline citations.") }
        if !citedLowConfidenceLabels.isEmpty { result.append("Cites low-confidence OCR sources: \(citedLowConfidenceLabels.joined(separator: ", ")).") }
        if citedFromIncompleteScope { result.append("Generated from an incompletely indexed scope.") }
        return result
    }
}

public enum CitationCoverage {
    /// Finds inline `[S#]`-style labels in the answer.
    public static func usedLabels(in answer: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\[([A-Za-z]{1,3}\\d{1,4})\\]") else { return [] }
        let range = NSRange(answer.startIndex..., in: answer)
        var labels: [String] = []
        for match in regex.matches(in: answer, range: range) {
            if let labelRange = Range(match.range(at: 1), in: answer) {
                let label = String(answer[labelRange])
                if !labels.contains(label) { labels.append(label) }
            }
        }
        return labels
    }

    public static func check(
        answer: String,
        availableLabels: [String],
        lowConfidenceLabels: Set<String> = [],
        scopeFullyIndexed: Bool = true
    ) -> CitationCheckResult {
        let available = Set(availableLabels)
        let used = usedLabels(in: answer)
        let unresolved = used.filter { !available.contains($0) }
        let lowered = answer.lowercased()
        let unsupported = lowered.contains("do not support an answer")
            || lowered.contains("does not support an answer")
            || lowered.contains("sources do not contain")
            || lowered.contains("cannot answer")
        let citedLowConfidence = used.filter { lowConfidenceLabels.contains($0) }
        return CitationCheckResult(
            usedLabels: used,
            unresolvedLabels: unresolved,
            hasInlineCitations: !used.isEmpty,
            appearsUnsupported: unsupported,
            citedLowConfidenceLabels: citedLowConfidence,
            citedFromIncompleteScope: !scopeFullyIndexed
        )
    }
}

/// Source appendix model (plan §8.4, §10.3).
public struct SourceAppendix: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var label: String
        public var documentName: String
        public var locatorDisplay: String
        public var excerpt: String
        public var warnings: [String]

        public init(label: String, documentName: String, locatorDisplay: String, excerpt: String, warnings: [String] = []) {
            self.label = label
            self.documentName = documentName
            self.locatorDisplay = locatorDisplay
            self.excerpt = excerpt
            self.warnings = warnings
        }
    }

    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    /// Renders the appendix as Markdown for saved outputs/exports.
    public func markdown() -> String {
        guard !entries.isEmpty else { return "" }
        var lines = ["", "## Sources"]
        for entry in entries {
            var line = "- **[\(entry.label)]** \(entry.documentName) — \(entry.locatorDisplay)"
            if !entry.warnings.isEmpty { line += " ⚠️ \(entry.warnings.joined(separator: " "))" }
            lines.append(line)
            if !entry.excerpt.isEmpty {
                lines.append("  > \(entry.excerpt)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
