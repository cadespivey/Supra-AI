import Foundation

public struct ChunkerMetricComparison: Codable, Equatable, Sendable {
    public var metricID: String
    public var name: String
    public var unit: String
    public var v1Value: Double
    public var v2Value: Double
    public var delta: Double
    public var passesNoninferiority: Bool
}

public struct ChunkerLatencyComparison: Codable, Equatable, Sendable {
    public var v1Seconds: Double
    public var v2Seconds: Double
    public var ratio: Double
}

public struct ChunkerDeferredGate: Codable, Equatable, Sendable {
    public var metricID: String
    public var status: String
    public var reason: String
}

public struct ChunkerDecision: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var shippingDefault: Int
    public var reasons: [String]
}

public struct ChunkerComparisonReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var repositorySHA: String
    public var corpusManifestSHA256: String
    public var generatedAt: String?
    public var metrics: [ChunkerMetricComparison]
    public var retrievalLatency: ChunkerLatencyComparison
    public var exhaustiveList: ChunkerDeferredGate
    public var decision: ChunkerDecision

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func make(
        repositorySHA: String,
        corpusManifestSHA256: String,
        generatedAt: String?,
        v1: BenchmarkReport,
        v2: BenchmarkReport,
        v1RetrievalSeconds: Double,
        v2RetrievalSeconds: Double
    ) throws -> ChunkerComparisonReport {
        guard v1RetrievalSeconds.isFinite, v1RetrievalSeconds > 0,
              v2RetrievalSeconds.isFinite, v2RetrievalSeconds >= 0 else {
            throw ChunkerComparisonReportError.invalidRetrievalLatency
        }

        let v1Measurements = try retrievalMeasurements(in: v1)
        let v2Measurements = try retrievalMeasurements(in: v2)
        guard Set(v1Measurements.keys) == Set(v2Measurements.keys), !v1Measurements.isEmpty else {
            throw ChunkerComparisonReportError.mismatchedRetrievalMeasurements
        }

        let metrics = try v1Measurements.keys.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.metricID < rhs.metricID : lhs.name < rhs.name
        }.map { key in
            guard let before = v1Measurements[key], let after = v2Measurements[key] else {
                throw ChunkerComparisonReportError.mismatchedRetrievalMeasurements
            }
            return ChunkerMetricComparison(
                metricID: key.metricID,
                name: key.name,
                unit: before.unit,
                v1Value: before.value,
                v2Value: after.value,
                delta: after.value - before.value,
                passesNoninferiority: after.value >= before.value
            )
        }

        let regressed = metrics.contains { !$0.passesNoninferiority }
        var reasons = ["D-06 requires explicit repo-owner approval."]
        if regressed {
            reasons.append("At least one B-RET metric regressed against the frozen v1 behavior.")
        } else {
            reasons.append("All measured B-RET metrics are noninferior to v1.")
        }
        reasons.append("B-LST-01 remains deferred until the exhaustive list engine lands in M6.")

        return ChunkerComparisonReport(
            schemaVersion: 1,
            repositorySHA: repositorySHA,
            corpusManifestSHA256: corpusManifestSHA256,
            generatedAt: generatedAt,
            metrics: metrics,
            retrievalLatency: ChunkerLatencyComparison(
                v1Seconds: v1RetrievalSeconds,
                v2Seconds: v2RetrievalSeconds,
                ratio: v2RetrievalSeconds / v1RetrievalSeconds
            ),
            exhaustiveList: ChunkerDeferredGate(
                metricID: "B-LST-01",
                status: "deferred_until_m6",
                reason: "The exhaustive list engine does not exist before M6."
            ),
            decision: ChunkerDecision(
                id: "D-06",
                status: regressed ? "blocked_recall_regression" : "pending_owner_approval",
                shippingDefault: 1,
                reasons: reasons
            )
        )
    }

    private struct MeasurementKey: Hashable {
        var metricID: String
        var name: String
    }

    private struct MeasuredValue {
        var unit: String
        var value: Double
    }

    private static func retrievalMeasurements(
        in report: BenchmarkReport
    ) throws -> [MeasurementKey: MeasuredValue] {
        var values: [MeasurementKey: MeasuredValue] = [:]
        for row in report.metrics where row.id == "B-RET-01" || row.id == "B-RET-02" {
            for measurement in row.measurements where measurement.status == .measured {
                guard let value = measurement.value, value.isFinite else {
                    throw ChunkerComparisonReportError.invalidRetrievalMeasurement("\(row.id)|\(measurement.name)")
                }
                values[MeasurementKey(metricID: row.id, name: measurement.name)] = MeasuredValue(
                    unit: measurement.unit,
                    value: value
                )
            }
        }
        return values
    }
}

public enum ChunkerComparisonReportError: Error, Equatable {
    case invalidRetrievalLatency
    case invalidRetrievalMeasurement(String)
    case mismatchedRetrievalMeasurements
}
