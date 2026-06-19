import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

final class CitationCoverageTests: XCTestCase {
    func testUsedLabelsParsing() {
        let labels = CitationCoverage.usedLabels(in: "Foo [S1] bar [S12]. Again [S1].")
        XCTAssertEqual(labels, ["S1", "S12"])
    }

    func testCitedAnswerPasses() {
        let check = CitationCoverage.check(answer: "Payment was due March 3 [S1].", availableLabels: ["S1", "S2"])
        XCTAssertTrue(check.hasInlineCitations)
        XCTAssertTrue(check.unresolvedLabels.isEmpty)
        XCTAssertFalse(check.requiresReview)
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
        let check = CitationCoverage.check(
            answer: "The sources do not contain X, but the deadline was March 3 [S9].",
            availableLabels: ["S1", "S2"]
        )
        XCTAssertTrue(check.appearsUnsupported)
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
