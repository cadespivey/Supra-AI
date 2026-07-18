import Foundation

public struct TypedStructureEvidenceCandidate: Equatable, Sendable {
    public var documentName: String
    public var unitKind: String?

    public init(documentName: String, unitKind: String?) {
        self.documentName = documentName
        self.unitKind = unitKind
    }
}

public struct TypedStructureEvidenceCase: Equatable, Sendable {
    public var expectedDocumentNames: [String]
    public var candidates: [TypedStructureEvidenceCandidate]

    public init(
        expectedDocumentNames: [String],
        candidates: [TypedStructureEvidenceCandidate]
    ) {
        self.expectedDocumentNames = expectedDocumentNames
        self.candidates = candidates
    }
}

public enum TypedStructureEvidenceBenchmark {
    public static func observation(
        cases: [TypedStructureEvidenceCase]
    ) -> BenchmarkObservation {
        var expectedCount = 0
        var typedEvidenceCount = 0
        for testCase in cases {
            let expected = Set(testCase.expectedDocumentNames)
            expectedCount += expected.count
            let typedDocuments: Set<String> = Set(testCase.candidates.compactMap { candidate -> String? in
                guard let unitKind = candidate.unitKind,
                      !unitKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return candidate.documentName
            })
            typedEvidenceCount += expected.intersection(typedDocuments).count
        }
        return BenchmarkObservation(
            metricID: "B-RET-02",
            name: "typed_structure_evidence_recall",
            unit: "rate",
            result: BenchmarkMetrics.rate(
                numerator: typedEvidenceCount,
                denominator: expectedCount,
                interval: .none
            )
        )
    }
}
