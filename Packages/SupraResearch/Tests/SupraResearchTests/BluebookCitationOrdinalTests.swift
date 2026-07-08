import XCTest
@testable import SupraResearch

/// Covers `BluebookCitation.ordinal`, the helper that renders federal-circuit
/// numbers ("2d Cir.", "11th Cir."). The reachable domain today is 1–11, but the
/// helper follows the general Bluebook ordinal rule, so these tests also pin the
/// higher-number cases that the naive `\(n)th` fallback used to get wrong
/// ("21th"/"22th"/"23th").
final class BluebookCitationOrdinalTests: XCTestCase {

    // MARK: - Reachable federal-circuit domain (1–11)

    func testLowOrdinalsUseBluebookDFormAndTeensUseTh() {
        // 2 and 3 take a bare "d" (Bluebook Rule 6.2(b)), not "nd"/"rd".
        XCTAssertEqual(BluebookCitation.ordinal(1), "1st")
        XCTAssertEqual(BluebookCitation.ordinal(2), "2d")
        XCTAssertEqual(BluebookCitation.ordinal(3), "3d")
        XCTAssertEqual(BluebookCitation.ordinal(4), "4th")
        XCTAssertEqual(BluebookCitation.ordinal(9), "9th")
        XCTAssertEqual(BluebookCitation.ordinal(11), "11th")
    }

    // MARK: - Higher numbers: last-two-digit teens exception, last-digit otherwise

    func testTwentiesFollowTheLastDigitRuleNotABlanketTh() {
        XCTAssertEqual(BluebookCitation.ordinal(21), "21st")
        XCTAssertEqual(BluebookCitation.ordinal(22), "22d")
        XCTAssertEqual(BluebookCitation.ordinal(23), "23d")
        XCTAssertEqual(BluebookCitation.ordinal(24), "24th")
    }

    func testTeensAlwaysTakeThRegardlessOfLastDigit() {
        XCTAssertEqual(BluebookCitation.ordinal(11), "11th")
        XCTAssertEqual(BluebookCitation.ordinal(12), "12th")
        XCTAssertEqual(BluebookCitation.ordinal(13), "13th")
        // 111–113 repeat the teens exception on their last two digits.
        XCTAssertEqual(BluebookCitation.ordinal(112), "112th")
        XCTAssertEqual(BluebookCitation.ordinal(113), "113th")
    }

    func testRoundTensAndHundredTakeTh() {
        XCTAssertEqual(BluebookCitation.ordinal(10), "10th")
        XCTAssertEqual(BluebookCitation.ordinal(20), "20th")
        XCTAssertEqual(BluebookCitation.ordinal(100), "100th")
        XCTAssertEqual(BluebookCitation.ordinal(101), "101st")
    }

    // MARK: - End-to-end through the public court-abbreviation path

    func testCircuitAbbreviationsRenderThroughPublicAPI() {
        XCTAssertEqual(
            BluebookCitation.courtAbbreviation(court: nil, courtID: "ca2", citation: nil),
            "2d Cir."
        )
        XCTAssertEqual(
            BluebookCitation.courtAbbreviation(court: nil, courtID: "ca3", citation: nil),
            "3d Cir."
        )
        XCTAssertEqual(
            BluebookCitation.courtAbbreviation(court: nil, courtID: "ca11", citation: nil),
            "11th Cir."
        )
    }
}
