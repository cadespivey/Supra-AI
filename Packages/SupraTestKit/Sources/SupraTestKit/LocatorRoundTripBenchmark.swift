public struct LocatorRoundTripBenchmarkCase: Equatable, Sendable {
    public var expectedKey: String
    public var resolvedKey: String?

    public init(expectedKey: String, resolvedKey: String?) {
        self.expectedKey = expectedKey
        self.resolvedKey = resolvedKey
    }
}

public enum LocatorRoundTripBenchmark {
    public static func observations(
        cases: [LocatorRoundTripBenchmarkCase]
    ) -> [BenchmarkObservation] {
        let exact = cases.count { $0.resolvedKey == $0.expectedKey }
        return [BenchmarkObservation(
            metricID: "B-LOC-01",
            name: "resolution_accuracy",
            unit: "rate",
            result: BenchmarkMetrics.rate(
                numerator: exact,
                denominator: cases.count,
                interval: .none
            )
        )]
    }
}
