import Foundation
import SupraDocuments
@testable import SupraSessions
import XCTest

/// Phase 3C (corrective safety slice, review finding #1): the shadow adapter must
/// consume the typed `ResponseShape`, not a caller-supplied "looks like a refusal"
/// boolean. Only a whole-response `.refusal` may build the typed refusal fast path; a
/// `.mixed` response projects its cited assertions as segments so the exact validator
/// sees them.
///
/// Expected RED: `answerDraft`/`shadowValidate` take `isRefusal: Bool`, not
/// `shape: ResponseShape`, so this file does not compile (the build log names the
/// wrong-argument-label at each call). The behavioral fail-open being closed is
/// observable on the parent through `RefusalOutcomeGatingTests` in SupraDocuments:
/// the mixed clause sets `appearsUnsupported`, and this adapter turned that same
/// signal into a clean typed `Refusal`.
final class GroundedAttributionShapeTests: XCTestCase {

    private func input(_ label: String, _ sourceID: String, _ text: String) -> GroundedSpanInput {
        GroundedSpanInput(label: label, sourceID: sourceID, text: text, lowConfidence: false)
    }

    /// T-SHAPE-01. A mixed response must never become a typed refusal: its cited
    /// assertion is projected as a segment for exact validation.
    func testMixedShapeDoesNotBuildARefusalDraft() {
        let sources = [input("S1", "matter/chunk-a", "The agreement was terminated on March 3, 2024.")]
        let answer = "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024 [S1]."
        let draft = GroundedAttributionAdapter.answerDraft(
            answer: answer,
            sources: sources,
            shape: RefusalContract.responseShape(of: answer)
        )
        XCTAssertNil(draft.refusal, "a mixed response must not enter the refusal fast path")
        XCTAssertEqual(draft.segments.count, 1, "the cited assertion must be projected for validation")
        XCTAssertEqual(draft.segments.first?.citations, [SpanID("matter/chunk-a")])
    }

    /// T-SHAPE-02. A whole-response refusal keeps the typed-refusal projection.
    func testRefusalShapeStillProjectsToCleanTypedRefusal() {
        let sources = [input("S1", "matter/chunk-a", "Unrelated.")]
        let answer = "The provided sources do not support an answer to this question."
        let result = GroundedAttributionAdapter.shadowValidate(
            answer: answer,
            sources: sources,
            shape: RefusalContract.responseShape(of: answer)
        )
        XCTAssertEqual(result.status, .refused)
        XCTAssertTrue(result.violations.isEmpty)
    }

    /// T-SHAPE-03. Wire-proof that the shape parameter is consumed, not decorative:
    /// the SAME mixed answer produces a refusal draft only under `.refusal`, and the
    /// default projection under its true `.mixed` shape carries segments. (Non-default
    /// value asserted present; default refusal output asserted absent, scoped to the
    /// draft's `refusal` field.)
    func testShapeParameterIsWired() {
        let sources = [input("S1", "matter/chunk-a", "The agreement was terminated on March 3, 2024.")]
        let answer = "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024 [S1]."
        let forcedRefusal = GroundedAttributionAdapter.answerDraft(answer: answer, sources: sources, shape: .refusal)
        XCTAssertNotNil(forcedRefusal.refusal)
        XCTAssertTrue(forcedRefusal.segments.isEmpty)
        let mixed = GroundedAttributionAdapter.answerDraft(answer: answer, sources: sources, shape: .mixed)
        XCTAssertNil(mixed.refusal)
        XCTAssertFalse(mixed.segments.isEmpty)
    }
}
