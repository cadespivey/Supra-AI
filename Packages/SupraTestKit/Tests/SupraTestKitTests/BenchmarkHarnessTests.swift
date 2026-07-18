import Foundation
@testable import SupraTestKit
import XCTest

/// T-BEN-03/T-BEN-04 freeze the benchmark report and formula contracts before
/// the runner or metric calculators exist.
final class BenchmarkHarnessTests: XCTestCase {
    func testMetricFormulasHandleFalseResultsDuplicatesAndZeroDenominators() throws {
        // T-BEN-04 expected RED: BenchmarkMetrics and its result types are absent.
        let score = BenchmarkMetrics.setScore(
            expected: Set(["a", "b", "c"]),
            predicted: ["a", "a", "x"]
        )

        XCTAssertEqual(try measured(score.precision), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try measured(score.recall), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measured(score.f1), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(try measured(score.duplicateRate), 1.0 / 3.0, accuracy: 0.000_001)

        let empty = BenchmarkMetrics.setScore(expected: Set<String>(), predicted: [])
        XCTAssertEqual(empty.precision.status, .notApplicable)
        XCTAssertEqual(empty.recall.status, .notApplicable)
        XCTAssertEqual(empty.f1.status, .notApplicable)
        XCTAssertNil(empty.precision.value, "zero-denominator precision must not silently become 100%")
        XCTAssertNil(empty.recall.value, "zero-denominator recall must not silently become 100%")

        let cer = BenchmarkMetrics.characterErrorRate(expected: "kitten", predicted: "sitting")
        XCTAssertEqual(try measured(cer), 0.5, accuracy: 0.000_001)

        let rate = BenchmarkMetrics.rate(numerator: 3, denominator: 4, interval: .wilson95)
        XCTAssertEqual(try measured(rate), 0.75, accuracy: 0.000_001)
        let interval = try XCTUnwrap(rate.confidenceInterval)
        XCTAssertEqual(interval.method, "wilson_95")
        XCTAssertLessThan(interval.lower, 0.75)
        XCTAssertGreaterThan(interval.upper, 0.75)
        XCTAssertEqual(
            interval,
            try XCTUnwrap(BenchmarkMetrics.rate(numerator: 3, denominator: 4, interval: .wilson95).confidenceInterval),
            "the confidence-interval rule must be deterministic"
        )
    }

    func testMetricsHandleAbstentionTiesAndFailedPartitions() throws {
        // T-BEN-04 expected RED: the hand-computable classification, ranking,
        // and completeness helpers are absent.
        let abstention = BenchmarkMetrics.binaryScore(
            expectedPositive: [true, false, true],
            predictedPositive: [true, true, false]
        )
        XCTAssertEqual(try measured(abstention.precision), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try measured(abstention.recall), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try measured(abstention.f1), 0.5, accuracy: 0.000_001)

        let tied = [
            BenchmarkRankedItem(id: "b", score: 1),
            BenchmarkRankedItem(id: "a", score: 1),
        ]
        XCTAssertEqual(
            try measured(BenchmarkMetrics.rankingRecall(relevant: Set(["b"]), ranked: tied, k: 1)),
            0,
            accuracy: 0.000_001,
            "score ties must use stable ID order, not caller order"
        )
        XCTAssertEqual(
            try measured(BenchmarkMetrics.rankingRecall(relevant: Set(["b"]), ranked: tied, k: 2)),
            1,
            accuracy: 0.000_001
        )

        let falseClaim = BenchmarkMetrics.completenessFalseClaimRate([
            BenchmarkCompletenessObservation(partitionStates: [.succeeded, .failed], claimsComplete: true),
            BenchmarkCompletenessObservation(partitionStates: [.succeeded, .cancelled], claimsComplete: false),
            BenchmarkCompletenessObservation(partitionStates: [.succeeded, .succeeded], claimsComplete: true),
        ])
        XCTAssertEqual(try measured(falseClaim), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(falseClaim.numerator, 1)
        XCTAssertEqual(falseClaim.denominator, 2, "only incomplete runs belong in the false-claim denominator")

        let ordering = BenchmarkMetrics.orderingAccuracy(
            expectedOrder: ["a", "b", "c"],
            predictedOrder: ["b", "a", "c"]
        )
        XCTAssertEqual(try measured(ordering), 2.0 / 3.0, accuracy: 0.000_001)
    }

    func testBOCRCalibrationMetricsUsePairedProbabilitiesAndFixedBins() throws {
        // B-OCR-02 expected RED: the harness has no Brier-score or fixed-bin
        // expected-calibration-error formulas before OCR policy v1 emits keys.
        let probabilities = [0.9, 0.8, 0.2, 0.1]
        let outcomes = [true, true, false, true]

        XCTAssertEqual(
            try measured(BenchmarkMetrics.brierScore(probabilities: probabilities, outcomes: outcomes)),
            0.225,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try measured(BenchmarkMetrics.expectedCalibrationError(
                probabilities: probabilities,
                outcomes: outcomes,
                binCount: 2
            )),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BenchmarkMetrics.brierScore(probabilities: [], outcomes: []).status,
            .notApplicable
        )
        XCTAssertEqual(
            BenchmarkMetrics.expectedCalibrationError(probabilities: [], outcomes: [], binCount: 5).status,
            .notApplicable
        )
    }

    func testDeterministicRunnerProducesCanonicalCatalogOrderedJSON() async throws {
        // T-BEN-03 expected RED: BenchmarkRunner, canonical report encoding, and
        // the complete B-* catalog are absent.
        let observations = [
            BenchmarkObservation(
                metricID: "B-RET-01",
                name: "recall_at_8",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: 3, denominator: 4)
            ),
            BenchmarkObservation(
                metricID: "B-ACC-01",
                name: "source_accounting_accuracy",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: 4, denominator: 4)
            ),
        ]
        let firstRunner = BenchmarkRunner(
            repositorySHA: "fixture-sha",
            corpusManifestSHA256: "fixture-manifest-sha",
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            workload: { observations }
        )
        let secondRunner = BenchmarkRunner(
            repositorySHA: "fixture-sha",
            corpusManifestSHA256: "fixture-manifest-sha",
            clock: { Date(timeIntervalSince1970: 1_700_000_001) },
            workload: { observations }
        )

        let first = try await firstRunner.runDeterministic()
        let second = try await secondRunner.runDeterministic()
        let firstRaw = try first.canonicalJSON()
        let secondRaw = try second.canonicalJSON()
        XCTAssertNotEqual(firstRaw, secondRaw, "the two clocks must prove timestamp stripping is exercised")
        XCTAssertEqual(
            try first.canonicalJSON(strippingRunTimestamp: true),
            try second.canonicalJSON(strippingRunTimestamp: true)
        )

        let expectedIDs = [
            "B-ACC-01", "B-CHR-01", "B-CHR-02", "B-CLS-01", "B-CLS-02", "B-CMP-01",
            "B-CTX-01", "B-CTX-02", "B-EXT-01", "B-EXT-02", "B-ISO-01", "B-LIN-01",
            "B-LOC-01", "B-LST-01", "B-NEG-01", "B-OCR-01", "B-OCR-02", "B-PERF-01",
            "B-PERF-02", "B-PERF-03", "B-REC-01", "B-RET-01", "B-RET-02", "B-STR-01",
            "B-SUP-01", "B-TAB-01", "B-VER-01", "B-VER-02",
        ]
        XCTAssertEqual(first.metrics.map(\.id), expectedIDs)
        XCTAssertEqual(first.metrics.first(where: { $0.id == "B-ACC-01" })?.measurements.first?.status, .measured)
        XCTAssertEqual(first.metrics.first(where: { $0.id == "B-STR-01" })?.measurements.first?.status, .notApplicable)
    }

    private func measured(_ result: BenchmarkResult, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        XCTAssertEqual(result.status, .measured, file: file, line: line)
        return try XCTUnwrap(result.value, file: file, line: line)
    }
}
