import Foundation

public enum BenchmarkResultStatus: String, Codable, Sendable {
    case measured
    case notApplicable = "not_applicable"
}

public enum BenchmarkIntervalRule: Sendable {
    case none
    case wilson95
}

public struct BenchmarkConfidenceInterval: Codable, Equatable, Sendable {
    public var lower: Double
    public var upper: Double
    public var method: String

    public init(lower: Double, upper: Double, method: String) {
        self.lower = lower
        self.upper = upper
        self.method = method
    }
}

public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var status: BenchmarkResultStatus
    public var value: Double?
    public var numerator: Int?
    public var denominator: Int?
    public var confidenceInterval: BenchmarkConfidenceInterval?
    public var reason: String?

    public static func measured(
        value: Double,
        numerator: Int? = nil,
        denominator: Int? = nil,
        confidenceInterval: BenchmarkConfidenceInterval? = nil
    ) -> BenchmarkResult {
        BenchmarkResult(
            status: .measured,
            value: value,
            numerator: numerator,
            denominator: denominator,
            confidenceInterval: confidenceInterval,
            reason: nil
        )
    }

    public static func notApplicable(_ reason: String) -> BenchmarkResult {
        BenchmarkResult(
            status: .notApplicable,
            value: nil,
            numerator: nil,
            denominator: nil,
            confidenceInterval: nil,
            reason: reason
        )
    }
}

public struct BenchmarkPRFScore: Equatable, Sendable {
    public var precision: BenchmarkResult
    public var recall: BenchmarkResult
    public var f1: BenchmarkResult
}

public struct BenchmarkSetScore: Equatable, Sendable {
    public var precision: BenchmarkResult
    public var recall: BenchmarkResult
    public var f1: BenchmarkResult
    public var duplicateRate: BenchmarkResult
}

public struct BenchmarkRankedItem: Equatable, Sendable {
    public var id: String
    public var score: Double

    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

public enum BenchmarkPartitionState: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case interrupted
    case pending
    case unrun
}

public struct BenchmarkCompletenessObservation: Equatable, Sendable {
    public var partitionStates: [BenchmarkPartitionState]
    public var claimsComplete: Bool

    public init(partitionStates: [BenchmarkPartitionState], claimsComplete: Bool) {
        self.partitionStates = partitionStates
        self.claimsComplete = claimsComplete
    }
}

public enum BenchmarkMetrics {
    public static func rate(
        numerator: Int,
        denominator: Int,
        interval: BenchmarkIntervalRule = .wilson95
    ) -> BenchmarkResult {
        guard denominator > 0 else {
            return .notApplicable("zero denominator")
        }
        precondition(numerator >= 0 && numerator <= denominator, "rate numerator must be within 0...denominator")
        let value = Double(numerator) / Double(denominator)
        let confidenceInterval: BenchmarkConfidenceInterval?
        switch interval {
        case .none:
            confidenceInterval = nil
        case .wilson95:
            confidenceInterval = wilson95(successes: numerator, trials: denominator)
        }
        return .measured(
            value: value,
            numerator: numerator,
            denominator: denominator,
            confidenceInterval: confidenceInterval
        )
    }

    public static func count(_ value: Int) -> BenchmarkResult {
        precondition(value >= 0, "count must be nonnegative")
        return .measured(value: Double(value), numerator: value)
    }

    public static func setScore(expected: Set<String>, predicted: [String]) -> BenchmarkSetScore {
        let predictedSet = Set(predicted)
        let truePositive = expected.intersection(predictedSet).count
        let falsePositive = predictedSet.subtracting(expected).count
        let falseNegative = expected.subtracting(predictedSet).count
        let duplicateCount = predicted.count - predictedSet.count
        return BenchmarkSetScore(
            precision: rate(numerator: truePositive, denominator: truePositive + falsePositive),
            recall: rate(numerator: truePositive, denominator: truePositive + falseNegative),
            f1: rate(
                numerator: 2 * truePositive,
                denominator: 2 * truePositive + falsePositive + falseNegative
            ),
            duplicateRate: rate(numerator: duplicateCount, denominator: predicted.count)
        )
    }

    public static func binaryScore(
        expectedPositive: [Bool],
        predictedPositive: [Bool]
    ) -> BenchmarkPRFScore {
        precondition(expectedPositive.count == predictedPositive.count, "binary observations must be paired")
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for (expected, predicted) in zip(expectedPositive, predictedPositive) {
            switch (expected, predicted) {
            case (true, true): truePositive += 1
            case (false, true): falsePositive += 1
            case (true, false): falseNegative += 1
            case (false, false): break
            }
        }
        return BenchmarkPRFScore(
            precision: rate(numerator: truePositive, denominator: truePositive + falsePositive),
            recall: rate(numerator: truePositive, denominator: truePositive + falseNegative),
            f1: rate(
                numerator: 2 * truePositive,
                denominator: 2 * truePositive + falsePositive + falseNegative
            )
        )
    }

