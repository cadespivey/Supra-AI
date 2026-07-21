import Foundation
@testable import SupraDocuments
import XCTest

/// Phase 1 typed I/O contract: the model emits an AnswerDraft as strict JSON (citing evidence
/// by compact label), and a tolerant parser decodes it, resolving labels to STABLE SpanIDs.
/// This is the foundation the capability harness and typed generation both build on, and it
/// composes with AttributionValidator (parse → validate). All model-free and deterministic.
final class AnswerDraftContractTests: XCTestCase {

    private let labelMap: [String: SpanID] = [
        "S1": SpanID("matter/chunk-a"),
        "S2": SpanID("matter/chunk-b"),
    ]

    func testParsesSegmentsAndResolvesLabelsToStableIDs() throws {
        let raw = #"""
        {"insufficient_evidence": false, "segments": [
          {"text": "The agreement was signed March 3, 2024.", "citations": ["S1"], "quotes": [{"span_id": "S1", "verbatim": "signed March 3, 2024"}]},
          {"text": "The fee was $900.", "citations": ["S2"]}
        ]}
        """#
        let draft = try AnswerDraftContract.parse(raw, labelToSpanID: labelMap)
        XCTAssertFalse(draft.insufficientEvidence)
        XCTAssertEqual(draft.segments.count, 2)
        XCTAssertEqual(draft.segments[0].citations, [SpanID("matter/chunk-a")])
        XCTAssertEqual(draft.segments[0].quotes.first?.spanID, SpanID("matter/chunk-a"))
        XCTAssertEqual(draft.segments[1].citations, [SpanID("matter/chunk-b")])
    }

    func testTolerantParseStripsCodeFencesAndProse() throws {
        let raw = """
        Sure — here is the structured answer:
        ```json
        {"insufficient_evidence": false, "segments": [{"text": "X.", "citations": ["S1"]}]}
        ```
        Let me know if you need anything else.
        """
        let draft = try AnswerDraftContract.parse(raw, labelToSpanID: labelMap)
        XCTAssertEqual(draft.segments.first?.citations, [SpanID("matter/chunk-a")])
    }

    func testInsufficientEvidenceParsesToTypedRefusal() throws {
        let raw = #"{"insufficient_evidence": true, "reason": "no_coverage"}"#
        let draft = try AnswerDraftContract.parse(raw, labelToSpanID: labelMap)
        XCTAssertTrue(draft.insufficientEvidence)
        XCTAssertEqual(draft.refusal, Refusal(.noCoverage))
        XCTAssertTrue(draft.segments.isEmpty)
    }

    func testMalformedOutputThrowsForRepairLoop() {
        XCTAssertThrowsError(try AnswerDraftContract.parse("not json at all", labelToSpanID: labelMap)) { error in
            XCTAssertEqual(error as? AnswerDraftContract.ParseError, .noJSONObject)
        }
        XCTAssertThrowsError(try AnswerDraftContract.parse(#"{"segments": "wrong-type"}"#, labelToSpanID: labelMap)) { error in
            XCTAssertEqual(error as? AnswerDraftContract.ParseError, .malformed)
        }
    }

    func testUnresolvedLabelSurvivesParseAndIsCaughtByValidator() throws {
        // A label the packet never assigned parses to a SpanID absent from the evidence set,
        // so the exact validator flags it — parse is tolerant, validation is strict.
        let raw = #"{"segments": [{"text": "Y.", "citations": ["S9"]}]}"#
        let draft = try AnswerDraftContract.parse(raw, labelToSpanID: labelMap)
        let evidence = EvidenceSet(spans: [
            Span(id: SpanID("matter/chunk-a"), kind: .document, exactText: "A"),
            Span(id: SpanID("matter/chunk-b"), kind: .document, exactText: "B"),
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: evidence)
        XCTAssertTrue(result.violations.contains { $0.kind == .citationNotInEvidence })
    }

    func testBuildPromptCarriesSchemaLabelsAndQuestion() {
        let prompt = AnswerDraftContract.buildPrompt(
            question: "When was the agreement signed?",
            labeledSpans: [(label: "S1", text: "Signed March 3, 2024."), (label: "S2", text: "Fee $900.")]
        )
        XCTAssertTrue(prompt.contains("insufficient_evidence"), "schema must be stated")
        XCTAssertTrue(prompt.contains("\"citations\""))
        XCTAssertTrue(prompt.contains("S1") && prompt.contains("S2"), "each span's label must be shown")
        XCTAssertTrue(prompt.contains("Signed March 3, 2024."), "each span's text must be shown")
        XCTAssertTrue(prompt.contains("When was the agreement signed?"))
    }
}
