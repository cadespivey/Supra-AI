import Foundation

/// Renders developments into a clearly-labeled, NON-citable "Legal developments" section appended
/// to a research answer. They are tracking context (what's pending / changing), never authority —
/// the heading and caption say so explicitly so they're never mistaken for cited law.
public enum LegalDevelopmentFormatter {
    public static func section(developments: [LegalDevelopment]) -> String? {
        guard !developments.isEmpty else { return nil }
        var lines = [
            "## Legal developments (tracking — not authority)",
            "_Pending or recent legislative/regulatory items that may affect the law above. These are not citable authority and may not be in force — verify status before relying on them._",
            ""
        ]
        for development in developments {
            let label = development.kind == .legislative ? "Bill" : "Rulemaking"
            let meta = [development.status, development.date].compactMap { $0 }.joined(separator: ", ")
            var line = "- **[\(label)] \(development.title)** — \(development.jurisdiction)"
            if !meta.isEmpty { line += " (\(meta))" }
            if let url = development.url { line += " — \(url)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
