import Foundation

public struct DocumentRelationBenchmarkKey: Codable, Equatable, Sendable {
    public var fromFilename: String
    public var toFilename: String
    public var kind: String
    public var symmetric: Bool

    public init(
        fromFilename: String,
        toFilename: String,
        kind: String,
        symmetric: Bool
    ) {
        self.fromFilename = fromFilename
        self.toFilename = toFilename
        self.kind = kind
        self.symmetric = symmetric
    }

    public var canonicalID: String {
        if symmetric {
            let pair = [fromFilename, toFilename].sorted()
            return "\(kind)|\(pair[0])|\(pair[1])"
        }
        return "\(kind)|\(fromFilename)->\(toFilename)"
    }
}

public struct DocumentRelationBenchmarkKeys: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var relations: [DocumentRelationBenchmarkKey]
    public var operativeStates: [DocumentOperativeStateBenchmarkKey]
    public var ambiguousFamilies: [DocumentAmbiguousRelationBenchmarkKey]

    public init(
        schemaVersion: Int,
        relations: [DocumentRelationBenchmarkKey],
        operativeStates: [DocumentOperativeStateBenchmarkKey] = [],
        ambiguousFamilies: [DocumentAmbiguousRelationBenchmarkKey] = []
    ) {
        self.schemaVersion = schemaVersion
        self.relations = relations
        self.operativeStates = operativeStates
        self.ambiguousFamilies = ambiguousFamilies
    }
}

public struct DocumentOperativeStateBenchmarkKey: Codable, Equatable, Hashable, Sendable {
    public var filename: String
    public var state: String

    public init(filename: String, state: String) {
        self.filename = filename
        self.state = state
    }
}

public struct DocumentAmbiguousRelationBenchmarkKey: Codable, Equatable, Sendable {
    public var id: String
    public var fromFilename: String
    public var toFilename: String
    public var kind: String

    public init(id: String, fromFilename: String, toFilename: String, kind: String) {
        self.id = id
        self.fromFilename = fromFilename
        self.toFilename = toFilename
        self.kind = kind
    }
}

public enum DocumentRelationBenchmark {
    public static func observations(
        expected: [DocumentRelationBenchmarkKey],
        predicted: [DocumentRelationBenchmarkKey]
    ) -> [BenchmarkObservation] {
        var observations = score(
            namePrefix: "",
            expected: expected,
            predicted: predicted
        )
        let kinds = Set(expected.map(\.kind)).union(predicted.map(\.kind)).sorted()
        for kind in kinds {
            observations.append(contentsOf: score(
                namePrefix: "\(kind)_",
                expected: expected.filter { $0.kind == kind },
                predicted: predicted.filter { $0.kind == kind }
            ))
        }
        return observations
    }

    private static func score(
        namePrefix: String,
        expected: [DocumentRelationBenchmarkKey],
        predicted: [DocumentRelationBenchmarkKey]
    ) -> [BenchmarkObservation] {
        let result = BenchmarkMetrics.setScore(
            expected: Set(expected.map(\.canonicalID)),
            predicted: predicted.map(\.canonicalID)
        )
        return [
            BenchmarkObservation(
                metricID: "B-VER-01",
                name: "\(namePrefix)precision",
                unit: "rate",
                result: result.precision
            ),
            BenchmarkObservation(
                metricID: "B-VER-01",
                name: "\(namePrefix)recall",
                unit: "rate",
                result: result.recall
            ),
            BenchmarkObservation(
                metricID: "B-VER-01",
                name: "\(namePrefix)f1",
                unit: "rate",
                result: result.f1
            ),
        ]
    }
}

public enum DocumentRelationReviewBenchmark {
    public static func observations(
        expectedOperativeStates: [DocumentOperativeStateBenchmarkKey],
        predictedOperativeStates: [DocumentOperativeStateBenchmarkKey],
        expectedAmbiguousFamilyIDs: Set<String>,
        blockedAmbiguousFamilyIDs: Set<String>
    ) -> [BenchmarkObservation] {
        let predictedByFilename = Dictionary(
            predictedOperativeStates.map { ($0.filename, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        let correctOperativeStates = expectedOperativeStates.count { expected in
            predictedByFilename[expected.filename] == expected.state
        }
        let blockedAmbiguousFamilies = expectedAmbiguousFamilyIDs
            .intersection(blockedAmbiguousFamilyIDs)
            .count

        return [
            BenchmarkObservation(
                metricID: "B-VER-02",
                name: "operative_state_accuracy",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: correctOperativeStates,
                    denominator: expectedOperativeStates.count,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-VER-02",
                name: "ambiguous_block_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: blockedAmbiguousFamilies,
                    denominator: expectedAmbiguousFamilyIDs.count,
                    interval: .none
                )
            ),
        ]
    }
}
