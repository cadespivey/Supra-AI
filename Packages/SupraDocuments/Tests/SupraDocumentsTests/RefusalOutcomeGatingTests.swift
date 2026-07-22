import SupraDocuments
import XCTest

/// Phase 3C (corrective safety slice, review finding #1 — critical): a refusal-LIKE
/// clause must never suppress citation review of an answer that also asserts facts.
///
/// The reproduced defect: `RefusalContract.isRefusalSentence` substring-matches the
/// source-inadequacy pattern anywhere in a sentence, so
///
///     "The provided sources do not support an answer, but the agreement was
///      terminated on March 3, 2024."
///
/// classifies as a refusal. That single misclassification fails open on THREE surfaces:
/// `CitationCoverage.check` skips the citation checks (`requiresReview == false`),
/// `DocumentSupportVerifier.extractPropositions` skips the sentence (the uncited
/// assertion is never verified), and `GroundedAttributionAdapter` builds a typed
/// `Refusal` fast path from the same signal.
///
/// The corrected contract: only a WHOLE-RESPONSE refusal — every sentence a pure
/// refusal statement carrying no assertion payload and no continuation clause — may
/// suppress citation checks. A mixed or malformed response always requires review.
///
/// This file gates through EXISTING APIs only, so every RED here is an observable
/// assertion failure on the parent commit (not a compile error). The typed
/// `AnswerOutcome` API gates live in `AnswerOutcomeContractTests.swift`.
final class RefusalOutcomeGatingTests: XCTestCase {

    /// The review's reproduced input, verbatim.
    private let mixedButClause =
        "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024."

    private func source(text: String) -> DocumentSupportSource {
        DocumentSupportSource(
            sourceID: "synthetic-matter/chunk-1",
            label: "S1",
            locator: #"{"page":1}"#,
            text: text,
            lowConfidence: false
        )
    }

    private func verify(_ answer: String) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
            answer: answer,
            sources: [source(text: "The service agreement was terminated on March 3, 2024.")],
            scopeFullyIndexed: true,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    // MARK: - The reproduced mixed clause (expected RED)

    /// T-REFOUT-01. Expected RED: `isRefusal` classifies the mixed clause as a refusal,
    /// so `appearsUnsupported` is true and `requiresReview` returns false — the uncited
    /// factual assertion ships with citation review suppressed.
    func testMixedButClauseDoesNotSuppressCitationReview() {
        let result = CitationCoverage.check(answer: mixedButClause, availableLabels: ["S1"])
        XCTAssertFalse(
            result.appearsUnsupported,
            "a response asserting a fact is not a whole-response refusal"
        )
        XCTAssertTrue(
            result.requiresReview,
            "an uncited assertion joined to a refusal clause must not skip review"
        )
    }

    /// T-REFOUT-02. Expected RED: the mixed sentence is skipped by proposition
    /// extraction (refusal-sentence exclusion), so `propositions` is empty and the
    /// March 3, 2024 assertion is never checked against the cited documents.
    func testMixedButClauseIsExtractedAsAProposition() throws {
        let report = try verify(mixedButClause)
        XCTAssertFalse(
            report.appearsUnsupported,
            "a response asserting a fact is not a whole-response refusal"
        )
        XCTAssertEqual(
            report.propositions.count, 1,
            "the factual assertion must be extracted for verification"
        )
        XCTAssertTrue(report.requiresReview)
    }

    /// T-REFOUT-03. Expected RED: with a resolvable [S1] label appended, the parent
    /// falls through every `requiresReview` branch (labels resolve, scope indexed,
    /// `appearsUnsupported && usedLabels.isEmpty` false) and returns FALSE — an
    /// internally inconsistent answer ships unreviewed. A mixed response must always
    /// require review, cited or not.
    func testMixedClauseWithCitationStillRequiresReview() {
        let result = CitationCoverage.check(
            answer: "The provided sources do not support an answer, but the agreement was terminated on March 3, 2024 [S1].",
            availableLabels: ["S1"]
        )
        XCTAssertFalse(result.appearsUnsupported)
        XCTAssertTrue(
            result.requiresReview,
            "a response that both declines and asserts is internally inconsistent and must be reviewed"
        )
    }

