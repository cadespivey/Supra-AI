@testable import SupraTestKit
import XCTest

final class LocatorRoundTripBenchmarkTests: XCTestCase {
    func testBLOC01RequiresEveryRevisionAndLocatorKeyToRoundTripExactly() throws {
        // B-LOC-01 expected RED: the catalog row is still n/a and there is no
        // deterministic observation producer for revision-bound locator keys.
        let cases = [
            LocatorRoundTripBenchmarkCase(expectedKey: "rev-text|chars:19-47", resolvedKey: "rev-text|chars:19-47"),
            LocatorRoundTripBenchmarkCase(expectedKey: "rev-pdf|page:2|box:11,22,33,44", resolvedKey: "rev-pdf|page:2|box:11,22,33,44"),
            LocatorRoundTripBenchmarkCase(expectedKey: "rev-sheet|Sheet2!C7:E9", resolvedKey: "rev-sheet|Sheet2!C7:E9"),
            LocatorRoundTripBenchmarkCase(expectedKey: "rev-email|part:1.2", resolvedKey: "rev-email|part:1.2"),
        ]
        let observation = try XCTUnwrap(LocatorRoundTripBenchmark.observations(cases: cases).first)

        XCTAssertEqual(observation.metricID, "B-LOC-01")
        XCTAssertEqual(observation.name, "resolution_accuracy")
        XCTAssertEqual(observation.result.numerator, 4)
        XCTAssertEqual(observation.result.denominator, 4)
        XCTAssertEqual(observation.result.value, 1)
    }
}
