import Foundation
import SupraDocuments
@testable import SupraSessions
import XCTest

/// Phase 0 shadow adapter: projects a grounded chat turn (retrieved sources + the streamed
/// [S#] prose answer) into the typed AnswerDraft / EvidenceSet and runs the exact
/// AttributionValidator alongside the lexical verifier. These tests pin the stable-SpanID
/// citation mapping ([S#] label → the source's stable sourceID, NOT its positional order)
/// that the Phase 1 data-model migration depends on.
final class GroundedAttributionAdapterTests: XCTestCase {

    private func input(_ label: String, _ sourceID: String, _ text: String, low: Bool = false) -> GroundedSpanInput {
        GroundedSpanInput(label: label, sourceID: sourceID, text: text, lowConfidence: low)
    }

    func testEvidenceSetKeysByStableSourceID() {
        let ev = GroundedAttributionAdapter.evidenceSet(from: [
            input("S1", "matter/chunk-a", "Alpha text."),
            input("S2", "matter/chunk-b", "Beta text."),
        ])
        XCTAssertEqual(ev.ids, [SpanID("matter/chunk-a"), SpanID("matter/chunk-b")])
    }

    func testResolvedLabelsValidateAgainstStableIDs() {
        let sources = [input("S1", "matter/chunk-a", "The agreement was signed March 3, 2024."),
                       input("S2", "matter/chunk-b", "The fee was $900.")]
        let answer = "The agreement was signed on March 3, 2024 [S1]. The fee was $900 [S2]."
        let result = GroundedAttributionAdapter.shadowValidate(answer: answer, sources: sources, isRefusal: false)
        XCTAssertEqual(result.status, .validated)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testUnresolvedLabelIsFlaggedInShadow() {
        // Answer cites [S3], which was never in the provided packet.
        let sources = [input("S1", "matter/chunk-a", "Alpha."), input("S2", "matter/chunk-b", "Beta.")]
        let flagged = GroundedAttributionAdapter.shadowValidate(
            answer: "The rule applies [S3].", sources: sources, isRefusal: false
        )
        XCTAssertEqual(flagged.status, .violations)
        XCTAssertTrue(flagged.violations.contains { $0.kind == .citationNotInEvidence })
        // Wire-proof: the same answer with a resolvable label is clean.
        let clean = GroundedAttributionAdapter.shadowValidate(
            answer: "The rule applies [S1].", sources: sources, isRefusal: false
        )
        XCTAssertFalse(clean.violations.contains { $0.kind == .citationNotInEvidence })
    }

    func testRefusalProjectsToCleanTypedRefusal() {
        let sources = [input("S1", "matter/chunk-a", "Unrelated.")]
        let result = GroundedAttributionAdapter.shadowValidate(
            answer: "The provided sources do not support an answer to this question.",
            sources: sources, isRefusal: true
        )
        XCTAssertEqual(result.status, .refused)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testUncitedConnectiveSentencesAreNotSegments() {
        // A real prose answer has non-claim sentences; they must not become uncited-segment
        // noise in shadow — only [S#]-bearing sentences are attribution claims.
        let sources = [input("S1", "matter/chunk-a", "The fee was $900.")]
        let answer = "Here is what the documents show. The fee was $900 [S1]."
        let result = GroundedAttributionAdapter.shadowValidate(answer: answer, sources: sources, isRefusal: false)
        XCTAssertEqual(result.status, .validated)
        XCTAssertFalse(result.violations.contains { $0.kind == .substantiveSegmentUncited })
    }

    func testReorderingSourcesDoesNotChangeResolution() {
        // The crux of stable SpanIDs: the SAME [S1] answer resolves to the SAME stable id
        // regardless of the order the packet's sources arrive in — a positional ordinal
        // resolver would bind [S1] to whichever source happens to be first.
        let answer = "The signing date was March 3, 2024 [S1]."
        let forward = [input("S1", "matter/chunk-a", "signed March 3, 2024"),
                       input("S2", "matter/chunk-b", "other")]
        let reversed = [input("S2", "matter/chunk-b", "other"),
                        input("S1", "matter/chunk-a", "signed March 3, 2024")]
        let d1 = GroundedAttributionAdapter.answerDraft(answer: answer, sources: forward, isRefusal: false)
        let d2 = GroundedAttributionAdapter.answerDraft(answer: answer, sources: reversed, isRefusal: false)
        XCTAssertEqual(d1.segments.first?.citations, [SpanID("matter/chunk-a")])
        XCTAssertEqual(d1.segments.first?.citations, d2.segments.first?.citations)
    }
}
