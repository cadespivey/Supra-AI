import Foundation

/// Sanitizes text returned by CourtListener's search API. The search endpoint is
/// queried with `highlight=on`, which wraps matched terms in `<mark>…</mark>`, and
/// some fields are HTML-encoded (`&quot;`, `&amp;`, `&#39;`, …). Left raw, those
/// tags and entities leak into stored/displayed citations, case names, and
/// snippets (e.g. `12 <mark>Fla</mark>. L. Weekly Fed. S 216`). This is the single
/// place that strips tags and decodes the common entities to clean plain text.
public enum CourtListenerText {
    /// Strips HTML tags and decodes common entities. Returns nil for nil or
    /// all-whitespace input.
    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = value.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let decoded = decodeEntities(stripped)
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Cleans each string and drops any that become empty.
    public static func cleanList(_ values: [String]) -> [String] {
        values.compactMap { clean($0) }
    }

    /// Extracts a readable ~50–100 word passage from full opinion text for display
    /// as a richer snippet. When `around` (e.g. the short search snippet) is given,
    /// the window is centered on its first match so the passage shows the relevant
    /// language; otherwise the first substantive paragraph is used.
    public static func passage(from body: String?, around: String? = nil, targetWords: Int = 80) -> String? {
        guard let cleaned = clean(body) else { return nil }
        // Collapse whitespace so word windows are stable.
        let normalized = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        guard words.count > targetWords else { return normalized }

        var startWord = 0
        if let anchor = anchorPhrase(from: around),
           let range = normalized.range(of: anchor, options: [.caseInsensitive]) {
            let prefixWords = normalized[..<range.lowerBound].split(separator: " ").count
            startWord = max(0, prefixWords - targetWords / 3)
        }
        let endWord = min(words.count, startWord + targetWords)
        let slice = words[startWord..<endWord].joined(separator: " ")
        let prefix = startWord > 0 ? "…" : ""
        let suffix = endWord < words.count ? "…" : ""
        return prefix + slice + suffix
    }

    /// The longest run of words from a short snippet, used to locate the matching
    /// passage in the full text. Strips highlight markup first.
    private static func anchorPhrase(from snippet: String?) -> String? {
        guard let cleaned = clean(snippet) else { return nil }
        let normalized = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Drop leading/trailing ellipses fragments; keep the longest inner run.
        let runs = normalized.components(separatedBy: "…").map { $0.trimmingCharacters(in: .whitespaces) }
        let best = runs.max(by: { $0.split(separator: " ").count < $1.split(separator: " ").count })
        guard let best, best.split(separator: " ").count >= 3 else { return nil }
        return best
    }

    private static func decodeEntities(_ input: String) -> String {
        var output = input
        // `&amp;` is decoded last so decoding can't synthesize a new entity.
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&#34;", "\""),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&sect;", "§"), ("&#167;", "§"),
            // Smart punctuation common in case text / case names.
            ("&rsquo;", "’"), ("&#8217;", "’"), ("&lsquo;", "‘"), ("&#8216;", "‘"),
            ("&ldquo;", "“"), ("&#8220;", "“"), ("&rdquo;", "”"), ("&#8221;", "”"),
            ("&ndash;", "–"), ("&#8211;", "–"), ("&mdash;", "—"), ("&#8212;", "—"),
            ("&hellip;", "…"), ("&#8230;", "…")
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}