    // MARK: - Conjunction and punctuation variants (expected RED)

    /// T-REFOUT-04. Expected RED: semicolon + "however" joins are one sentence-like
    /// span under the contract's splitter, and the substring match classifies the whole
    /// span as a refusal.
    func testHoweverJoinedClausesAreNotARefusal() {
        let answer =
            "The provided sources do not support an answer; however, the agreement was terminated on March 3, 2024."
        XCTAssertFalse(RefusalContract.isRefusal(answer))
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertTrue(result.requiresReview)
    }

    /// T-REFOUT-05. Expected RED: same failure for a bare semicolon join.
    func testSemicolonJoinedClausesAreNotARefusal() {
        let answer =
            "The provided sources do not support an answer; the agreement was terminated on March 3, 2024."
        XCTAssertFalse(RefusalContract.isRefusal(answer))
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertTrue(result.requiresReview)
    }

    /// T-REFOUT-06. Expected RED: the defect is structural, not a date-detection gap —
    /// a payload-free continuation clause after the refusal statement must also fail
    /// closed to review. (Guards against "fixing" this with a digit blacklist alone.)
    func testPayloadFreeContinuationClauseIsNotARefusal() {
        let answer = "The provided sources do not support an answer, but the buyer terminated the agreement."
        XCTAssertFalse(
            RefusalContract.isRefusal(answer),
            "a continuation clause carrying an assertion disqualifies the refusal shape"
        )
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertTrue(result.requiresReview)
    }

    // MARK: - Sentence-order variants (standing guards)

    /// T-REFOUT-07. Standing guard (green on parent, justified per §2): a refusal
    /// sentence FOLLOWED by an assertion sentence must never suppress review. This
    /// already holds because the second sentence fails the per-sentence test; the guard
    /// pins the whole-response contract so a future "any refusal sentence wins" change
    /// cannot land silently.
    func testRefusalSentenceFollowedByAssertionRequiresReview() throws {
        let answer =
            "The provided sources do not support an answer to this question. The agreement was terminated on March 3, 2024."
        XCTAssertFalse(RefusalContract.isRefusal(answer))
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertTrue(result.requiresReview)
        let report = try verify(answer)
        XCTAssertEqual(
            report.propositions.count, 1,
            "the assertion sentence must be extracted for verification"
        )
    }

    /// T-REFOUT-08. Standing guard (green on parent, justified per §2): an assertion
    /// followed by a trailing refusal disclaimer is an answer plus a caveat, never a
    /// refusal. Pins the same whole-response contract from the opposite ordering.
    func testAssertionFollowedByRefusalDisclaimerRequiresReview() throws {
        let answer =
            "The agreement was terminated on March 3, 2024. The provided sources do not support any further detail."
        XCTAssertFalse(RefusalContract.isRefusal(answer))
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertTrue(result.requiresReview)
        let report = try verify(answer)
        XCTAssertEqual(report.propositions.count, 1)
    }

    // MARK: - Genuine refusals keep their fast path (standing guards)

    /// T-REFOUT-09. Standing guard (green on parent, justified per §2): the canonical
    /// whole-response refusal remains a refusal — it asserts nothing, extracts no
    /// proposition, and skips the no-citation warning. The corrected contract must not
    /// strand honest refusals in review noise.
    func testCanonicalRefusalKeepsItsFastPath() throws {
        let answer = RefusalContract.canonicalReply
        XCTAssertTrue(RefusalContract.isRefusal(answer))
        let result = CitationCoverage.check(answer: answer, availableLabels: ["S1"])
        XCTAssertFalse(result.requiresReview)
        let report = try verify(answer)
        XCTAssertTrue(report.propositions.isEmpty, "a refusal asserts no material claim")
        XCTAssertTrue(report.appearsUnsupported)
    }

