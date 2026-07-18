import SupraTestKit
import XCTest

final class ContextPackingBenchmarkTests: XCTestCase {
    func testBCTXMetricsAccountForUtilizationEstimateOmissionAndOverflowRecovery() throws {
        // B-CTX-01/B-CTX-02 expected RED: the benchmark catalog has no scorer
        // that converts packing and overflow outcomes into the required metrics.
        let observations = ContextPackingBenchmark.observations(samples: [
            ContextPackingBenchmarkSample(
                usableInputTokens: 100,
                exactPackedTokens: 80,
                fallbackEstimatedTokens: 96,
                consideredResponsiveCandidates: 4,
                omittedResponsiveCandidates: 1,
                overflowAttempts: 1,
                recoveredOverflows: 1,
                silentOverflows: 0
            ),
            ContextPackingBenchmarkSample(
                usableInputTokens: 100,
                exactPackedTokens: 60,
                fallbackEstimatedTokens: 72,
                consideredResponsiveCandidates: 2,
                omittedResponsiveCandidates: 0,
                overflowAttempts: 0,
                recoveredOverflows: 0,
                silentOverflows: 0
            ),
        ])

        XCTAssertEqual(try value("B-CTX-01", "context_utilization", in: observations), 0.7, accuracy: 0.000_001)
        XCTAssertEqual(try value("B-CTX-01", "fallback_estimate_error", in: observations), 0.2, accuracy: 0.000_001)
        XCTAssertEqual(
            try value("B-CTX-02", "responsive_candidate_omission_rate", in: observations),
            1.0 / 6.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(try value("B-CTX-02", "overflow_recovery_rate", in: observations), 1)
        XCTAssertEqual(try value("B-CTX-02", "silent_overflow_count", in: observations), 0)
    }

    private func value(
        _ metricID: String,
        _ name: String,
        in observations: [BenchmarkObservation]
    ) throws -> Double {
        let observation = try XCTUnwrap(observations.first {
            $0.metricID == metricID && $0.name == name
        })
        XCTAssertEqual(observation.result.status, .measured)
        return try XCTUnwrap(observation.result.value)
    }
}
