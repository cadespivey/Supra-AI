import SupraDrafting
import XCTest

final class MotionCitationShapeDetectorTests: XCTestCase {
    func testRepresentativeVerifierCitationShapesShareOneContract() {
        let citationShaped = [
            "Fictional Marine v. Harbor Works",
            "123 So. 3d 456",
            "Fla. Stat. § 95.11",
            "18 U.S.C. 1001",
            "12 C.F.R. 1026",
            "rule 12",
        ]
        for text in citationShaped {
            XCTAssertTrue(
                MotionCitationShapeDetector.containsCitationShape(in: text),
                "expected citation shape: \(text)"
            )
        }
    }

    // T-MTD-CITE-01. The shared detector must recognize both the standard
    // abbreviated and spelled-out Florida civil-rule citation forms.
    func testFloridaRulesOfCivilProcedureCitationShapeIsDetected() {
        for citation in [
            "Fla. R. Civ. P. 1.140(b)(6)",
            "Florida Rule of Civil Procedure 1.140(b)(6)",
        ] {
            XCTAssertTrue(
                MotionCitationShapeDetector.containsCitationShape(in: citation),
                "expected Florida civil-rule citation shape: \(citation)"
            )
        }
    }

    func testOrdinaryComposedMotionSlotsAreNotCitationShaped() {
        for text in [
            "Plaintiff's First Amended Complaint",
            "dismissal without prejudice and leave to amend",
            "Gulf Works, Inc.",
            "Defendant",
        ] {
            XCTAssertFalse(
                MotionCitationShapeDetector.containsCitationShape(in: text),
                "unexpected citation shape: \(text)"
            )
        }
    }
}
