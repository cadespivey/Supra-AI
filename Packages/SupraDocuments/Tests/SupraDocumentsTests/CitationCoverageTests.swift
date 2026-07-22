import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

final class CitationCoverageTests: XCTestCase {
    func testUsedLabelsParsing() {
        let labels = CitationCoverage.usedLabels(in: "Foo [S1] bar [S12]. Again [S1].")
        XCTAssertEqual(labels, ["S1", "S12"])
    }

    func testResolvedLabelIsStructuralOnlyAndUnrelatedSourceRequiresReview() throws {
        // ACR-DOCSUP-01 expected RED: CitationCoverage currently treats any resolved
        // label as clean without testing whether the cited text supports the claim.
        let report = try DocumentSupportVerifier.verify(
            answer: "Payment was due March 3 [S1].",
            sources: [
                DocumentSupportSource(
                    sourceID: "chunk-unrelated",
                    label: "S1",
                    locator: "p. 8",
                    text: "The deposition was noticed for July 12."
                )
            ],
            scopeFullyIndexed: true,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(report.results.map(\.status), [.unsupported])
        XCTAssertTrue(report.requiresReview)
        XCTAssertEqual(report.verificationStatus, .needsReview)
    }

    func testMissingCitationsRequiresReview() {
        let check = CitationCoverage.check(answer: "Payment was due March 3.", availableLabels: ["S1"])
        XCTAssertFalse(check.hasInlineCitations)
        XCTAssertTrue(check.requiresReview)
    }

    func testUnresolvedLabelRequiresReview() {
        let check = CitationCoverage.check(answer: "See [S9].", availableLabels: ["S1"])
        XCTAssertEqual(check.unresolvedLabels, ["S9"])
        XCTAssertTrue(check.requiresReview)
    }

    func testUnsupportedAnswerIsValidWithoutCitations() {
        let check = CitationCoverage.check(answer: "The provided sources do not support an answer to this question.", availableLabels: ["S1"])
        XCTAssertTrue(check.appearsUnsupported)
        XCTAssertFalse(check.requiresReview)
    }

    func testRefusalPhraseInSubstantiveCitedAnswerStillRequiresReviewForUnresolvedLabel() {
        // A substantive answer that merely contains a refusal-like phrase AND cites
        // an unresolved label must not skip review (audit [10]).
        //
        // REVISED in the Phase 3C RED commit (review finding #1, methodology §3.5):
        // this test previously asserted `appearsUnsupported == true` — encoding the
        // very defect under correction, a refusal-clause-plus-assertion classified as
        // a refusal. A mixed response is not a whole-response refusal; only the
        // review requirement stands. Expected RED: `appearsUnsupported` is true today.
        let check = CitationCoverage.check(
            answer: "The sources do not contain X, but the deadline was March 3 [S9].",
            availableLabels: ["S1", "S2"]
        )
        XCTAssertFalse(
            check.appearsUnsupported,
            "a refusal clause joined to a factual assertion is mixed, not a refusal"
        )
        XCTAssertEqual(check.unresolvedLabels, ["S9"])
        XCTAssertTrue(check.requiresReview)
    }

    func testRefusalPhraseWithResolvedCitationStillReviewedNotTreatedAsRefusal() {
        // Contains a refusal phrase but actually answers and cites a real source —
        // because it cites something, it is not a genuine refusal fast-path.
        let check = CitationCoverage.check(
            answer: "I cannot answer fully, but [S1] shows the payment was due March 3.",
            availableLabels: ["S1"],
            scopeFullyIndexed: false
        )
        XCTAssertTrue(check.requiresReview)
    }

    func testIncompleteScopeRequiresReview() {
        let check = CitationCoverage.check(answer: "Due March 3 [S1].", availableLabels: ["S1"], scopeFullyIndexed: false)
        XCTAssertTrue(check.requiresReview)
    }

    func testLowConfidenceCitedSurfacesWarning() {
        let check = CitationCoverage.check(answer: "Total $42 [S1].", availableLabels: ["S1"], lowConfidenceLabels: ["S1"])
        XCTAssertEqual(check.citedLowConfidenceLabels, ["S1"])
        XCTAssertTrue(check.warnings.contains { $0.contains("low-confidence") })
    }

    func testSourceAppendixMarkdown() {
        let appendix = SourceAppendix(entries: [
            .init(label: "S1", documentName: "agreement.pdf", locatorDisplay: "p. 3", excerpt: "Indemnification…", warnings: [])
        ])
        let md = appendix.markdown()
        XCTAssertTrue(md.contains("## Sources"))
        XCTAssertTrue(md.contains("[S1]"))
        XCTAssertTrue(md.contains("agreement.pdf"))
    }
}
