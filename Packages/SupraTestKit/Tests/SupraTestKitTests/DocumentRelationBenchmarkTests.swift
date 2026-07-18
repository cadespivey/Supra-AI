import XCTest
@testable import SupraTestKit

final class DocumentRelationBenchmarkTests: XCTestCase {
    func testBVER01ScoresCanonicalDirectedAndSymmetricRelationKeysByKind() throws {
        // Expected RED: the benchmark harness cannot score relation proposals.
        let expected = [
            DocumentRelationBenchmarkKey(
                fromFilename: "executed-copy.docx",
                toFilename: "executed.docx",
                kind: "exact_duplicate",
                symmetric: true
            ),
            DocumentRelationBenchmarkKey(
                fromFilename: "draft.docx",
                toFilename: "executed.docx",
                kind: "draft_of",
                symmetric: false
            ),
        ]
        let predicted = [
            DocumentRelationBenchmarkKey(
                fromFilename: "executed.docx",
                toFilename: "executed-copy.docx",
                kind: "exact_duplicate",
                symmetric: true
            ),
            DocumentRelationBenchmarkKey(
                fromFilename: "draft.docx",
                toFilename: "executed.docx",
                kind: "draft_of",
                symmetric: false
            ),
            DocumentRelationBenchmarkKey(
                fromFilename: "draft.docx",
                toFilename: "unrelated.docx",
                kind: "near_duplicate",
                symmetric: true
            ),
        ]

        let observations = DocumentRelationBenchmark.observations(
            expected: expected,
            predicted: predicted
        )
        let byName = Dictionary(uniqueKeysWithValues: observations.map { ($0.name, $0.result) })
        XCTAssertEqual(try measured(byName["precision"]), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["recall"]), 1, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["f1"]), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["exact_duplicate_f1"]), 1, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["draft_of_f1"]), 1, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["near_duplicate_precision"]), 0, accuracy: 0.000_001)
        XCTAssertEqual(byName["near_duplicate_recall"]?.status, .notApplicable)
        XCTAssertTrue(observations.allSatisfy { $0.metricID == "B-VER-01" })
    }

    private func measured(
        _ result: BenchmarkResult?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        let result = try XCTUnwrap(result, file: file, line: line)
        XCTAssertEqual(result.status, .measured, file: file, line: line)
        return try XCTUnwrap(result.value, file: file, line: line)
    }
}
