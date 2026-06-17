import Foundation
import SupraCore

public enum ResearchPlannerError: Error, Equatable, Sendable {
    case templateUnavailable
}

/// Builds the local-LLM prompt that proposes CourtListener search queries and
/// parses the model's Markdown response back into individual queries.
///
/// Pure and offline: no network, no runtime — the caller runs the prompt through
/// the local model and hands the raw output here for parsing (spec §9, §15.1).
public struct ResearchQueryPlanner: Sendable {
    /// The plan asks the model for exactly five proposed queries.
    public static let expectedQueryCount = 5

    public init() {}

    /// Fills the query-generation template. `dateRange` is a human description
    /// (e.g. "2015–2020" or "Any"); the caller formats it.
    public func buildPrompt(
        issueText: String,
        jurisdiction: String,
        partyPerspective: String,
        preferredCourts: [String],
        excludedCourts: [String],
        dateRange: String
    ) throws -> String {
        var template = try Self.loadTemplate()
        let replacements: [(String, String)] = [
            ("{{jurisdiction}}", blankToNeutral(jurisdiction, fallback: "Unspecified")),
            ("{{party_perspective}}", blankToNeutral(partyPerspective, fallback: "neutral")),
            ("{{preferred_courts}}", preferredCourts.isEmpty ? "Any" : preferredCourts.joined(separator: ", ")),
            ("{{excluded_courts}}", excludedCourts.isEmpty ? "None" : excludedCourts.joined(separator: ", ")),
            ("{{date_range}}", blankToNeutral(dateRange, fallback: "Any")),
            ("{{issue_text}}", issueText.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        for (token, value) in replacements {
            template = template.replacingOccurrences(of: token, with: value)
        }
        return template
    }

    /// Extracts the queries written under each `## Query N` heading. Reasoning
    /// traces are stripped first. Returns at most `expectedQueryCount`; the
    /// caller treats fewer than that as "generation incomplete" (spec §15.1).
    public func parseQueries(from rawOutput: String) -> [String] {
        let answer = ReasoningContent.answer(from: rawOutput)
        var buckets: [[String]] = []
        var current: [String]?

        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isQueryHeading(trimmed) {
                if let current { buckets.append(current) }
                current = []
            } else if isHeading(trimmed) {
                // A non-query heading (e.g. "# Research Queries") closes the block.
                if let current { buckets.append(current) }
                current = nil
            } else if current != nil {
                current?.append(line)
            }
        }
        if let current { buckets.append(current) }

        let queries: [String] = buckets.compactMap { lines in
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isPlaceholder(text) else { return nil }
            return text
        }
        return Array(queries.prefix(Self.expectedQueryCount))
    }

    // MARK: - Helpers

    private func blankToNeutral(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func isHeading(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private func isQueryHeading(_ line: String) -> Bool {
        guard isHeading(line) else { return false }
        let body = line.drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return body.hasPrefix("query")
    }

    private func isPlaceholder(_ text: String) -> Bool {
        // Guard against a model that echoes the template's placeholder lines.
        let lower = text.lowercased()
        return lower == "{{query}}" || (lower.hasPrefix("<your") && lower.hasSuffix("query>"))
    }

    private static func loadTemplate() throws -> String {
        guard
            let url = Bundle.module.url(forResource: "research-query-generation-v1", withExtension: "md"),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw ResearchPlannerError.templateUnavailable
        }
        return content
    }
}
