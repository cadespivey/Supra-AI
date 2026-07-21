import Foundation

/// Rewrites the citation-marker variants a model may emit into the canonical, space-separated
/// `[S1] [S8]` form that the renderer and `CitationCoverage` recognize. A reasoning model often
/// writes `[CITE: S1, S8]`, groups labels as `[S1, S8]`, or prefixes them (`[Source S1]`); those
/// otherwise render as literal text and are treated as uncited propositions. A bracket is rewritten
/// ONLY when, after stripping an optional `CITE`/`Source(s)` prefix, its content is nothing but
/// source labels and separators — so case citations, note markers, and ordinary bracketed prose are
/// left untouched. Idempotent: a bracket already in `[S1]` form is returned unchanged.
public enum CitationNormalizer {
    /// A single inline source label: 1–3 letters immediately followed by 1–4 digits (e.g. `S1`).
    private static let labelPattern = "[A-Za-z]{1,3}\\d{1,4}"

    public static func normalize(_ text: String) -> String {
        guard let bracketRegex = try? NSRegularExpression(pattern: "\\[([^\\[\\]]+)\\]"),
              let labelRegex = try? NSRegularExpression(pattern: labelPattern)
        else { return text }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in bracketRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let inner = ns.substring(with: match.range(at: 1))
            if let canonical = canonicalCitation(inner, labelRegex: labelRegex) {
                result += canonical
            } else {
                result += ns.substring(with: match.range) // not a citation marker — leave verbatim
            }
        }
        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    /// Returns the canonical `[S1] [S8]` rendering of a bracket's inner text, or nil when the
    /// bracket is not a citation marker.
    private static func canonicalCitation(_ inner: String, labelRegex: NSRegularExpression) -> String? {
        // Strip an optional leading "CITE"/"Source"/"Sources" prefix (with optional colon).
        let stripped = inner.replacingOccurrences(
            of: "^\\s*(?:cite|sources?)\\s*:?\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let strippedNS = stripped as NSString
        let range = NSRange(location: 0, length: strippedNS.length)
        let labels = labelRegex.matches(in: stripped, range: range).map { strippedNS.substring(with: $0.range) }
        guard !labels.isEmpty else { return nil }

        // Everything that is not a label must be a separator (comma, semicolon, ampersand,
        // "and", or whitespace) — otherwise this bracket carries prose, not a citation.
        let residue = labelRegex
            .stringByReplacingMatches(in: stripped, range: range, withTemplate: " ")
            .replacingOccurrences(of: "\\b(and|und|et)\\b", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "[,;&]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard residue.isEmpty else { return nil }

        return labels.map { "[\(canonicalLabel($0))]" }.joined(separator: " ")
    }

    /// Uppercases the letter prefix and keeps the digits (`s1` → `S1`).
    private static func canonicalLabel(_ label: String) -> String {
        let letters = label.prefix { $0.isLetter }.uppercased()
        let digits = label.drop { $0.isLetter }
        return letters + digits
    }
}
