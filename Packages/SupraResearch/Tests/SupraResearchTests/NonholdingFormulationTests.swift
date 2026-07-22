@testable import SupraResearch
import XCTest

/// Phase 3C (corrective safety slice, review finding #4): the holding/nonholding
/// detector dropped the substring needles `whether` and `might` (PR #111) because they
/// marked genuine holdings as dicta — but the bounded judicial formulations that
/// actually express "we are not deciding this" were never added in their place. A
/// court that says "we do not reach whether the statute requires written notice"
/// currently reads as SUPPORT for the claim "the court held that the statute requires
/// written notice."
///
/// The detector remains a deliberately conservative lexical heuristic for
/// review-gating — never a semantic holding/dicta determination — so the fix is a
/// bounded set of express non-decision formulations, not the restoration of bare
/// `whether`/`might`.
///
/// Expected RED (behavioral, observable on the parent commit): each formulation test
/// below fails because `nonholdingMarkerPatterns` carries no pattern for it, so
/// `isQualifiedOrNonholdingSupport` returns false and the claimed holding passes as
/// supported.
final class NonholdingFormulationTests: XCTestCase {

    private let holdingClaim = "The court held that the statute requires written notice."

    // MARK: - The review's required reproduction (expected RED)

    /// T-NONH-01. "we do not reach whether …" is an express non-decision; a claimed
    /// holding resting on it is qualified/nonholding support and requires review.
    func testDoNotReachIsNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "Because the record is inadequate, we do not reach whether the statute requires written notice.",
                for: holdingClaim
            ),
            "an expressly unreached question is not a holding"
        )
    }

    /// T-NONH-02. Tense variants of "not reach".
    func testDidNotReachAndDoesNotReachAreNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The panel did not reach the notice question, resolving the appeal on standing.",
                for: holdingClaim
            )
        )
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court does not reach the question whether written notice is required.",
                for: holdingClaim
            )
        )
    }

    // MARK: - Declination formulations (expected RED)

    /// T-NONH-03. "decline to reach" and inflected "declined/declining to decide" —
    /// the existing pattern covers only "decline(s) to decide".
    func testDeclineFormulationsAreNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We decline to reach the written-notice question presented by the statute.",
                for: holdingClaim
            )
        )
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court declined to decide whether the statute requires written notice.",
                for: holdingClaim
            )
        )
    }

    // MARK: - Leave open / express no view (expected RED)

    /// T-NONH-04. "leave open" in its common judicial arrangements.
    func testLeaveOpenIsNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We leave open the question whether the statute requires written notice.",
                for: holdingClaim
            )
        )
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court left that question open for another day, although the statute requires written notice of appeal in the ordinary case.",
                for: holdingClaim
            )
        )
    }

    /// T-NONH-05. "express no view/opinion".
    func testExpressNoViewIsNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We express no view on whether the statute requires written notice.",
                for: holdingClaim
            )
        )
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The majority expressed no opinion on the notice requirement of the statute.",
                for: holdingClaim
            )
        )
    }

    // MARK: - Standing guards (green on parent, justified per methodology §2)

    /// T-NONH-06. Standing guard: "assume without deciding" is already caught by the
    /// bounded `without deciding` marker and must stay caught — pinned here because
    /// the review names the formulation explicitly.
    func testAssumeWithoutDecidingRemainsNonholding() {
        XCTAssertTrue(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "Assuming without deciding that the statute requires written notice, we affirm on harmless-error grounds.",
                for: holdingClaim
            )
        )
    }

    /// T-NONH-07. Standing guard: bare `whether` stays retired — appellate courts
    /// phrase express holdings with it constantly, and the new formulations must not
    /// smuggle it back.
    func testWhetherInsideAnExpressHoldingStaysAHolding() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We hold that whether notice was written is an element the plaintiff must prove.",
                for: holdingClaim
            ),
            "a holding phrased with \"whether\" is still a holding"
        )
    }

    /// T-NONH-08. Standing guard: bare `might` stays retired.
    func testHedgedWordingInsideAnExpressHoldingStaysAHolding() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "We hold that the statute requires written notice, however slight the prejudice might be.",
                for: holdingClaim
            )
        )
    }

    /// T-NONH-09. Standing guard: ordinary uses of "reach"/"open"/"decline" outside
    /// the bounded formulations must not trip the detector.
    func testOrdinaryUsesOfTheNewMarkerWordsAreNotNonholding() {
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court reached the merits and held that the statute requires written notice.",
                for: holdingClaim
            ),
            "\"reached the merits\" is the opposite of declining to reach"
        )
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The clerk's office remains open, and the statute requires written notice filed there.",
                for: holdingClaim
            ),
            "\"open\" outside the leave-open formulation is not a hedge"
        )
        XCTAssertFalse(
            LegalCitationVerifier.isQualifiedOrNonholdingSupport(
                "The court held that a party may decline to renew the contract only after written notice under the statute.",
                for: holdingClaim
            ),
            "\"decline\" outside the decline-to-reach/decide formulation is substantive prose"
        )
    }
}
