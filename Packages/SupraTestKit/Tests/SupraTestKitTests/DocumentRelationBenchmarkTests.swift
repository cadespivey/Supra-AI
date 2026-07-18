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

    func testBVER02ScoresReviewedOperativeStatesAndRequiredAmbiguousBlockers() throws {
        // B-VER-02 expected RED: the harness cannot score confirmed operative
        // states or prove that every keyed ambiguous family blocks a clean result.
        let expected = [
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-draft.docx",
                state: "draft"
            ),
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-executed.docx",
                state: "operative"
            ),
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-superseded.docx",
                state: "superseded"
            ),
        ]
        let predicted = [
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-draft.docx",
                state: "draft"
            ),
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-executed.docx",
                state: "operative"
            ),
            DocumentOperativeStateBenchmarkKey(
                filename: "atlas-superseded.docx",
                state: "operative"
            ),
        ]

        let observations = DocumentRelationReviewBenchmark.observations(
            expectedOperativeStates: expected,
            predictedOperativeStates: predicted,
            expectedAmbiguousFamilyIDs: ["missing-date-amendment", "conflicting-executed-copies"],
            blockedAmbiguousFamilyIDs: ["missing-date-amendment"]
        )
        let byName = Dictionary(uniqueKeysWithValues: observations.map { ($0.name, $0.result) })
        XCTAssertEqual(try measured(byName["operative_state_accuracy"]), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measured(byName["ambiguous_block_rate"]), 0.5, accuracy: 0.000_001)
        XCTAssertTrue(observations.allSatisfy { $0.metricID == "B-VER-02" })
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