    public static func characterErrorRate(expected: String, predicted: String) -> BenchmarkResult {
        let golden = Array(expected)
        guard !golden.isEmpty else {
            return .notApplicable("golden text has zero characters")
        }
        let distance = levenshtein(golden, Array(predicted))
        return .measured(
            value: Double(distance) / Double(golden.count),
            numerator: distance,
            denominator: golden.count
        )
    }

    public static func rankingRecall(
        relevant: Set<String>,
        ranked: [BenchmarkRankedItem],
        k: Int
    ) -> BenchmarkResult {
        guard !relevant.isEmpty else {
            return .notApplicable("no relevant keys")
        }
        guard k > 0 else {
            return .notApplicable("K must be positive")
        }
        let stable = ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
        let retrieved = Set(stable.prefix(k).map(\.id))
        return rate(
            numerator: relevant.intersection(retrieved).count,
            denominator: relevant.count
        )
    }

    /// Correct pairwise order among golden items that appear in the prediction.
    public static func orderingAccuracy(
        expectedOrder: [String],
        predictedOrder: [String]
    ) -> BenchmarkResult {
        let predictedPosition = Dictionary(
            uniqueKeysWithValues: predictedOrder.enumerated().map { ($0.element, $0.offset) }
        )
        var correct = 0
        var comparable = 0
        for left in expectedOrder.indices {
            for right in expectedOrder.indices where right > left {
                guard let leftPosition = predictedPosition[expectedOrder[left]],
                      let rightPosition = predictedPosition[expectedOrder[right]] else { continue }
                comparable += 1
                if leftPosition < rightPosition { correct += 1 }
            }
        }
        return rate(numerator: correct, denominator: comparable)
    }

    public static func completenessFalseClaimRate(
        _ observations: [BenchmarkCompletenessObservation]
    ) -> BenchmarkResult {
        let incomplete = observations.filter {
            $0.partitionStates.isEmpty || $0.partitionStates.contains(where: { $0 != .succeeded })
        }
        return rate(
            numerator: incomplete.filter(\.claimsComplete).count,
            denominator: incomplete.count
        )
    }

    public static func brierScore(
        probabilities: [Double],
        outcomes: [Bool]
    ) -> BenchmarkResult {
        precondition(probabilities.count == outcomes.count, "calibration observations must be paired")
        guard !probabilities.isEmpty else { return .notApplicable("no calibration observations") }
        precondition(probabilities.allSatisfy { (0...1).contains($0) }, "probabilities must be within 0...1")
        let squaredError = zip(probabilities, outcomes).reduce(0.0) { partial, observation in
            let expected = observation.1 ? 1.0 : 0.0
            return partial + pow(observation.0 - expected, 2)
        }
        return .measured(value: squaredError / Double(probabilities.count), denominator: probabilities.count)
    }

    public static func expectedCalibrationError(
        probabilities: [Double],
        outcomes: [Bool],
        binCount: Int
    ) -> BenchmarkResult {
        precondition(probabilities.count == outcomes.count, "calibration observations must be paired")
        precondition(binCount > 0, "calibration bin count must be positive")
        guard !probabilities.isEmpty else { return .notApplicable("no calibration observations") }
        precondition(probabilities.allSatisfy { (0...1).contains($0) }, "probabilities must be within 0...1")

        var bins = Array(repeating: (confidence: 0.0, correct: 0, count: 0), count: binCount)
        for (probability, outcome) in zip(probabilities, outcomes) {
            let index = min(binCount - 1, Int(probability * Double(binCount)))
            bins[index].confidence += probability
            bins[index].correct += outcome ? 1 : 0
            bins[index].count += 1
        }
        let total = Double(probabilities.count)
        let error = bins.reduce(0.0) { partial, bin in
            guard bin.count > 0 else { return partial }
            let meanConfidence = bin.confidence / Double(bin.count)
            let accuracy = Double(bin.correct) / Double(bin.count)
            return partial + abs(meanConfidence - accuracy) * Double(bin.count) / total
        }
        return .measured(value: error, denominator: probabilities.count)
    }

    private static func wilson95(successes: Int, trials: Int) -> BenchmarkConfidenceInterval {
        let z = 1.959_963_984_540_054
        let n = Double(trials)
        let proportion = Double(successes) / n
        let zSquared = z * z
        let scale = 1 + zSquared / n
        let center = (proportion + zSquared / (2 * n)) / scale
        let margin = z * sqrt((proportion * (1 - proportion) + zSquared / (4 * n)) / n) / scale
        return BenchmarkConfidenceInterval(
            lower: max(0, center - margin),
            upper: min(1, center + margin),
            method: "wilson_95"
        )
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, right) in rhs.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
