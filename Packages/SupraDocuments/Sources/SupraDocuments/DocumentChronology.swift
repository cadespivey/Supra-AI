import Foundation
import SupraCore

/// Deterministic date detection used to select date-bearing chunks for fact
/// chronologies (plan §9.2). Recognizes ISO, slashed, month-name, month-year, and
/// bare-year forms.
public enum DateExtraction {
    private static let patterns: [String] = [
        "\\b\\d{4}-\\d{2}-\\d{2}\\b",
        "\\b\\d{1,2}/\\d{1,2}/\\d{2,4}\\b",
        "\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December)\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}\\b",
        "\\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{4}\\b",
        "\\b(?:19|20)\\d{2}\\b"
    ]

    private static let regex: NSRegularExpression? = {
        let combined = patterns.map { "(?:\($0))" }.joined(separator: "|")
        return try? NSRegularExpression(pattern: combined, options: [.caseInsensitive])
    }()

    public static func containsDate(_ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

}

public enum DocumentChronologyFormat: String, Sendable, Codable {
    case table
    case narrative

    public var outputType: StructuredOutputType {
        self == .narrative ? .factChronologyNarrative : .factChronologyTable
    }
}

/// Builds fact-chronology prompts requiring exact/partial date labeling, inline
/// citations, and source-only facts (plan §9).
public enum DocumentChronologyPromptBuilder {
    public static func build(sources: [GroundingSource], format: DocumentChronologyFormat) -> String {
        var lines: [String] = []
        lines.append("You are a litigation assistant building a fact chronology from the SOURCES below.")
        lines.append("Rules:")
        lines.append("- Use ONLY facts found in the sources. Do not invent dates or events.")
        lines.append("- Cite every entry inline with its source label in square brackets, e.g. [\(sources.first?.label ?? "S1")].")
        lines.append("- Use exact dates where the source gives them. If a date is only partial (e.g. a month or year), label it as approximate and do not invent day-level precision.")
        lines.append("- Sources marked (metadata date) are file/email metadata, not statements in the text — note that distinction.")
        lines.append("- Order entries chronologically (earliest first).")
        if format == .table {
            lines.append("- Output a Markdown table with columns: | Date | Event | Source |.")
        } else {
            lines.append("- Output a narrative chronology in short dated paragraphs, each citing its source inline.")
        }
        lines.append("")
        lines.append("SOURCES:")
        for source in sources {
            lines.append("[\(source.label)] \(source.documentName) (\(source.locatorDisplay)):")
            lines.append(source.text)
            lines.append("")
        }
        lines.append("CHRONOLOGY:")
        return lines.joined(separator: "\n")
    }
}
