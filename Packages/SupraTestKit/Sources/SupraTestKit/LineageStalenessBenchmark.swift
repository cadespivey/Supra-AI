public enum LineageStalenessBenchmark {
    public static func observations(
        expectedStaleKeys: Set<String>,
        actualStaleKeys: Set<String>
    ) -> [BenchmarkObservation] {
        let truePositive = expectedStaleKeys.intersection(actualStaleKeys).count
        return [
            BenchmarkObservation(
                metricID: "B-LIN-01",
                name: "stale_detection_precision",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: truePositive,
                    denominator: actualStaleKeys.count,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-LIN-01",
                name: "stale_detection_recall",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: truePositive,
                    denominator: expectedStaleKeys.count,
                    interval: .none
                )
            ),
        ]
    }
}
