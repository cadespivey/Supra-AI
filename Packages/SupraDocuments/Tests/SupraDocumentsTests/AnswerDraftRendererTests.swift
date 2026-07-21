import Foundation
@testable import SupraDocuments
import XCTest

/// Phase 1 gate-switch groundwork: renders a validated typed `AnswerDraft` back into the
/// `[S#]`-prose the chat already understands, so a typed grounded answer flows through the
/// existing citation rendering and persistence without a data-model change. Pure, model-free.
final class AnswerDraftRendererTests: XCTestCase {

    private let labels: [SpanID: String] = [
        SpanID("m/c-a"): "S1",
        SpanID("m/c-b"): "S2",
    ]

    func testRendersSegmentsWithResolvedCitationMarkers() {
        let draft = AnswerDraft(segments: [
            Segment(text: "The agreement was signed March 3, 2024.", citations: [SpanID("m/c-a")]),
            Segment(text: "The fee was $900.", citations: [SpanID("m/c-b")]),
        ])
        let text = AnswerDraftRenderer.render(draft, labelForSpanID: labels)
        XCTAssertTrue(text.contains("The agreement was signed March 3, 2024. [S1]"))
        XCTAssertTrue(text.contains("The fee was $900. [S2]"))
    }

    func testMultipleCitationsRenderAllMarkers() {
        let draft = AnswerDraft(segments: [
            Segment(text: "Both sources agree.", citations: [SpanID("m/c-a"), SpanID("m/c-b")]),
        ])
        let text = AnswerDraftRenderer.render(draft, labelForSpanID: labels)
        XCTAssertTrue(text.contains("[S1]") && text.contains("[S2]"))
    }

    func testRefusalRendersCanonicalUnsupportedText() {
        let draft = AnswerDraft(refusal: Refusal(.noCoverage))
        let text = AnswerDraftRenderer.render(draft, labelForSpanID: labels)
        XCTAssertEqual(text, "The provided sources do not support an answer to this question.")
    }

    func testStillIndexingRefusalRendersDistinctMessage() {
        let text = AnswerDraftRenderer.render(AnswerDraft(refusal: Refusal(.stillIndexing)), labelForSpanID: labels)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("indexing"))
        XCTAssertNotEqual(text, "The provided sources do not support an answer to this question.")
    }

    func testUnresolvedCitationMarkerIsOmittedButTextRemains() {
        // Post-validation this shouldn't occur, but rendering must be robust: a citation with
        // no display label drops the marker, never crashing or emitting a raw SpanID.
        let draft = AnswerDraft(segments: [Segment(text: "Claim.", citations: [SpanID("m/c-unknown")])])
        let text = AnswerDraftRenderer.render(draft, labelForSpanID: labels)
        XCTAssertEqual(text, "Claim.")
        XCTAssertFalse(text.contains("m/c-unknown"))
    }
}
