import SupraDrafting
import XCTest

final class FloridaMotionToDismissContractTests: XCTestCase {
    // T-MTD-CITE-02. Expected RED: the current parser searches for a supported
    // state reporter anywhere before a Florida parenthetical, so a string that
    // also embeds federal authority is accepted as a supported state citation.
    func testMixedFederalAndFloridaReporterStringsAreRejected() {
        let mixedCitations = [
            "Example v. Fictional, 123 F. Supp. 3d 456, 321 So. 3d 654 (Fla. 2022)",
            "Example v. Fictional, 321 So. 3d 654, 123 F.3d 456 (Fla. 2022)",
            "123 F.3d 456, 789 So. 3d 1 (Fla. 2024)",
            "123 F. Supp. 3d 456, 321 So. 3d 654 (Fla. 2022)",
        ]

        for citation in mixedCitations {
            XCTAssertFalse(
                FloridaMotionToDismissContract.isSupportedAuthorityCitation(citation),
                "mixed reporter string must fail closed: \(citation)"
            )
        }
    }

    // Standing guard: a full-string grammar must retain the supported state
    // reporter families, including their optional state-reporter pinpoints.
    func testSupportedFloridaReporterStringsAndPinpointsRemainAccepted() {
        let supportedCitations = [
            "Example v. Fictional, 123 So. 3d 456 (Fla. 2020)",
            "Example v. Fictional, 123 So. 3d 456, 460 (Fla. 2020)",
            "Example v. Fictional, 123 So. 3d 456, 460–61 (Fla. 1st DCA 2020)",
            "Sample v. Placeholder, 49 Fla. L. Weekly D1234 (Fla. 4th DCA 2024)",
            "Sample v. Placeholder, 49 Fla. L. Weekly D1234, D1236 (Fla. 4th DCA 2024)",
        ]

        for citation in supportedCitations {
            XCTAssertTrue(
                FloridaMotionToDismissContract.isSupportedAuthorityCitation(citation),
                "supported state reporter string must remain accepted: \(citation)"
            )
        }
    }
}
