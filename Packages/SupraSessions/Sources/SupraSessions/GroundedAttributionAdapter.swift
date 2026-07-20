import Foundation
import os
import SupraDocuments

/// The minimal projection of a retrieved grounded source the shadow adapter needs: its
/// inline `[S#]` label, its STABLE `sourceID` ("matter/chunk"), its packed text, and OCR
/// confidence. Decouples the adapter from the heavier `GroundedSourceRef`.
struct GroundedSpanInput: Equatable {
    let label: String
    let sourceID: String
    let text: String
    let lowConfidence: Bool
}

/// Phase 0 SHADOW adapter for the reasoning-framework reorg. It projects a grounded chat
/// turn — its retrieved sources plus the streamed `[S#]` prose answer — into the typed
/// `AnswerDraft` / `EvidenceSet`, and runs the exact `AttributionValidator` ALONGSIDE the
/// existing lexical verifier. It changes nothing user-visible: the result is logged
/// (metadata only — no answer or source text) so real traffic reveals where exact
/// validation would fire before Phase 1 flips the gate. It also exercises the stable-SpanID
/// citation mapping (`[S#]` label → the source's stable `sourceID`, independent of packet
/// order) on real answers, de-risking the Phase 1 data-model migration.
enum GroundedAttributionAdapter {
    private static let log = Logger(subsystem: "ai.supra.SupraAI", category: "reasoning.shadow")

    /// The EvidenceSet for a turn: each retrieved source becomes a `Span` keyed by its
    /// stable `sourceID`, not its positional `[S#]` label.
    static func evidenceSet(from sources: [GroundedSpanInput]) -> EvidenceSet {
        EvidenceSet(spans: sources.map {
            Span(id: SpanID($0.sourceID), kind: .document, exactText: $0.text, lowConfidence: $0.lowConfidence)
        })
    }

    /// Projects the streamed prose answer into an `AnswerDraft`. A canonical refusal (the
    /// caller supplies `isRefusal`, reusing the lexical verifier's own `appearsUnsupported`
    /// signal) becomes a typed `Refusal`. Otherwise each sentence carrying ≥1 `[S#]` label
    /// becomes a `Segment` whose citations are those labels resolved to their sources'
    /// stable SpanIDs; sentences with no label are not attribution claims in the prose
    /// model and are not represented (so ordinary connective prose is not uncited-segment
    /// noise). An unresolvable `[S#]` maps to a SpanID absent from the evidence set, so the
    /// validator flags it — matching the existing unresolved-label behavior.
    static func answerDraft(answer: String, sources: [GroundedSpanInput], isRefusal: Bool) -> AnswerDraft {
        if isRefusal { return AnswerDraft(refusal: Refusal(.noCoverage)) }
        let labelToSpan = Dictionary(sources.map { ($0.label, SpanID($0.sourceID)) }, uniquingKeysWith: { first, _ in first })
        var segments: [Segment] = []
        for sentence in sentences(in: answer) {
            let labels = CitationCoverage.usedLabels(in: sentence)
            guard !labels.isEmpty else { continue }
            let citations = labels.map { labelToSpan[$0] ?? SpanID("unresolved:\($0)") }
            segments.append(Segment(text: sentence, citations: citations))
        }
        return AnswerDraft(segments: segments)
    }

    static func shadowValidate(answer: String, sources: [GroundedSpanInput], isRefusal: Bool) -> ValidationResult {
        let draft = answerDraft(answer: answer, sources: sources, isRefusal: isRefusal)
        return AttributionValidator.validate(draft: draft, evidence: evidenceSet(from: sources))
    }

    /// Logs the shadow result as metadata only (never answer or source content), so a dev/
    /// synthetic-fixture run reveals where exact attribution validation would fire — and
    /// where it diverges from the lexical verifier — before Phase 1 makes it a gate.
    static func logShadow(_ result: ValidationResult, lexicalRequiresReview: Bool?) {
        let kinds = Dictionary(grouping: result.violations, by: \.kind)
            .map { "\($0.key.rawValue)×\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        // A divergence worth attention: the exact validator flags an attribution problem the
        // lexical support verifier did not force to review (or vice versa).
        let diverges = (result.status == .violations) != (lexicalRequiresReview == true)
        if result.status == .violations || diverges {
            log.notice("shadow attribution: status=\(result.status.rawValue, privacy: .public) violations=[\(kinds, privacy: .public)] lexicalReview=\(String(describing: lexicalRequiresReview), privacy: .public) diverges=\(diverges, privacy: .public)")
        } else {
            log.debug("shadow attribution: status=\(result.status.rawValue, privacy: .public)")
        }
    }

    /// Sentence split good enough for shadow segmentation: labels, not exact boundaries,
    /// drive segment membership, so abbreviation handling is unnecessary here.
    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .flatMap { $0.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