    /// T-REFOUT-10. Standing guard (green on parent, justified per §2): a noncanonical
    /// pure refusal — a source-inadequacy statement with no assertion payload and no
    /// continuation clause — is still a refusal under the anchored shape test.
    func testNoncanonicalPureRefusalIsStillARefusal() throws {
        let answer = "The provided sources do not contain any information about the termination date."
        XCTAssertTrue(RefusalContract.isRefusal(answer))
        let report = try verify(answer)
        XCTAssertTrue(report.appearsUnsupported)
        XCTAssertFalse(
            report.warnings.contains("Answer has no inline citations."),
            "an honest refusal must not be warned for citing nothing: \(report.warnings)"
        )
    }

    /// T-REFOUT-11. Standing guard (green on parent, justified per §2): the
    /// inability-plus-source-reference refusal form stays a refusal.
    func testInabilityWithSourceReferenceIsStillARefusal() {
        XCTAssertTrue(
            RefusalContract.isRefusal(
                "I cannot determine the termination date from the provided sources."
            )
        )
    }

    // MARK: - Typed path: a refusal cannot carry answer content (expected RED)

    /// T-REFOUT-12. Expected RED: `AttributionValidator` fast-paths any draft with a
    /// non-nil `refusal` to a clean `.refused` — even one that also carries cited
    /// answer segments. A typed refusal carrying material answer text is malformed and
    /// must surface violations, never a clean refusal.
    func testTypedRefusalCarryingAnswerSegmentsIsNotClean() {
        let evidence = EvidenceSet(spans: [
            Span(id: SpanID("synthetic-matter/chunk-1"), kind: .document, exactText: "The agreement was terminated on March 3, 2024.")
        ])
        let mixedDraft = AnswerDraft(
            segments: [Segment(text: "The agreement was terminated on March 3, 2024.", citations: [SpanID("synthetic-matter/chunk-1")])],
            refusal: Refusal(.noCoverage)
        )
        let result = AttributionValidator.validate(draft: mixedDraft, evidence: evidence)
        XCTAssertNotEqual(
            result.status, .refused,
            "a refusal carrying answer segments must not enter the refusal fast path"
        )
        XCTAssertFalse(
            result.isClean,
            "a mixed typed result always requires review"
        )
    }

    /// T-REFOUT-13. Expected RED: `AnswerDraftContract.parse` silently DROPS the
    /// segments of a reply that sets `insufficient_evidence: true` while also carrying
    /// answer segments, laundering a mixed reply into a clean typed refusal. The parse
    /// must preserve the mixed shape so the validator can flag it.
    func testParsePreservesSegmentsOfAMixedTypedReply() throws {
        let raw = #"{"insufficient_evidence": true, "reason": "no_coverage", "segments": [{"text": "The agreement was terminated on March 3, 2024.", "citations": ["S1"]}]}"#
        let draft = try AnswerDraftContract.parse(raw, labelToSpanID: ["S1": SpanID("synthetic-matter/chunk-1")])
        XCTAssertNotNil(draft.refusal)
        XCTAssertFalse(
            draft.segments.isEmpty,
            "parse must not launder a mixed reply into a pure refusal"
        )
        let evidence = EvidenceSet(spans: [
            Span(id: SpanID("synthetic-matter/chunk-1"), kind: .document, exactText: "The agreement was terminated on March 3, 2024.")
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: evidence)
        XCTAssertFalse(result.isClean, "the laundered mixed reply must surface as a violation")
    }

    /// T-REFOUT-14. Standing guard (green on parent, justified per §2): a pure typed
    /// refusal — no segments — remains a clean `.refused` outcome. The fix must not
    /// break the legitimate refusal fast path.
    func testPureTypedRefusalRemainsClean() {
        let result = AttributionValidator.validate(
            draft: AnswerDraft(refusal: Refusal(.noCoverage)),
            evidence: EvidenceSet(spans: [])
        )
        XCTAssertEqual(result.status, .refused)
        XCTAssertTrue(result.isClean)
    }
}
