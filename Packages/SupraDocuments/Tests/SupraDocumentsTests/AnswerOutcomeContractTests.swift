import SupraDocuments
import XCTest

/// Phase 3C (corrective safety slice, review finding #1): the typed, fail-closed answer
/// outcome. `AnswerOutcome` is the internally consistent replacement for the scattered
/// "looks like a refusal" booleans: a result is either `.answered` or `.refused`, and a
/// draft that is BOTH (or neither) validates to nil — the caller must treat it as
/// malformed and route it to review. `ResponseShape` is the whole-response
/// classification for legacy prose: only `.refusal` — every sentence a pure refusal
/// statement — may suppress citation checks.
///
/// Expected RED for every test in this file: `ResponseShape`,
/// `RefusalContract.responseShape(of:)`, and `AnswerOutcome` do not exist, so the file
/// does not compile (missing symbols named in the build log). Behavioral RED reasons
/// for the shape cases are additionally observable through the existing-API tests in
/// `RefusalOutcomeGatingTests.swift`.
final class AnswerOutcomeContractTests: XCTestCase {

    // MARK: - ResponseShape: whole-response classification

    /// T-OUT-01. The canonical reply is a whole-response refusal.
    func testCanonicalReplyShapeIsRefusal() {
        XCTAssertEqual(RefusalContract.responseShape(of: RefusalContract.canonicalReply), .refusal)
    }

    /// T-OUT-02. A noncanonical pure refusal — source-inadequacy statement, no payload,
    /// no continuation clause — is a refusal, including across multiple sentences.
    func testNoncanonicalPureRefusalShapeIsRefusal() {
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not contain any information about the termination date."
            ),
            .refusal
        )
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not support an answer to this question. The sources do not mention a termination date."
            ),
            .refusal
        )
    }

    /// T-OUT-03. The review's reproduced input is mixed — a refusal clause joined to a
    /// factual assertion — and mixed always requires review downstream.
    func testMixedButClauseShapeIsMixed() {
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024."
            ),
            .mixed
        )
    }

    /// T-OUT-04. Sentence-order variants are mixed in both directions.
    func testRefusalAndAssertionSentencesAreMixedInEitherOrder() {
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not support an answer to this question. The agreement was terminated on March 3, 2024."
            ),
            .mixed
        )
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The agreement was terminated on March 3, 2024. The provided sources do not support any further detail."
            ),
            .mixed
        )
    }

    /// T-OUT-05. however/semicolon joins are mixed, not refusals.
    func testJoinedClauseVariantsAreMixed() {
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not support an answer; however, the agreement was terminated on March 3, 2024."
            ),
            .mixed
        )
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "The provided sources do not support an answer; the agreement was terminated on March 3, 2024."
            ),
            .mixed
        )
    }

    /// T-OUT-06. Ordinary substantive prose is an answer; a hedge without a source
    /// reference is not refusal-like at all.
    func testSubstantiveAnswerShapeIsAnswer() {
        XCTAssertEqual(
            RefusalContract.responseShape(of: "The agreement was terminated on March 3, 2024 [S1]."),
            .answer
        )
        XCTAssertEqual(
            RefusalContract.responseShape(
                of: "I cannot answer that with certainty, but the agreement was terminated on March 3, 2024."
            ),
            .answer
        )
    }

    /// T-OUT-07. Empty and whitespace-only text is `.empty` — never a refusal, never an
    /// answer; callers fail closed to review.
    func testEmptyTextShapeIsEmpty() {
        XCTAssertEqual(RefusalContract.responseShape(of: ""), .empty)
        XCTAssertEqual(RefusalContract.responseShape(of: "  \n\t"), .empty)
    }

    /// T-OUT-08. Consistency pin: `isRefusal` is exactly "shape == .refusal", so no
    /// caller can consume a refusal signal that disagrees with the typed shape.
    func testIsRefusalAgreesWithResponseShape() {
        let samples = [
            RefusalContract.canonicalReply,
            "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024.",
            "The agreement was terminated on March 3, 2024 [S1].",
            "The provided sources do not contain any information about the termination date.",
        ]
        for sample in samples {
            XCTAssertEqual(
                RefusalContract.isRefusal(sample),
                RefusalContract.responseShape(of: sample) == .refusal,
                "isRefusal must be derived from the typed shape for: \(sample)"
            )
        }
    }

    // MARK: - AnswerOutcome: typed, fail-closed

    /// T-OUT-09. A pure substantive draft validates to `.answered` and preserves the
    /// draft.
    func testPureAnswerValidatesToAnswered() throws {
        let draft = AnswerDraft(segments: [
            Segment(text: "The agreement was terminated on March 3, 2024.", citations: [SpanID("matter/chunk-1")])
        ])
        let outcome = try XCTUnwrap(AnswerOutcome(validating: draft))
        guard case .answered(let validated) = outcome else {
            return XCTFail("a substantive draft must validate to .answered, got \(outcome)")
        }
        XCTAssertEqual(validated, draft)
    }

    /// T-OUT-10. A pure refusal validates to `.refused` and preserves the reason.
    func testPureRefusalValidatesToRefused() throws {
        let outcome = try XCTUnwrap(
            AnswerOutcome(validating: AnswerDraft(refusal: Refusal(.stillIndexing)))
        )
        guard case .refused(let refusal) = outcome else {
            return XCTFail("a pure refusal draft must validate to .refused, got \(outcome)")
        }
        XCTAssertEqual(refusal.reason, .stillIndexing)
    }

    /// T-OUT-11. A refusal carrying material answer segments is malformed: validation
    /// fails (nil) so no caller can route it down the refusal fast path.
    func testRefusalCarryingSegmentsFailsValidation() {
        let mixed = AnswerDraft(
            segments: [Segment(text: "The agreement was terminated on March 3, 2024.", citations: [SpanID("matter/chunk-1")])],
            refusal: Refusal(.noCoverage)
        )
        XCTAssertNil(
            AnswerOutcome(validating: mixed),
            "a refusal cannot contain material answer text or citations"
        )
    }

    /// T-OUT-12. A draft with neither a refusal nor any non-blank segment is malformed.
    func testEmptyDraftFailsValidation() {
        XCTAssertNil(AnswerOutcome(validating: AnswerDraft()))
        XCTAssertNil(
            AnswerOutcome(validating: AnswerDraft(segments: [Segment(text: "   ")])),
            "blank segments are not answer content"
        )
    }

    /// T-OUT-13. Blank segments do not disqualify a refusal — they carry no answer
    /// content, so the outcome is still a clean `.refused`.
    func testRefusalWithOnlyBlankSegmentsIsStillRefused() throws {
        let outcome = try XCTUnwrap(
            AnswerOutcome(
                validating: AnswerDraft(segments: [Segment(text: " \n")], refusal: Refusal(.noCoverage))
            )
        )
        guard case .refused = outcome else {
            return XCTFail("blank segments carry no answer content, got \(outcome)")
        }
    }

    /// T-OUT-14. A blank string does not erase attribution payload. A refusal cannot
    /// carry citations or quotes even when the segment prose is whitespace-only.
    func testRefusalWithAttributedBlankSegmentFailsValidation() {
        let draft = AnswerDraft(
            segments: [Segment(text: "  ", citations: [SpanID("matter/chunk-1")])],
            refusal: Refusal(.noCoverage)
        )
        XCTAssertNil(AnswerOutcome(validating: draft))
    }
}
