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

    public init(schemaVersion: Int, relations: [DocumentRelationBenchmarkKey]) {
        self.schemaVersion = schemaVersion
        self.relations = relations
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
