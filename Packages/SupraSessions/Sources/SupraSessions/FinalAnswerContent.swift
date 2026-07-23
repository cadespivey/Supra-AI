import Foundation

/// Render-time fold of a grounded answer's preamble: everything before the LAST
/// line-anchored "Answer:" marker is working prose that belongs with the
/// collapsed Reasoning section, and the displayed answer starts at the marker —
/// so the answer is stated exactly once, in the labeled form the short-mode QA
/// prompt requests. Bodies without a marker (bare answers, memos, research
/// output, refusals) are untouched, and persistence/copy keep the full text —
/// this reorders presentation, never content.
public enum FinalAnswerContent {
    /// Splits `body` at the last line-anchored `Answer:` (or `**Answer:**`)
    /// marker. Returns `(nil, body)` when there is no marker or nothing precedes
    /// it.
    public static func split(_ body: String) -> (preamble: String?, answer: String) {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(?:\*\*)?Answer:"#) else {
            return (nil, body)
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.matches(in: body, range: range).last,
              let markerRange = Range(match.range, in: body)
        else {
            return (nil, body)
        }
        let preamble = String(body[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preamble.isEmpty else { return (nil, body) }
        let answer = String(body[markerRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (preamble, answer)
    }
}
