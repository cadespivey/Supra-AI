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
