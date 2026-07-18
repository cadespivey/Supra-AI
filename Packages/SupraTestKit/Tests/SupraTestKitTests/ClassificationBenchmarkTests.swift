@testable import SupraTestKit
import XCTest

final class ClassificationBenchmarkTests: XCTestCase {
    func testBCLS01And02ReportMacroRecallAbstentionAndEvidenceValidity() throws {
        // B-CLS-01/B-CLS-02 expected RED: the catalog still emits unavailable;
        // no classification observation calculator exists.
        let observations = ClassificationBenchmark.observations(cases: [
            .init(
                expectedCategory: "financial_records",
                predictedCategory: "financial_records",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 2,
                validEvidenceSpanCount: 2
            ),
            .init(
                expectedCategory: "correspondence",
                predictedCategory: nil,
                shouldAbstain: true,
                didAbstain: true,
                emittedEvidenceSpanCount: 0,
                validEvidenceSpanCount: 0
            ),
            .init(
                expectedCategory: "financial_records",
                predictedCategory: "correspondence",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 1,
                validEvidenceSpanCount: 0
            ),
            .init(
                expectedCategory: "correspondence",
                predictedCategory: "correspondence",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 1,
                validEvidenceSpanCount: 1
            ),
        ])

        XCTAssertEqual(observations.map(\.metricID), [
            "B-CLS-01", "B-CLS-01", "B-CLS-01", "B-CLS-02", "B-CLS-02", "B-CLS-02",
        ])
        XCTAssertEqual(observations.map(\.name), [
            "macro_f1", "recall_correspondence", "recall_financial_records",
            "abstention_precision", "abstention_recall", "evidence_validity_rate",
        ])
        XCTAssertEqual(observations[1].result.numerator, 1)
        XCTAssertEqual(observations[1].result.denominator, 1)
        XCTAssertEqual(observations[2].result.numerator, 1)
        XCTAssertEqual(observations[2].result.denominator, 2)
        XCTAssertEqual(observations[3].result.value, 1)
        XCTAssertEqual(observations[4].result.value, 1)
        XCTAssertEqual(observations[5].result.numerator, 3)
        XCTAssertEqual(observations[5].result.denominator, 4)
    }
}
