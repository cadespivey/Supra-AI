import SupraCore

public struct SupportBenchmarkCase: Equatable, Sendable {
    public var expectedSupported: Bool
    public var actualStatus: OutputVerificationStatus

    public init(expectedSupported: Bool, actualStatus: OutputVerificationStatus) {
        self.expectedSupported = expectedSupported
        self.actualStatus = actualStatus
    }
}

public enum SupportBenchmark {
    /// A false accept is an adversarial proposition expected to remain
    /// unsupported/unverifiable that the shipping verifier marks all-supported.
    /// The denominator intentionally excludes positive controls.
    public static func observations(cases: [SupportBenchmarkCase]) -> [BenchmarkObservation] {
        let adversarial = cases.filter { !$0.expectedSupported }
        let falseAccepts = adversarial.count { $0.actualStatus == .allSupported }
        return [BenchmarkObservation(
            metricID: "B-SUP-01",
            name: "support_false_accept_rate",
            unit: "rate",
            result: BenchmarkMetrics.rate(
                numerator: falseAccepts,
                denominator: adversarial.count,
                interval: .none
            )
        )]
    }
}
