import Foundation
import SupraStore

/// The practice areas already entered on matters, used by the matter form to
/// recommend an existing spelling as one is typed — the same consistency
/// mechanic as `ClientDirectory`. Derived on demand from the matters table.
public struct PracticeAreaDirectory: Sendable, Equatable {
    public struct Entry: Identifiable, Sendable, Equatable {
        /// Canonical spelling: the variant used by the most matters.
        public let name: String
        public let matterCount: Int

        public var id: String { name }
    }

    /// Most-used practice areas first.
    public let entries: [Entry]

    public static let empty = PracticeAreaDirectory(entries: [])

    init(entries: [Entry]) {
        self.entries = entries
    }

    public static func build(from rows: [MattersRepository.PracticeAreaUsageRow]) -> PracticeAreaDirectory {
        // Sum duplicate spellings first — callers may pass one row per matter
        // rather than pre-aggregated counts. Then case/diacritic-variant
        // spellings collapse into one entry; the most used spelling becomes
        // canonical (ties break alphabetically for determinism).
        var countsBySpelling: [String: Int] = [:]
        for row in rows {
            countsBySpelling[row.name, default: 0] += row.matterCount
        }
        var groups: [String: [(name: String, matterCount: Int)]] = [:]
        for (name, matterCount) in countsBySpelling {
            groups[fold(name), default: []].append((name, matterCount))
        }
        let entries = groups.values.compactMap { variants -> Entry? in
            let dominant = variants.max { lhs, rhs in
                if lhs.matterCount != rhs.matterCount { return lhs.matterCount < rhs.matterCount }
                return lhs.name > rhs.name
            }
            guard let dominant else { return nil }
            return Entry(name: dominant.name, matterCount: variants.reduce(0) { $0 + $1.matterCount })
        }
        return PracticeAreaDirectory(entries: entries.sorted { lhs, rhs in
            if lhs.matterCount != rhs.matterCount { return lhs.matterCount > rhs.matterCount }
            return lhs.name < rhs.name
        })
    }

    /// Practice areas containing the typed text (case/diacritic-insensitive),
    /// prefix matches first.
    public func suggestions(for query: String, limit: Int = 6) -> [Entry] {
        let folded = Self.fold(query)
        guard !folded.isEmpty else { return [] }
        let matches = entries.filter { Self.fold($0.name).contains(folded) }
        let leading = matches.filter { Self.fold($0.name).hasPrefix(folded) }
        return Array((leading + matches.filter { !Self.fold($0.name).hasPrefix(folded) }).prefix(limit))
    }

    /// True when the typed text already carries this entry's exact spelling.
    public func isApplied(_ entry: Entry, text: String) -> Bool {
        entry.name == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The canonical (most-used) spelling of this practice area, if known.
    public func canonicalName(for text: String) -> String? {
        let folded = Self.fold(text)
        guard !folded.isEmpty else { return nil }
        return entries.first { Self.fold($0.name) == folded }?.name
    }

    private static func fold(_ value: String) -> String {
        // Locale nil: grouping identity must not shift with the user's locale.
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
