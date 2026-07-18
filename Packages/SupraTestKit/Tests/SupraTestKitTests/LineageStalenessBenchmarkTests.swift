@testable import SupraTestKit
import XCTest

final class LineageStalenessBenchmarkTests: XCTestCase {
    func testBLIN01ReportsExactRecallAndPrecisionFromDependencyMatrix() throws {
        // B-LIN-01 expected RED: the benchmark catalog still emits unavailable
        // because no lineage dependency-matrix observation builder exists.
        let required = Set([
            "source-edit", "model-revision", "chunker", "prompt", "relation",
        ])
        let exact = LineageStalenessBenchmark.observations(
            expectedStaleKeys: required,
            actualStaleKeys: required
        )
        XCTAssertEqual(exact.map(\.metricID), ["B-LIN-01", "B-LIN-01"])
        XCTAssertEqual(exact.map(\.name), ["stale_detection_precision", "stale_detection_recall"])
        XCTAssertEqual(exact.compactMap(\.result.value), [1.0, 1.0])

        let imperfect = LineageStalenessBenchmark.observations(
            expectedStaleKeys: required,
            actualStaleKeys: ["source-edit", "model-revision", "false-positive"]
        )
        XCTAssertEqual(imperfect[0].result.numerator, 2)
        XCTAssertEqual(imperfect[0].result.denominator, 3)
        XCTAssertEqual(imperfect[1].result.numerator, 2)
        XCTAssertEqual(imperfect[1].result.denominator, 5)
    }
}
