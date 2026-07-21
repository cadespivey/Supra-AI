import Foundation
@testable import SupraSessions
import XCTest

/// P1-S1: a model-generated case summary summarizes a single supplied opinion. It is
/// abstractive, so it is NOT held to the citation/quote contract — but it must not smuggle
/// in a party/judge NAME that the opinion never states. `groundedSummaryAnnotation` runs the
/// existing entity-grounding check as a proportionate, advisory caveat (never a gate).
final class AuthoritySummaryGroundingTests: XCTestCase {

    private let opinion = """
    The Supreme Court of the United States held that the machine-or-transformation test is
    a useful clue but not the sole test for patent eligibility. Justice Kennedy wrote for
    the Court. The judgment of the Court of Appeals is affirmed.
    """

    func testFabricatedPartyNameInSummaryIsFlagged() {
        // The summary asserts a name the opinion never states.
        let summary = "The Court, per Justice Stevens, held that Nathan Ovidsen prevailed on eligibility."
        let result = AuthoritiesController.groundedSummaryAnnotation(summary: summary, opinionText: opinion)
        XCTAssertTrue(
            result.flaggedEntities.contains { $0.localizedCaseInsensitiveContains("Nathan Ovidsen") },
            "a name absent from the opinion must be flagged"
        )
        XCTAssertTrue(result.annotated.contains("Unverified"), "the persisted summary carries an out-of-band caveat")
        XCTAssertTrue(result.annotated.hasPrefix(summary), "the model's summary text is preserved, caveat appended")
    }

    func testGroundedSummaryIsNotAnnotated() {
        // A summary naming only entities present in the opinion is left untouched (wire-proof:
        // the caveat is absent precisely when the fabricated name is).
        let summary = "Justice Kennedy wrote that the machine-or-transformation test is not the sole test."
        let result = AuthoritiesController.groundedSummaryAnnotation(summary: summary, opinionText: opinion)
        XCTAssertTrue(result.flaggedEntities.isEmpty, "no ungrounded entity → no flag")
        XCTAssertEqual(result.annotated, summary, "a grounded summary is stored verbatim, no caveat")
        XCTAssertFalse(result.annotated.contains("Unverified"))
    }
}
