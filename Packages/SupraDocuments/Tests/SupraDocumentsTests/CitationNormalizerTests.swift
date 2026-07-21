import Foundation
@testable import SupraDocuments
import XCTest

/// Models don't always emit the canonical `[S1]` citation marker: a reasoning model may write
/// `[CITE: S1, S8]` or group labels as `[S1, S8]`. Those neither render as links nor register as
/// citations, so `CitationNormalizer` rewrites the recognizable variants to space-separated
/// `[S1] [S8]`. Anything that is not a citation marker is left untouched.
///
/// Expected RED before `CitationNormalizer` exists: the suite does not compile.
final class CitationNormalizerTests: XCTestCase {

    private func used(_ text: String) -> [String] {
        CitationCoverage.usedLabels(in: CitationNormalizer.normalize(text))
    }

    func testRewritesCiteGroupToCanonicalLabels() {
        XCTAssertEqual(
            CitationNormalizer.normalize("The case number is 2:26 [CITE: S1, S8]."),
            "The case number is 2:26 [S1] [S8]."
        )
        XCTAssertEqual(used("The case number is 2:26 [CITE: S1, S8]."), ["S1", "S8"])
    }

    func testRewritesSingleCite() {
        XCTAssertEqual(CitationNormalizer.normalize("The fee was $900 [CITE: S1]."), "The fee was $900 [S1].")
    }

    func testRewritesGroupedBracket() {
        XCTAssertEqual(CitationNormalizer.normalize("See [S1, S8] and [S3]."), "See [S1] [S8] and [S3].")
    }

    func testRewritesSourcePrefix() {
        XCTAssertEqual(CitationNormalizer.normalize("Per [Source S1] and [Sources S2, S3]."), "Per [S1] and [S2] [S3].")
    }

    func testLowercaseLabelsAreCanonicalized() {
        XCTAssertEqual(CitationNormalizer.normalize("[cite: s1, s8]"), "[S1] [S8]")
    }

    func testAlreadyCanonicalIsUnchanged() {
        XCTAssertEqual(CitationNormalizer.normalize("The fee was $900 [S1]."), "The fee was $900 [S1].")
    }

    func testNonCitationBracketsAreUntouched() {
        // A blank line marker, a case citation, and prose "S1" are not citation markers.
        XCTAssertEqual(
            CitationNormalizer.normalize("It cites [SACV 13-0030 AG] and a note [see chronology]."),
            "It cites [SACV 13-0030 AG] and a note [see chronology]."
        )
        XCTAssertEqual(
            CitationNormalizer.normalize("The case number is 2:26 as cited in sources S1 and S8."),
            "The case number is 2:26 as cited in sources S1 and S8."
        )
    }

    func testTextWithoutBracketsIsUnchanged() {
        XCTAssertEqual(CitationNormalizer.normalize("No citations here at all."), "No citations here at all.")
    }
}
