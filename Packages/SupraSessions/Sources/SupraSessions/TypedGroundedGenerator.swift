import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface

/// Phase 1 P1-T2: the parse-and-repair generation loop for typed grounded answers. It asks
/// the model for an `AnswerDraft` (via `AnswerDraftContract`), parses the reply tolerantly,
/// validates it against the exact `AttributionValidator`, and re-asks on a parse OR validation
/// failure up to `maxRepairs` times — falling back cleanly if the model cannot hold the schema.
///
/// This is the honest mechanism given the runtime exposes no constrained decoding: decoding
/// produces a *candidate*, and the exact validator (not the decoder) is the trust boundary,
/// preserving the "no model-judges-model" guarantee. A clean typed refusal is a valid outcome
/// and is never re-asked. The caller (or capability harness) decides what a `.fallback` means
/// for its surface (e.g. degrade to the prose path).
public enum TypedGroundedGenerator {
    public struct Generated: Equatable, Sendable {
        public let draft: AnswerDraft
        public let validation: ValidationResult
        /// 1-based number of model calls it took to reach this result.
        public let attempts: Int

        public init(draft: AnswerDraft, validation: ValidationResult, attempts: Int) {
            self.draft = draft
            self.validation = validation
            self.attempts = attempts
        }
    }

    public enum FallbackReason: String, Sendable, Equatable {
        /// Every attempt failed to parse into the schema.
        case unparseable
        /// Parsed, but never passed exact attribution validation within the repair budget.
        case unvalidated
        /// The runtime returned no text (load/transport failure).
        case modelError
    }

    public enum Outcome: Equatable, Sendable {
        case generated(Generated)
        case fallback(FallbackReason, attempts: Int)
    }

    public static func generate(
        question: String,
        spans: [GroundedSpanInput],
        modelID: ModelID,
        options: GenerationOptions,
        systemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol,
        maxRepairs: Int = 2
    ) async -> Outcome {
        let evidence = GroundedAttributionAdapter.evidenceSet(from: spans)
        let labelToSpanID = Dictionary(
            spans.map { ($0.label, SpanID($0.sourceID)) }, uniquingKeysWith: { first, _ in first }
        )
        let basePrompt = AnswerDraftContract.buildPrompt(
            question: question, labeledSpans: spans.map { ($0.label, $0.text) }
        )

        var prompt = basePrompt
        var lastFailure: FallbackReason = .unparseable
        let totalAttempts = max(1, maxRepairs + 1)

        for attempt in 1...totalAttempts {
            let request = GenerateRequest(
                generationID: GenerationID(), modelID: modelID,
                prompt: prompt, systemPrompt: systemPrompt, options: options
            )
            guard let raw = try? await runtimeClient.collectGeneratedText(request) else {
                return .fallback(.modelError, attempts: attempt)
            }
            let answer = ReasoningContent.answer(from: raw)

            let draft: AnswerDraft
            do {
                draft = try AnswerDraftContract.parse(answer, labelToSpanID: labelToSpanID)
            } catch {
                lastFailure = .unparseable
                prompt = Self.repairPrompt(
                    base: basePrompt,
                    problem: "Your previous reply was not valid JSON for the schema. Reply with ONLY the JSON object — no prose, no code fences."
                )
                continue
            }

            let validation = AttributionValidator.validate(draft: draft, evidence: evidence)
            // A refusal or a non-empty validated answer is a usable result. A non-refusal draft
            // with no answer content (empty/blank segments) is degenerate — the weak-model
            // failure the fallback exists for — so it re-asks and ultimately falls back rather
            // than surfacing a blank "answer" that AttributionValidator finds no violation in.
            if validation.isClean, Self.hasRenderableContent(draft) {
                return .generated(Generated(draft: draft, validation: validation, attempts: attempt))
            }
            lastFailure = .unvalidated
            let problem = Self.hasRenderableContent(draft)
                ? "Your previous JSON cited or quoted evidence that does not match the provided labels. Cite ONLY the labels shown, copy any quote text exactly, and reply with ONLY the JSON object."
                : "Your previous reply had no answer content. Provide one or more segments that answer the question (each citing a shown label), or set insufficient_evidence to true. Reply with ONLY the JSON object."
            prompt = Self.repairPrompt(base: basePrompt, problem: problem)
        }

        return .fallback(lastFailure, attempts: totalAttempts)
    }

    private static func repairPrompt(base: String, problem: String) -> String {
        "\(problem)\n\n\(base)"
    }

    /// Whether the draft carries something to show the reader: a typed refusal, or at least one
    /// segment with non-whitespace text. An empty/blank-segment non-refusal draft renders to "".
    private static func hasRenderableContent(_ draft: AnswerDraft) -> Bool {
        if draft.refusal != nil { return true }
        return draft.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
