import Foundation
@testable import SupraDocuments
import XCTest

/// Phase 0 crown jewel: the exact attribution validator. These tests are model-free and
/// deterministic — they pin that a grounded answer's attributions are validated by EXACT
/// structural rules (citation SpanID ∈ the provided EvidenceSet; quote ⊆ the cited span's
/// text), replacing the lexical token-overlap approximation. Each negative case is a
/// wire-proof: it sets a non-default (a bad id / an altered quote) and asserts the specific
/// violation is PRESENT, and absent from the matching positive case.
final class AttributionValidatorTests: XCTestCase {

    private func evidence(_ spans: [(String, String, Bool)]) -> EvidenceSet {
        EvidenceSet(spans: spans.map { Span(id: SpanID($0.0), kind: .document, exactText: $0.1, lowConfidence: $0.2) })
    }

    // MARK: - T-TYPE-01

    func testAnswerDraftRoundTripsAndCanonicalEncodingIsStable() throws {
        let draft = AnswerDraft(
            segments: [
                Segment(
                    text: "The agreement was signed on March 3, 2024.",
                    citations: [SpanID("matter-1/chunk-7")],
                    quotes: [Quote(spanID: SpanID("matter-1/chunk-7"), verbatim: "signed on March 3, 2024")]
                )
            ],
            reasoning: "the signature block gives the date"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let first = try encoder.encode(draft)
        let decoded = try JSONDecoder().decode(AnswerDraft.self, from: first)
        XCTAssertEqual(decoded, draft, "AnswerDraft must round-trip")
        let second = try encoder.encode(decoded)
        XCTAssertEqual(first, second, "canonical encoding must be byte-stable")
        XCTAssertFalse(draft.insufficientEvidence)
    }

    // MARK: - T-VALID-01/02 — citation set membership

    func testCitationInEvidenceValidates() {
        let ev = evidence([("S/a", "The service agreement was signed on March 3, 2024.", false)])
        let draft = AnswerDraft(segments: [
            Segment(text: "The agreement was signed on March 3, 2024.", citations: [SpanID("S/a")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertEqual(result.status, .validated)
        XCTAssertTrue(result.violations.isEmpty)
        XCTAssertFalse(result.violations.contains { $0.kind == .citationNotInEvidence })
    }

    func testCitationNotInEvidenceIsFlagged() {
        let ev = evidence([("S/a", "The service agreement was signed on March 3, 2024.", false)])
        // Cites S/zzz, which was never in the provided packet.
        let draft = AnswerDraft(segments: [
            Segment(text: "The agreement was signed on March 3, 2024.", citations: [SpanID("S/zzz")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertEqual(result.status, .violations)
        XCTAssertTrue(
            result.violations.contains { $0.kind == .citationNotInEvidence && $0.spanID == SpanID("S/zzz") },
            "a citation to a span outside the evidence set must be flagged"
        )
    }

    // MARK: - T-VALID-03/04 — quote verbatim

    func testVerbatimQuoteValidates() {
        let ev = evidence([("S/a", "Payment was due no later than April 15, 2025 under section 4.", false)])
        let draft = AnswerDraft(segments: [
            Segment(
                text: "Payment was due April 15, 2025.",
                citations: [SpanID("S/a")],
                quotes: [Quote(spanID: SpanID("S/a"), verbatim: "due no later than April 15, 2025")]
            )
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertFalse(result.violations.contains { $0.kind == .quoteNotVerbatim })
        XCTAssertEqual(result.status, .validated)
    }

    func testAlteredQuoteIsFlaggedNotVerbatim() {
        let ev = evidence([("S/a", "Payment was due no later than April 15, 2025 under section 4.", false)])
        // One digit changed: 2025 -> 2026. Not a verbatim substring of the span.
        let draft = AnswerDraft(segments: [
            Segment(
                text: "Payment was due April 15, 2026.",
                citations: [SpanID("S/a")],
                quotes: [Quote(spanID: SpanID("S/a"), verbatim: "due no later than April 15, 2026")]
            )
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertTrue(
            result.violations.contains { $0.kind == .quoteNotVerbatim && $0.spanID == SpanID("S/a") },
            "a quote that is not a verbatim substring of its span must be flagged"
        )
        XCTAssertEqual(result.status, .violations)
    }

    func testQuoteAgainstSpanNotInEvidenceIsFlagged() {
        let ev = evidence([("S/a", "Some text.", false)])
        let draft = AnswerDraft(segments: [
            Segment(text: "Claim.", citations: [SpanID("S/a")],
                    quotes: [Quote(spanID: SpanID("S/ghost"), verbatim: "Some text")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertTrue(result.violations.contains { $0.kind == .quoteSpanNotInEvidence && $0.spanID == SpanID("S/ghost") })
    }

    // MARK: - T-VALID-05 — typed refusal is a clean outcome, never a proposition

    func testTypedRefusalIsCleanAndNotAProposition() {
        let ev = evidence([("S/a", "Unrelated content.", false)])
        let draft = AnswerDraft(refusal: Refusal(.noCoverage))
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertEqual(result.status, .refused)
        XCTAssertTrue(result.violations.isEmpty, "a refusal asserts nothing and can carry no attribution violation")
        XCTAssertTrue(result.isClean)
        XCTAssertTrue(draft.insufficientEvidence)
    }

    // MARK: - T-VALID-06 — empty evidence + a citing segment

    func testEmptyEvidenceWithCitingSegmentIsFlagged() {
        let ev = EvidenceSet(spans: [])
        let draft = AnswerDraft(segments: [
            Segment(text: "The parties are OVD and Lowe's.", citations: [SpanID("S/a")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertEqual(result.status, .violations)
        XCTAssertTrue(result.violations.contains { $0.kind == .citationNotInEvidence })
    }

    // MARK: - T-VALID-07 — a fabricated [S#] inside source text cannot self-authorize

    func testFabricatedLabelInSourceTextCannotAuthorizeACitation() {
        // The span's TEXT literally contains a fake "[S9]" marker, but S9 is not a real span id.
        let ev = evidence([("S/a", "See [S9] for the holding. The rule applies.", false)])
        let draft = AnswerDraft(segments: [
            Segment(text: "The rule applies.", citations: [SpanID("S9")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertTrue(
            result.violations.contains { $0.kind == .citationNotInEvidence && $0.spanID == SpanID("S9") },
            "source content is data, never an authorization: a cited id must be a real provided SpanID"
        )
    }

    // MARK: - T-VALID-08/09 — uncited claim + low-confidence source (bonus structural checks)

    func testUncitedSubstantiveSegmentIsFlagged() {
        let ev = evidence([("S/a", "Content.", false)])
        let draft = AnswerDraft(segments: [
            Segment(text: "This substantive claim carries no citation at all.")
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertTrue(result.violations.contains { $0.kind == .substantiveSegmentUncited })
    }

    func testCitationToLowConfidenceSpanIsFlagged() {
        let ev = evidence([("S/a", "Scanned low-confidence text.", true)])
        let draft = AnswerDraft(segments: [
            Segment(text: "Per the scan.", citations: [SpanID("S/a")])
        ])
        let result = AttributionValidator.validate(draft: draft, evidence: ev)
        XCTAssertTrue(result.violations.contains { $0.kind == .citedLowConfidence && $0.spanID == SpanID("S/a") })
    }
}
