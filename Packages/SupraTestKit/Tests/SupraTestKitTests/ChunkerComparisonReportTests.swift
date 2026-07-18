import Foundation
@testable import SupraTestKit
import XCTest

final class ChunkerComparisonReportTests: XCTestCase {
    func testM5W3ComparisonReportsRecallLatencyAndDeferredListGateWithoutAutoApproval() async throws {
        // M5-W3 expected RED: no v1/v2 decision-report contract exists.
        let v1 = try await report(
            sha: "v1",
            observations: [
                rate("B-RET-01", "recall_at_8", 11, 17),
                rate("B-RET-01", "recall_at_12", 12, 17),
                rate("B-RET-01", "recall_at_40", 14, 17),
                rate("B-RET-02", "full_evidence_set_recall_at_40", 5, 8),
            ]
        )
        let v2 = try await report(
            sha: "v2",
            observations: [
                rate("B-RET-01", "recall_at_8", 12, 17),
                rate("B-RET-01", "recall_at_12", 13, 17),
                rate("B-RET-01", "recall_at_40", 15, 17),
                rate("B-RET-02", "full_evidence_set_recall_at_40", 6, 8),
            ]
        )

        let comparison = try ChunkerComparisonReport.make(
            repositorySHA: "decision-sha",
            corpusManifestSHA256: "fixture-sha",
            generatedAt: "2026-07-18T00:00:00Z",
            v1: v1,
            v2: v2,
            v1RetrievalSeconds: 1.0,
            v2RetrievalSeconds: 1.1
        )

        XCTAssertEqual(comparison.schemaVersion, 1)
        XCTAssertEqual(comparison.metrics.map { $0.name }, [
            "full_evidence_set_recall_at_40", "recall_at_12", "recall_at_40", "recall_at_8",
        ])
        XCTAssertTrue(comparison.metrics.allSatisfy { $0.v2Value >= $0.v1Value })
        XCTAssertEqual(comparison.retrievalLatency.ratio, 1.1, accuracy: 0.000_001)
        XCTAssertEqual(comparison.exhaustiveList.status, "deferred_until_m6")
        XCTAssertEqual(comparison.decision.status, "pending_owner_approval")
        XCTAssertEqual(comparison.decision.shippingDefault, 1)
        XCTAssertTrue(comparison.decision.reasons.contains("D-06 requires explicit repo-owner approval."))
    }

    func testM5W3ComparisonHoldsV1WhenAnyRecallMetricRegresses() async throws {
        // M5-W3 expected RED: no deterministic noninferiority decision exists.
        let v1 = try await report(sha: "v1", observations: [rate("B-RET-01", "recall_at_8", 8, 10)])
        let v2 = try await report(sha: "v2", observations: [rate("B-RET-01", "recall_at_8", 7, 10)])

        let comparison = try ChunkerComparisonReport.make(
            repositorySHA: "decision-sha",
            corpusManifestSHA256: "fixture-sha",
            generatedAt: nil,
            v1: v1,
            v2: v2,
            v1RetrievalSeconds: 1,
            v2RetrievalSeconds: 1
        )

        XCTAssertEqual(comparison.decision.status, "blocked_recall_regression")
        XCTAssertEqual(comparison.decision.shippingDefault, 1)
        XCTAssertTrue(comparison.metrics.first?.passesNoninferiority == false)
    }

    private func report(
        sha: String,
        observations: [BenchmarkObservation]
    ) async throws -> BenchmarkReport {
        try await BenchmarkRunner(
            repositorySHA: sha,
            corpusManifestSHA256: "fixture-sha",
            clock: { Date(timeIntervalSinceReferenceDate: 0) },
            workload: { observations }
        ).runDeterministic()
    }

    private func rate(_ metricID: String, _ name: String, _ numerator: Int, _ denominator: Int) -> BenchmarkObservation {
        BenchmarkObservation(
            metricID: metricID,
            name: name,
            unit: "rate",
            result: BenchmarkMetrics.rate(numerator: numerator, denominator: denominator, interval: .none)
        )
    }
}
