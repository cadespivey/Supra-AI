import Foundation

/// Renders a validated typed `AnswerDraft` into the `[S#]`-prose the chat already understands,
/// so a typed grounded answer flows through the existing citation rendering, source-key
/// trailer, and persistence unchanged — the gate switch (P1-T4) can adopt typed generation
/// without a data-model migration. `labelForSpanID` maps each evidence span back to the
/// compact label it was shown as (the inverse of the per-turn label→SpanID map).
public enum AnswerDraftRenderer {
    public static func render(_ draft: AnswerDraft, labelForSpanID: [SpanID: String]) -> String {
        if let refusal = draft.refusal {
            return refusalText(refusal)
        }
        return draft.segments
            .map { segment in
                let markers = segment.citations
                    .compactMap { labelForSpanID[$0] }
                    .map { "[\($0)]" }
                    .joined(separator: " ")
                return markers.isEmpty
                    ? segment.text
                    : segment.text + " " + markers
            }
            .joined(separator: " ")
    }

    /// The user-facing message for a typed refusal. `.noCoverage` matches the canonical
    /// document-Q&A refusal so verification and history behave exactly as on the prose path.
    static func refusalText(_ refusal: Refusal) -> String {
        switch refusal.reason {
        case .noCoverage:
            return "The provided sources do not support an answer to this question."
        case .stillIndexing:
            return "The documents in scope are still indexing, so their text is not fully searchable yet. Try again shortly."
        case .emptyScope:
            return "There are no indexed documents in scope to answer from."
        }
    }
}
