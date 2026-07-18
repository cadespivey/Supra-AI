import Foundation

/// One auditable packet-packing outcome for B-CTX-01/B-CTX-02. Exact token
/// counts come from the loaded runtime tokenizer in protected T3/T4 runs; the
/// deterministic companion supplies a frozen exact-count matrix.
public struct ContextPackingBenchmarkSample: Equatable, Sendable {
    public var usableInputTokens: Int
    public var exactPackedTokens: Int
    public var fallbackEstimatedTokens: Int
    public var consideredResponsiveCandidates: Int
    public var omittedResponsiveCandidates: Int
    public var overflowAttempts: Int
    public var recoveredOverflows: Int
    public var silentOverflows: Int

    public init(
        usableInputTokens: Int,
        exactPackedTokens: Int,
        fallbackEstimatedTokens: Int,
        consideredResponsiveCandidates: Int,
        omittedResponsiveCandidates: Int,
        overflowAttempts: Int,
        recoveredOverflows: Int,
        silentOverflows: Int
    ) {
        precondition(usableInputTokens >= 0)
        precondition(exactPackedTokens >= 0)
        precondition(fallbackEstimatedTokens >= 0)
        precondition(consideredResponsiveCandidates >= 0)
        precondition((0...consideredResponsiveCandidates).contains(omittedResponsiveCandidates))
        precondition(overflowAttempts >= 0)
        precondition((0...overflowAttempts).contains(recoveredOverflows))
        precondition((0...overflowAttempts).contains(silentOverflows))
        self.usableInputTokens = usableInputTokens
        self.exactPackedTokens = exactPackedTokens
        self.fallbackEstimatedTokens = fallbackEstimatedTokens
        self.consideredResponsiveCandidates = consideredResponsiveCandidates
        self.omittedResponsiveCandidates = omittedResponsiveCandidates
        self.overflowAttempts = overflowAttempts
        self.recoveredOverflows = recoveredOverflows
        self.silentOverflows = silentOverflows
    }
}

public enum ContextPackingBenchmark {
    public static func observations(
        samples: [ContextPackingBenchmarkSample]
    ) -> [BenchmarkObservation] {
        let usableTokens = samples.reduce(0) { $0 + $1.usableInputTokens }
        let exactTokens = samples.reduce(0) { $0 + $1.exactPackedTokens }
        let estimateErrorTokens = samples.reduce(0) {
            $0 + abs($1.fallbackEstimatedTokens - $1.exactPackedTokens)
        }
        let consideredCandidates = samples.reduce(0) { $0 + $1.consideredResponsiveCandidates }
        let omittedCandidates = samples.reduce(0) { $0 + $1.omittedResponsiveCandidates }
        let overflowAttempts = samples.reduce(0) { $0 + $1.overflowAttempts }
        let recoveredOverflows = samples.reduce(0) { $0 + $1.recoveredOverflows }
        let silentOverflows = samples.reduce(0) { $0 + $1.silentOverflows }

        return [
            BenchmarkObservation(
                metricID: "B-CTX-01",
                name: "context_utilization",
                unit: "rate",
                result: ratio(numerator: exactTokens, denominator: usableTokens)
            ),
            BenchmarkObservation(
                metricID: "B-CTX-01",
                name: "fallback_estimate_error",
                unit: "rate",
                result: ratio(numerator: estimateErrorTokens, denominator: exactTokens)
            ),
            BenchmarkObservation(
                metricID: "B-CTX-02",
                name: "responsive_candidate_omission_rate",
                unit: "rate",
                result: ratio(numerator: omittedCandidates, denominator: consideredCandidates)
            ),
            BenchmarkObservation(
                metricID: "B-CTX-02",
                name: "overflow_recovery_rate",
                unit: "rate",
                result: ratio(numerator: recoveredOverflows, denominator: overflowAttempts)
            ),
            BenchmarkObservation(
                metricID: "B-CTX-02",
                name: "silent_overflow_count",
                unit: "count",
                result: .measured(
                    value: Double(silentOverflows),
                    numerator: silentOverflows,
                    denominator: overflowAttempts
                )
            ),
        ]
    }

    private static func ratio(numerator: Int, denominator: Int) -> BenchmarkResult {
        guard denominator > 0 else { return .notApplicable("zero denominator") }
        return .measured(
            value: Double(numerator) / Double(denominator),
            numerator: numerator,
            denominator: denominator
        )
    }
}
