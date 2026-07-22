@testable import SupraResearch
import XCTest

/// `isQualifiedOrNonholdingSupport` decides whether a cited excerpt supplies the claimed HOLDING
/// or merely dicta/dissent/expressly unresolved treatment. It does that with bare substring
/// matching on both sides:
///
///     guard claim.contains("hold") || claim.contains("require") || claim.contains("must")
///     return ["dissent", "dicta", "might", "whether", "declines to decide", "does not decide"]
///         .contains { source.contains($0) }
///
/// No word boundaries. "threshold" contains "hold"; "dictates" contains "dicta"; "mighty" contains
/// "might". And "whether" appears in most appellate prose, including inside actual holdings.
///
/// This is the last lexical-shortcut defect in this verifier, and it fails in the noisy
/// direction: a hit REJECTS support, so genuine authority is reported as not supporting the
/// proposition.
///
/// Tested directly rather than through `verify(...)`: reaching this rule end-to-end requires an
/// excerpt that first clears citation resolution, term overlap, negation polarity, and
/// contradiction, so an end-to-end assertion here passes or fails for unrelated reasons. One
/// end-to-end wire-proof is kept at the bottom to prove the rule is actually reached in
/// production.
final class HoldingDictaBoundaryTests: XCTestCase {

    private let holdingClaim = "The statute requires written notice."

    // MARK: - Substring collisions (expected RED)

    /// T-DICTA-01. "dictates" contains "dicta".
    func testDictatesIsNotDicta() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The statute's plain text dictates that written notice is required.",
                for: holdingClaim
            ),
            "\"dictates\" is not dicta"
        )
    }

    /// T-DICTA-02. "mighty" contains "might".
    func testMightyIsNotAHedge() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The mighty oak clause requires written notice of assignment.",
                for: holdingClaim
            ),
            "\"mighty\" is not the hedge \"might\""
        )
    }

    /// T-DICTA-03. A holding does not stop being a holding because it contains "whether".
    /// Appellate courts phrase the question that way constantly.
    func testWhetherInsideAHoldingIsNotNonholding() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We hold that whether notice was written is an element the plaintiff must prove.",
                for: holdingClaim
            ),
            "a holding phrased with \"whether\" is still a holding"
        )
    }

    /// T-DICTA-04. Same for hedged wording inside an express holding.
    func testHedgedWordingInsideAHoldingIsNotNonholding() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We hold that the statute requires written notice, however slight the prejudice might be.",
                for: holdingClaim
            ),
            "a hedge inside an express holding does not make it dicta"
        )
    }

    /// T-DICTA-05. The trigger side collides too: "threshold" contains "hold", so a proposition
    /// about a threshold is treated as a holding claim.
    func testThresholdIsNotAHoldingClaim() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The amount in controversy dictates the forum.",
                for: "The threshold for removal is $75,000."
            ),
            "\"threshold\" must not trigger the holding rule"
        )
    }

    // MARK: - Regression pins: genuine non-holding treatment must STILL be rejected

    func testGenuineDictaIsStillRejected() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "In dicta, the court observed that the statute would require written notice.",
                for: holdingClaim
            )
        )
    }

    func testDissentIsStillRejected() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The dissent would require written notice under the statute.",
                for: holdingClaim
            )
        )
    }

    func testExpresslyUndecidedIsStillRejected() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We do not decide whether the statute requires written notice.",
                for: holdingClaim
            )
        )
    }

    func testDeclinesToDecideIsStillRejected() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court declines to decide the written-notice question.",
                for: holdingClaim
            )
        )
    }

    /// A proposition that claims no holding is not subject to the rule at all.
    func testNonHoldingClaimIsNeverRejected() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "In dicta, the court observed that the parties settled.",
                for: "The parties settled in 2024."
            )
        )
    }

    // MARK: - Wire-proof

    /// Proves the rule is actually reached from the production entry point — the unit tests above
    /// would all pass on a function nothing calls.
    func testRuleIsReachedFromVerify() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:hd",
            authorityType: .case,
            caseName: "Holder v. Dictum",
            citation: "900 F.3d 500",
            citations: ["900 F.3d 500"],
            court: "United States Court of Appeals for the Ninth Circuit",
            courtID: "ca9",
            text: "In dicta, the court observed that the agreement requires strict compliance with the notice provision."
        )
        let report = LegalCitationVerifier.verify(
            answer: "The agreement requires strict compliance with the notice provision [A1].",
            authorities: [authority]
        )
        XCTAssertTrue(
            report.issues.contains { $0.message.contains("dicta, dissent, or expressly unresolved") },
            "the holding rule must be reachable from verify(): \(report.issues.map(\.message))"
        )
    }
}
