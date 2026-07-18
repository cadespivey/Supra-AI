import CryptoKit
import Foundation
@testable import SupraTestKit
import XCTest

/// T-BEN-05 freezes the first honest benchmark baseline and its still-pending
/// threshold decisions. It fails closed on harness, fixture, schema, or catalog
/// drift rather than silently comparing unlike reports.
final class BenchmarkBaselineContractTests: XCTestCase {
    private struct ThresholdManifest: Decodable {
        var schemaVersion: Int
        var baselinePath: String
        var harnessSHA256: String
        var decisions: [ThresholdDecision]
    }

    private struct ThresholdDecision: Decodable {
        var metricID: String
        var owner: String
        var approvalStatus: String
        var proposal: String
    }

    private struct OCRSelectionKeys: Decodable {
        struct Candidate: Decodable {
            var id: String
            var origin: String
            var text: String
            var confidence: Double?
            var boundingBoxesJSON: String?
        }

        struct Case: Decodable {
            var id: String
            var embedded: Candidate
            var ocr: Candidate
            var expectedSelectedOrigin: String
            var expectedNeedsReview: Bool
        }

        var schemaVersion: Int
        var syntheticDataDeclaration: String
        var cases: [Case]
    }

    func testFrozenBaselineMatchesCurrentHarnessFixturesAndThresholdLedger() throws {
        // T-BEN-05 expected RED: TestData/Benchmarks and its frozen baseline /
        // threshold-proposal manifest do not exist yet.
        let root = repoRoot()
        let proposalURL = root.appendingPathComponent("TestData/Benchmarks/threshold-proposals.json")
        let proposalData = try Data(contentsOf: proposalURL)
        let proposals = try JSONDecoder().decode(ThresholdManifest.self, from: proposalData)
        XCTAssertEqual(proposals.schemaVersion, 1)

        let baselineURL = root.appendingPathComponent(proposals.baselinePath)
        let baseline = try JSONDecoder().decode(BenchmarkReport.self, from: Data(contentsOf: baselineURL))
        XCTAssertEqual(baseline.schemaVersion, 1)
        XCTAssertEqual(
            proposals.baselinePath,
            "TestData/Benchmarks/baseline-\(baseline.run.repositorySHA).json",
            "the immutable source SHA must name its baseline"
        )
        XCTAssertEqual(baseline.run.repositorySHA.count, 40)
        XCTAssertTrue(baseline.run.repositorySHA.allSatisfy { $0.isHexDigit })

        let manifestData = try Data(contentsOf: root.appendingPathComponent("TestData/benchmark-manifest.json"))
        XCTAssertEqual(baseline.run.corpusManifestSHA256, Self.sha256(manifestData))
        XCTAssertEqual(proposals.harnessSHA256, try harnessDigest(root: root))

        let expectedMetricIDs = BenchmarkMetricCatalog.all.map(\.id)
        XCTAssertEqual(baseline.metrics.map(\.id), expectedMetricIDs)
        XCTAssertEqual(Set(proposals.decisions.map(\.metricID)), Set(expectedMetricIDs))
        XCTAssertEqual(Set(proposals.decisions.map(\.metricID)).count, proposals.decisions.count)
        for decision in proposals.decisions {
            XCTAssertEqual(decision.owner, "repo_owner")
            XCTAssertEqual(decision.approvalStatus, "pending_owner_approval")
            XCTAssertFalse(decision.proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        for row in baseline.metrics {
            XCTAssertFalse(row.measurements.isEmpty, "\(row.id) must emit a measurement or explicit n/a")
            for measurement in row.measurements {
                switch measurement.status {
                case .measured:
                    let value = try XCTUnwrap(measurement.value, "\(row.id)/\(measurement.name) missing measured value")
                    XCTAssertTrue(value.isFinite)
                case .notApplicable:
                    XCTAssertNil(measurement.value)
                    let reason = try XCTUnwrap(measurement.reason, "\(row.id) n/a row needs a reason")
                    XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }

        XCTAssertEqual(try measuredValue("B-ACC-01", "source_accounting_accuracy", in: baseline), 1)
        XCTAssertEqual(try measuredValue("B-ACC-01", "source_balance_error_count", in: baseline), 0)
        XCTAssertEqual(try measuredValue("B-ISO-01", "cross_matter_leak_count", in: baseline), 0)
        XCTAssertEqual(try measuredValue("B-REC-01", "successful_recovery_rate", in: baseline), 1)
        XCTAssertEqual(try measuredValue("B-REC-01", "duplicate_work_rate", in: baseline), 0)
        let successfulRecovery = try measurement("B-REC-01", "successful_recovery_rate", in: baseline)
        XCTAssertEqual(successfulRecovery.numerator, 5, "B-REC-01 must include three import and two corpus cases")
        XCTAssertEqual(successfulRecovery.denominator, 5)
        let duplicateWork = try measurement("B-REC-01", "duplicate_work_rate", in: baseline)
        XCTAssertEqual(duplicateWork.numerator, 0)
        XCTAssertEqual(duplicateWork.denominator, 3, "one import and two corpus checkpoints are replay probes")

        XCTAssertEqual(try measuredValue("B-LST-01", "item_recall", in: baseline), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measuredValue("B-LST-01", "item_precision", in: baseline), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measuredValue("B-LST-01", "item_f1", in: baseline), 2.0 / 3.0, accuracy: 0.000_001)
        let duplicateListItems = try measurement("B-LST-01", "duplicate_output_rate", in: baseline)
        XCTAssertEqual(duplicateListItems.numerator, 1)
        XCTAssertEqual(duplicateListItems.denominator, 5)

        let falseCompleteness = try measurement("B-CMP-01", "completeness_false_claim_rate", in: baseline)
        XCTAssertEqual(falseCompleteness.value, 0)
        XCTAssertEqual(falseCompleteness.numerator, 0)
        XCTAssertEqual(falseCompleteness.denominator, 3)
        let falseNegatives = try measurement("B-NEG-01", "negative_false_accept_rate", in: baseline)
        XCTAssertEqual(falseNegatives.value, 0)
        XCTAssertEqual(falseNegatives.numerator, 0)
        XCTAssertEqual(falseNegatives.denominator, 2)

        XCTAssertEqual(try measuredValue("B-VER-01", "precision", in: baseline), 1)
        XCTAssertEqual(try measuredValue("B-VER-01", "recall", in: baseline), 1)
        XCTAssertEqual(try measuredValue("B-VER-01", "f1", in: baseline), 1)
        let operativeAccuracy = try measurement("B-VER-02", "operative_state_accuracy", in: baseline)
        XCTAssertEqual(operativeAccuracy.value, 1)
        XCTAssertEqual(operativeAccuracy.numerator, 3)
        XCTAssertEqual(operativeAccuracy.denominator, 3)
        let ambiguousBlockRate = try measurement("B-VER-02", "ambiguous_block_rate", in: baseline)
        XCTAssertEqual(ambiguousBlockRate.value, 1)
        XCTAssertEqual(ambiguousBlockRate.numerator, 1)
        XCTAssertEqual(ambiguousBlockRate.denominator, 1)

        // B-OCR-01/B-OCR-02 expected RED: the frozen M2 baseline still reports
        // both metrics n/a because policy-v1 benchmark observations do not exist.
        XCTAssertEqual(try measuredValue("B-OCR-01", "selection_accuracy", in: baseline), 1)
        XCTAssertEqual(try measuredValue("B-OCR-02", "false_clean_count", in: baseline), 0)
        XCTAssertGreaterThanOrEqual(try measuredValue("B-OCR-02", "brier_score", in: baseline), 0)
        XCTAssertLessThanOrEqual(try measuredValue("B-OCR-02", "brier_score", in: baseline), 1)
        XCTAssertGreaterThanOrEqual(try measuredValue("B-OCR-02", "expected_calibration_error", in: baseline), 0)
        XCTAssertLessThanOrEqual(try measuredValue("B-OCR-02", "expected_calibration_error", in: baseline), 1)
    }

    func testBOCRKeysAreSyntheticCompleteAndExerciseBothOutcomes() throws {
        let keyURL = repoRoot().appendingPathComponent("TestData/Benchmarks/ocr-selection-keys.json")
        let keys = try JSONDecoder().decode(OCRSelectionKeys.self, from: Data(contentsOf: keyURL))

        XCTAssertEqual(keys.schemaVersion, 1)
        XCTAssertTrue(keys.syntheticDataDeclaration.lowercased().contains("synthetic"))
        XCTAssertGreaterThanOrEqual(keys.cases.count, 4)
        XCTAssertEqual(Set(keys.cases.map(\.id)).count, keys.cases.count)
        XCTAssertEqual(Set(keys.cases.map(\.expectedSelectedOrigin)), ["embedded_pdf", "ocr"])
        XCTAssertTrue(keys.cases.contains { $0.expectedNeedsReview })
        XCTAssertTrue(keys.cases.contains { !$0.expectedNeedsReview })
        for key in keys.cases {
            XCTAssertEqual(key.embedded.origin, "embedded_pdf")
            XCTAssertEqual(key.ocr.origin, "ocr")
            XCTAssertFalse(key.embedded.text.isEmpty)
            XCTAssertFalse(key.ocr.text.isEmpty)
            XCTAssertNotNil(key.ocr.confidence)
            XCTAssertNotNil(key.ocr.boundingBoxesJSON)
        }
    }

    private func measuredValue(_ metricID: String, _ name: String, in report: BenchmarkReport) throws -> Double {
        let measurement = try measurement(metricID, name, in: report)
        XCTAssertEqual(measurement.status, .measured)
        return try XCTUnwrap(measurement.value)
    }

    private func measurement(
        _ metricID: String,
        _ name: String,
        in report: BenchmarkReport
    ) throws -> BenchmarkMeasurement {
        let row = try XCTUnwrap(report.metrics.first { $0.id == metricID })
        return try XCTUnwrap(row.measurements.first { $0.name == name })
    }

    private func harnessDigest(root: URL) throws -> String {
        let paths = [
            "Packages/SupraTestKit/Package.swift",
            "Packages/SupraTestKit/Sources/SupraBench/main.swift",
            "Packages/SupraTestKit/Sources/SupraTestKit/DocumentRelationBenchmark.swift",
            "Packages/SupraTestKit/Sources/SupraTestKit/BenchmarkMetrics.swift",
            "Packages/SupraTestKit/Sources/SupraTestKit/BenchmarkReport.swift",
            "TestData/Benchmarks/document-relation-keys.json",
        ]
        var bytes = Data()
        for path in paths.sorted() {
            bytes.append(Data(path.utf8))
            bytes.append(0)
            bytes.append(try Data(contentsOf: root.appendingPathComponent(path)))
            bytes.append(0)
        }
        return Self.sha256(bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}
