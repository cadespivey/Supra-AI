import Foundation
import SupraCore

// ScratchPad `@matter` / `#tag` parsing and resolution (Milestone 4, Phase 2).
// Pure, UI-independent helpers so they can be unit-tested without the editor.

/// A matter as offered to the `@` autocomplete and used to resolve mentions.
public struct MatterChip: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Lowercased alphanumeric form used for fuzzy `@handle` matching.
    public var handle: String { ScratchPadTagResolver.slug(name) }
}

/// Scans note text for `@mention` and `#tag` tokens.
public enum ScratchPadTokenParser {
    /// Returns the `@` handles and `#` tags appearing in `text` (sigil dropped,
    /// trailing punctuation trimmed), order-preserving and de-duplicated.
    public static func parse(_ text: String) -> (mentions: [String], tags: [String]) {
        var mentions: [String] = []
        var tags: [String] = []
        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = rawToken.first, first == "@" || first == "#" else { continue }
            let body = trimTrailingPunctuation(String(rawToken.dropFirst()))
            guard !body.isEmpty else { continue }
            if first == "@" {
                if !mentions.contains(body) { mentions.append(body) }
            } else if !tags.contains(body) {
                tags.append(body)
            }
        }
        return (mentions, tags)
    }

    /// Drops trailing characters that are not letters/digits/`-`/`_` (e.g. a comma
    /// or period right after a mention), keeping the token body intact.
    private static func trimTrailingPunctuation(_ s: String) -> String {
        func allowed(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" }
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if allowed(s[prev]) { break }
            end = prev
        }
        return String(s[s.startIndex..<end])
    }
}

/// Resolves `@` handles to matter IDs and powers `@`/`#` autocomplete.
public enum ScratchPadTagResolver {
    /// Lowercased alphanumeric slug of a string (spaces/punctuation removed).
    public static func slug(_ value: String) -> String {
        String(String.UnicodeScalarView(
            value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    /// Resolves raw `@` handles to unique matter IDs. An `explicit` map (handle ->
    /// matter ID, recorded when the user picks a suggestion) wins; otherwise a handle
    /// matches a chip by slug equality, slug prefix, or a case-insensitive name match.
    public static func resolveMentions(
        _ handles: [String],
        chips: [MatterChip],
        explicit: [String: String] = [:]
    ) -> [String] {
        var ids: [String] = []
        func append(_ id: String) { if !ids.contains(id) { ids.append(id) } }
        for handle in handles {
            if let id = explicit[handle] { append(id); continue }
            let h = slug(handle)
            guard !h.isEmpty else { continue }
            let match = chips.first { $0.handle == h }
                ?? chips.first { !$0.handle.isEmpty && ($0.handle.hasPrefix(h) || h.hasPrefix($0.handle)) }
                ?? chips.first { $0.name.range(of: handle, options: .caseInsensitive) != nil }
            if let match { append(match.id) }
        }
        return ids
    }

    /// Matter suggestions for a typed `@` prefix (name prefix first, then contains).
    public static func matterSuggestions(prefix: String, chips: [MatterChip], limit: Int = 8) -> [MatterChip] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return Array(chips.prefix(limit)) }
        let pSlug = slug(prefix)
        let starts = chips.filter { $0.name.lowercased().hasPrefix(p) || (!pSlug.isEmpty && $0.handle.hasPrefix(pSlug)) }
        let contains = chips.filter { chip in
            !starts.contains(chip) && (chip.name.lowercased().contains(p) || (!pSlug.isEmpty && chip.handle.contains(pSlug)))
        }
        return Array((starts + contains).prefix(limit))
    }

    /// Tag suggestions for a typed `#` prefix from the known-tag registry.
    public static func tagSuggestions(prefix: String, knownTags: [String], limit: Int = 8) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return Array(knownTags.prefix(limit)) }
        return Array(knownTags.filter { $0.lowercased().hasPrefix(p) }.prefix(limit))
    }

    /// A starter vocabulary for litigation timekeeping, so `#` is useful before the
    /// user has built up their own tags. `note` (the reserved non-billable tag) is
    /// last so it doesn't crowd out billable activities. These are merged with the
    /// user's actually-used tags by `mergedTagVocabulary`.
    public static let defaultLitigationTags: [String] = [
        "call", "email", "conference", "research", "draft", "review", "revise",
        "court", "hearing", "deposition", "discovery", "filing", "travel", "note",
    ]

    /// The `#` autocomplete vocabulary: the user's used tags first (their real
    /// working set, in the order the store returns them), then any curated defaults
    /// they haven't used yet. De-duplicated case-insensitively, preferring the used
    /// spelling so "Draft" and "draft" don't both appear.
    public static func mergedTagVocabulary(
        used: [String],
        curated: [String] = defaultLitigationTags
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for tag in used + curated {
            let key = tag.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(tag)
        }
        return result
    }
}
