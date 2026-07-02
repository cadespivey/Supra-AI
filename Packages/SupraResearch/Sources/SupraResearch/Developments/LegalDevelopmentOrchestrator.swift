import Foundation

/// Queries the registered development sources in parallel, dedupes, and sorts most-recent-first.
/// Provider-agnostic — adding a provider (OpenStates / Regulations.gov / …) is a one-line registry change.
public struct LegalDevelopmentOrchestrator: Sendable {
    public let sources: [any LegalDevelopmentSource]

    public init(sources: [any LegalDevelopmentSource]) {
        self.sources = sources
    }

    public var hasSources: Bool { !sources.isEmpty }

    public func lookup(_ query: LegalDevelopmentQuery) async -> (developments: [LegalDevelopment], notes: [String]) {
        guard !sources.isEmpty else { return ([], []) }

        let results = await withTaskGroup(of: LegalDevelopmentLookupResult.self) { group -> [LegalDevelopmentLookupResult] in
            for source in sources {
                group.addTask { await source.lookup(query) }
            }
            var collected: [LegalDevelopmentLookupResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let queryTerms = Self.significantTerms(in: query.terms)
        var seen = Set<String>()
        var developments: [LegalDevelopment] = []
        for result in results {
            for development in result.developments where seen.insert(development.dedupKey).inserted {
                if Self.isRelevant(development, to: queryTerms) {
                    developments.append(development)
                }
            }
        }
        // Most recent first (developments are time-sensitive); undated entries sort last.
        developments.sort { ($0.date ?? "") > ($1.date ?? "") }

        let notes = results.compactMap(\.note)
        return (developments, notes)
    }

    private static func isRelevant(_ development: LegalDevelopment, to queryTerms: Set<String>) -> Bool {
        guard !queryTerms.isEmpty else { return true }
        let haystack = [
            development.identifier,
            development.title,
            development.status,
            development.summary
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let developmentTerms = significantTerms(in: haystack)
        let overlap = queryTerms.intersection(developmentTerms).count
        let requiredOverlap = queryTerms.count <= 1 ? 1 : min(2, queryTerms.count)
        return overlap >= requiredOverlap
    }

    private static func significantTerms(in text: String) -> Set<String> {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(Self.normalizeDevelopmentTerm)
            .filter { $0.count >= 3 && !developmentStopwords.contains($0) }
        return Set(normalized.flatMap(Self.expandedDevelopmentTerms))
    }

    private static func normalizeDevelopmentTerm(_ value: String) -> String {
        if value.hasSuffix("ies"), value.count > 4 {
            return String(value.dropLast(3)) + "y"
        }
        if value.hasSuffix("s"), value.count > 4 {
            return String(value.dropLast())
        }
        return value
    }

    private static func expandedDevelopmentTerms(_ value: String) -> [String] {
        switch value {
        case "dba":
            return ["dba", "defense", "base"]
        case "lhwca":
            return ["lhwca", "longshore", "harbor", "worker", "compensation"]
        default:
            return [value]
        }
    }

    private static let developmentStopwords: Set<String> = [
        "act", "acts", "affect", "affecting", "agency", "agencies", "amendment",
        "bill", "case", "claim", "claimant", "code", "current", "deadline",
        "does", "federal", "file", "filing", "jurisdiction", "latest", "law",
        "legal", "limit", "limitation", "made", "pending", "period", "proposed",
        "recent", "regulation", "regulatory", "rule", "rulemaking", "rules",
        "section", "state", "statute", "statutory", "time", "under", "when"
    ]
}
