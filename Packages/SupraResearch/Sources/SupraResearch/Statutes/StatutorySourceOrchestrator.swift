import Foundation

/// Queries the registered statutory sources and merges their results under the source-weight
/// hierarchy. Adding a new provider (govinfo, Openlaws, an MCP-backed source) is a one-line
/// registry change — the orchestration logic here is provider-agnostic.
///
/// Merge rules:
/// - All sources are queried in parallel, best-effort (a source that fails contributes nothing).
/// - Provisions are deduped by `dedupKey`; when two sources return the same provision, the
///   **higher `weightTier`** wins (so a future currency-verifiable source overrides OLC).
/// - The result is sorted by tier (desc), preserving each source's own ordering within a tier.
public struct StatutorySourceOrchestrator: Sendable {
    public let sources: [any StatutorySource]

    public init(sources: [any StatutorySource]) {
        self.sources = sources
    }

    /// Whether any statutory source is configured (used to gate the legal-research integration).
    public var hasSources: Bool { !sources.isEmpty }

    /// Looks up statutory provisions across all sources and returns the merged, weighted list
    /// plus any human notes (e.g. a source that was warming up). Never throws.
    public func lookup(_ query: StatutoryQuery) async -> (provisions: [StatutoryProvision], notes: [String]) {
        guard !sources.isEmpty else { return ([], []) }

        let results = await withTaskGroup(of: StatutoryLookupResult.self) { group -> [StatutoryLookupResult] in
            for source in sources {
                group.addTask { await source.lookup(query) }
            }
            var collected: [StatutoryLookupResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Dedupe by provision, keeping the highest-tier copy.
        var best: [String: StatutoryProvision] = [:]
        var order: [String] = []
        for result in results {
            for provision in result.provisions {
                let key = provision.dedupKey
                if let existing = best[key] {
                    if provision.weightTier > existing.weightTier { best[key] = provision }
                } else {
                    best[key] = provision
                    order.append(key)
                }
            }
        }

        // Stable sort by tier desc; ties keep first-seen (source registration) order.
        let merged = order.compactMap { best[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.weightTier != rhs.element.weightTier {
                    return lhs.element.weightTier > rhs.element.weightTier
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        let notes = results.compactMap(\.note)
        return (merged, notes)
    }
}
