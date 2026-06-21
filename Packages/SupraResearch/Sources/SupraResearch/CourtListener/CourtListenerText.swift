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

    private static func decodeEntities(_ input: String) -> String {
        var output = input
        // `&amp;` is decoded last so decoding can't synthesize a new entity.
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&#34;", "\""),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&sect;", "§"), ("&#167;", "§")
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}
