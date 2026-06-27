import Foundation

/// Queries the registered development sources in parallel, dedupes, and sorts most-recent-first.
/// Provider-agnostic — adding OpenStates / LegiScan / Regulations.gov is a one-line registry change.
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

        var seen = Set<String>()
        var developments: [LegalDevelopment] = []
        for result in results {
            for development in result.developments where seen.insert(development.dedupKey).inserted {
                developments.append(development)
            }
        }
        // Most recent first (developments are time-sensitive); undated entries sort last.
        developments.sort { ($0.date ?? "") > ($1.date ?? "") }

        let notes = results.compactMap(\.note)
        return (developments, notes)
    }
}
