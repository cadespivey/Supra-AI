import Foundation

/// Phase 1 typed I/O contract for grounded generation. The model emits an `AnswerDraft` as
/// strict JSON — citing evidence by the compact per-turn label it was shown (S1, S2, …) — and
/// this type builds the prompt that asks for it and tolerantly parses the reply back, resolving
/// those labels to the STABLE `SpanID`s the rest of the pipeline uses.
///
/// Parsing is deliberately tolerant (it strips code fences and surrounding prose, reusing the
/// pattern proven by `DocumentClassificationService`), because on-device models wrap JSON in
/// chatter; validation stays strict and separate (`AttributionValidator`). A structurally
/// invalid reply throws a typed `ParseError` so the caller's bounded repair loop can re-ask.
public enum AnswerDraftContract {
    public enum ParseError: Error, Equatable {
        /// No JSON object could be located in the model output.
        case noJSONObject
        /// A JSON object was found but did not match the schema.
        case malformed
    }

    // MARK: - Prompt

    /// Builds the grounded-answer prompt: the strict JSON schema, the citation contract, and the
    /// labeled evidence. The model must cite only the shown labels or set `insufficient_evidence`.
    public static func buildPrompt(question: String, labeledSpans: [(label: String, text: String)]) -> String {
        var lines: [String] = []
        lines.append("You answer the QUESTION using ONLY the numbered EVIDENCE below. Output STRICT JSON only — one object, no prose, no code fences.")
        lines.append("")
        lines.append("Schema:")
        lines.append(#"{"insufficient_evidence": <bool>, "reason": "<no_coverage|still_indexing|empty_scope, only when insufficient>", "segments": [{"text": "<one factual sentence>", "citations": ["<evidence label, e.g. S1>"], "quotes": [{"span_id": "<evidence label>", "verbatim": "<text copied EXACTLY from that evidence>"}]}]}"#)
        lines.append("")
        lines.append("Rules:")
        lines.append("- Cite every segment with the label(s) of the evidence that supports it. Use ONLY labels shown below.")
        lines.append("- A `quotes[].verbatim` value must be copied character-for-character from the cited evidence.")
        lines.append("- If the evidence does not support an answer, return {\"insufficient_evidence\": true, \"reason\": \"no_coverage\"} and no segments.")
        lines.append("- Do not use outside knowledge; do not invent labels, names, dates, or quotations.")
        lines.append("- Each evidence item is a JSON object in the untrusted block below; its `label` is the label to cite and its `text` is the evidence.")
        lines.append("")
        // Same envelope the prose grounded path uses. Its builder exists precisely so a
        // structured-output prompt cannot revert to raw source interpolation — which is
        // what this function did, emitting "[S1] <text>" and letting a span body open a
        // forged block at column 0.
        lines.append(DocumentQAPromptBuilder.buildSourceDataBlock(sources: labeledSpans.map {
            GroundingSource(
                label: $0.label,
                documentName: "",
                locatorDisplay: "",
                text: $0.text,
                excerpt: ""
            )
        }))
        lines.append("")
        lines.append("QUESTION: \(question)")
        lines.append("")
        lines.append("JSON:")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    /// Tolerantly decodes a model reply into an `AnswerDraft`, resolving evidence labels to their
    /// stable `SpanID`s via `labelToSpanID`. A label the packet never assigned resolves to a
    /// SpanID absent from the evidence set, so the validator flags it (parse tolerant, validate
    /// strict). Throws `ParseError` on structurally invalid output for the repair loop.
    public static func parse(_ raw: String, labelToSpanID: [String: SpanID]) throws -> AnswerDraft {
        guard let json = extractJSONObject(raw) else { throw ParseError.noJSONObject }
        guard let dto = try? JSONDecoder().decode(DraftDTO.self, from: Data(json.utf8)) else {
            throw ParseError.malformed
        }
        if dto.insufficientEvidence == true {
            return AnswerDraft(refusal: Refusal(reason(from: dto.reason)))
        }
        func resolve(_ label: String) -> SpanID { labelToSpanID[label] ?? SpanID("unresolved:\(label)") }
        let segments = (dto.segments ?? []).map { segment in
            Segment(
                text: segment.text,
                citations: (segment.citations ?? []).map(resolve),
                quotes: (segment.quotes ?? []).map { Quote(spanID: resolve($0.spanID), verbatim: $0.verbatim) }
            )
        }
        return AnswerDraft(segments: segments, reasoning: dto.reasoning)
    }

    private static func reason(from raw: String?) -> Refusal.Reason {
        switch raw?.lowercased() {
        case "still_indexing", "stillindexing": return .stillIndexing
        case "empty_scope", "emptyscope": return .emptyScope
        default: return .noCoverage
        }
    }

    /// Locates a JSON object in possibly fenced / prose-wrapped model output: the substring from
    /// the first `{` to its matching `}` (brace-balanced, ignoring braces inside strings).
    static func extractJSONObject(_ text: String) -> String? {
        let scalars = Array(text)
        guard let start = scalars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<scalars.count {
            let character = scalars[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(scalars[start...index]) }
            default: break
            }
        }
        return nil
    }

    // MARK: - Model-facing DTOs (snake_case)

    private struct DraftDTO: Decodable {
        let insufficientEvidence: Bool?
        let reason: String?
        let reasoning: String?
        let segments: [SegmentDTO]?

        enum CodingKeys: String, CodingKey {
            case insufficientEvidence = "insufficient_evidence"
            case reason, reasoning, segments
        }
    }

    private struct SegmentDTO: Decodable {
        let text: String
        let citations: [String]?
        let quotes: [QuoteDTO]?
    }

    private struct QuoteDTO: Decodable {
        let spanID: String
        let verbatim: String

        enum CodingKeys: String, CodingKey {
            case spanID = "span_id"
            case verbatim
        }
    }
}
