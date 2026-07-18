import Foundation

public struct ClassificationBenchmarkCase: Equatable, Sendable {
    public var expectedCategory: String
    public var predictedCategory: String?
    public var shouldAbstain: Bool
    public var didAbstain: Bool
    public var emittedEvidenceSpanCount: Int
    public var validEvidenceSpanCount: Int

    public init(
        expectedCategory: String,
        predictedCategory: String?,
        shouldAbstain: Bool,
        didAbstain: Bool,
        emittedEvidenceSpanCount: Int,
        validEvidenceSpanCount: Int
    ) {
        precondition(emittedEvidenceSpanCount >= 0)
        precondition(validEvidenceSpanCount >= 0 && validEvidenceSpanCount <= emittedEvidenceSpanCount)
        self.expectedCategory = expectedCategory
        self.predictedCategory = predictedCategory
        self.shouldAbstain = shouldAbstain
        self.didAbstain = didAbstain
        self.emittedEvidenceSpanCount = emittedEvidenceSpanCount
        self.validEvidenceSpanCount = validEvidenceSpanCount
    }
}

public enum ClassificationBenchmark {
    /// Reports macro F1/per-class recall only over classifiable cases. Abstention
    /// quality is scored separately so a correct safety decision is never counted
    /// as a category miss, while an unjustified abstention remains observable.
    public static func observations(cases: [ClassificationBenchmarkCase]) -> [BenchmarkObservation] {
        let classifiable = cases.filter { !$0.shouldAbstain }
        let categories = Set(classifiable.map(\.expectedCategory)).sorted()
        var f1Values: [Double] = []
        var categoryObservations: [BenchmarkObservation] = []
        for category in categories {
            let expectedPositive = classifiable.map { $0.expectedCategory == category }
            let predictedPositive = classifiable.map { !$0.didAbstain && $0.predictedCategory == category }
            let score = BenchmarkMetrics.binaryScore(
                expectedPositive: expectedPositive,
                predictedPositive: predictedPositive
            )
            if let value = score.f1.value { f1Values.append(value) }
            categoryObservations.append(BenchmarkObservation(
                metricID: "B-CLS-01",
                name: "recall_\(category)",
                unit: "rate",
                result: score.recall
            ))
        }
        let macroF1: BenchmarkResult = f1Values.isEmpty
            ? .notApplicable("no classifiable category observations")
            : .measured(value: f1Values.reduce(0, +) / Double(f1Values.count))

        let abstention = BenchmarkMetrics.binaryScore(
            expectedPositive: cases.map(\.shouldAbstain),
            predictedPositive: cases.map(\.didAbstain)
        )
        let emittedEvidence = cases.reduce(0) { $0 + $1.emittedEvidenceSpanCount }
        let validEvidence = cases.reduce(0) { $0 + $1.validEvidenceSpanCount }

        return [
            BenchmarkObservation(
                metricID: "B-CLS-01",
                name: "macro_f1",
                unit: "rate",
                result: macroF1
            ),
        ] + categoryObservations + [
            BenchmarkObservation(
                metricID: "B-CLS-02",
                name: "abstention_precision",
                unit: "rate",
                result: abstention.precision
            ),
            BenchmarkObservation(
                metricID: "B-CLS-02",
                name: "abstention_recall",
                unit: "rate",
                result: abstention.recall
            ),
            BenchmarkObservation(
                metricID: "B-CLS-02",
                name: "evidence_validity_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: validEvidence,
                    denominator: emittedEvidence
                )
            ),
        ]
    }
}
