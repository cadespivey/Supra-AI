import Foundation

public struct BenchmarkMetricDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var unavailableReason: String
}

public enum BenchmarkMetricCatalog {
    public static let all: [BenchmarkMetricDefinition] = [
        .init(id: "B-ACC-01", title: "Source accounting", unavailableReason: "import accounting observation unavailable"),
        .init(id: "B-CHR-01", title: "Chronology event accuracy", unavailableReason: "chronology result unavailable"),
        .init(id: "B-CHR-02", title: "Chronology order and coverage", unavailableReason: "chronology result unavailable"),
        .init(id: "B-CLS-01", title: "Classification macro F1", unavailableReason: "classification result unavailable"),
        .init(id: "B-CLS-02", title: "Classification abstention and evidence", unavailableReason: "classification evidence unavailable"),
        .init(id: "B-CMP-01", title: "Completeness false claims", unavailableReason: "exhaustive corpus runs do not exist before M6"),
        .init(id: "B-CTX-01", title: "Context utilization", unavailableReason: "exact token accounting does not exist before M8"),
        .init(id: "B-CTX-02", title: "Context omission and overflow recovery", unavailableReason: "packing reports do not exist before M8"),
        .init(id: "B-EXT-01", title: "Extraction character error", unavailableReason: "normalized extraction goldens do not exist before M4"),
        .init(id: "B-EXT-02", title: "Extraction field accuracy", unavailableReason: "typed extraction fields do not exist before M4"),
        .init(id: "B-ISO-01", title: "Matter isolation", unavailableReason: "isolation observation unavailable"),
        .init(id: "B-LIN-01", title: "Stale detection", unavailableReason: "lineage dependency observation unavailable"),
        .init(id: "B-LOC-01", title: "Locator round trip", unavailableReason: "revision-bound golden locators do not exist before M4"),
        .init(id: "B-LST-01", title: "Exhaustive list accuracy", unavailableReason: "exhaustive list engine does not exist before M6"),
        .init(id: "B-NEG-01", title: "Negative false accepts", unavailableReason: "negative task engine does not exist before M6"),
        .init(id: "B-OCR-01", title: "OCR selection", unavailableReason: "dual OCR candidates do not exist before M3"),
        .init(id: "B-OCR-02", title: "OCR calibration", unavailableReason: "OCR decision keys do not exist before M3"),
        .init(id: "B-PERF-01", title: "Latency", unavailableReason: "fixed performance protocol unavailable"),
        .init(id: "B-PERF-02", title: "Throughput and memory", unavailableReason: "fixed performance protocol unavailable"),
        .init(id: "B-PERF-03", title: "Incremental work", unavailableReason: "incremental lineage path does not exist before M8"),
        .init(id: "B-REC-01", title: "Recovery", unavailableReason: "durable recovery ledger does not exist before M2"),
        .init(id: "B-RET-01", title: "Retrieval recall at K", unavailableReason: "retrieval observation unavailable"),
        .init(id: "B-RET-02", title: "Full evidence-set recall", unavailableReason: "retrieval observation unavailable"),
        .init(id: "B-STR-01", title: "Structure accuracy", unavailableReason: "structure nodes do not exist before M4"),
        .init(id: "B-SUP-01", title: "Support false accepts", unavailableReason: "support observation unavailable"),
        .init(id: "B-TAB-01", title: "Table header association", unavailableReason: "header graph does not exist before M4"),
        .init(id: "B-VER-01", title: "Document relation accuracy", unavailableReason: "relation observation unavailable"),
        .init(id: "B-VER-02", title: "Operative state accuracy", unavailableReason: "relation review workflow does not exist before M7"),
    ]
}

public struct BenchmarkObservation: Codable, Equatable, Sendable {
    public var metricID: String
    public var name: String
    public var unit: String
    public var result: BenchmarkResult

    public init(metricID: String, name: String, unit: String, result: BenchmarkResult) {
        self.metricID = metricID
        self.name = name
        self.unit = unit
        self.result = result
    }
}

public struct BenchmarkMeasurement: Codable, Equatable, Sendable {
    public var name: String
    public var unit: String
    public var status: BenchmarkResultStatus
    public var value: Double?
    public var numerator: Int?
    public var denominator: Int?
    public var confidenceInterval: BenchmarkConfidenceInterval?
    public var reason: String?

    init(observation: BenchmarkObservation) {
        name = observation.name
        unit = observation.unit
        status = observation.result.status
        value = observation.result.value
        numerator = observation.result.numerator
        denominator = observation.result.denominator
        confidenceInterval = observation.result.confidenceInterval
        reason = observation.result.reason
    }

    init(notApplicable reason: String) {
        name = "overall"
        unit = "rate"
        status = .notApplicable
        value = nil
        numerator = nil
        denominator = nil
        confidenceInterval = nil
        self.reason = reason
    }
}

public struct BenchmarkMetricRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var measurements: [BenchmarkMeasurement]
}

public struct BenchmarkRunMetadata: Codable, Equatable, Sendable {
    public var mode: String
    public var repositorySHA: String
    public var corpusManifestSHA256: String
    public var generatedAt: String?
}

public struct BenchmarkReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var run: BenchmarkRunMetadata
    public var metrics: [BenchmarkMetricRow]

    public func canonicalJSON(strippingRunTimestamp: Bool = false) throws -> Data {
        var report = self
        if strippingRunTimestamp { report.run.generatedAt = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

public enum BenchmarkReportError: Error, Equatable {
    case unknownMetricID(String)
    case duplicateMeasurement(String)
}

public final class BenchmarkRunner: @unchecked Sendable {
    public typealias Workload = @Sendable () async throws -> [BenchmarkObservation]

    private let repositorySHA: String
    private let corpusManifestSHA256: String
    private let clock: @Sendable () -> Date
    private let workload: Workload

    public init(
        repositorySHA: String,
        corpusManifestSHA256: String,
        clock: @escaping @Sendable () -> Date = Date.init,
        workload: @escaping Workload
    ) {
        self.repositorySHA = repositorySHA
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.clock = clock
        self.workload = workload
    }

    public func runDeterministic() async throws -> BenchmarkReport {
        let observations = try await workload()
        let knownIDs = Set(BenchmarkMetricCatalog.all.map(\.id))
        for observation in observations where !knownIDs.contains(observation.metricID) {
            throw BenchmarkReportError.unknownMetricID(observation.metricID)
        }

        var grouped: [String: [BenchmarkObservation]] = [:]
        var keys = Set<String>()
        for observation in observations {
            let key = "\(observation.metricID)|\(observation.name)"
            guard keys.insert(key).inserted else {
                throw BenchmarkReportError.duplicateMeasurement(key)
            }
            grouped[observation.metricID, default: []].append(observation)
        }

        let rows = BenchmarkMetricCatalog.all.map { definition in
            let measurements: [BenchmarkMeasurement]
            if let observed = grouped[definition.id] {
                measurements = observed.sorted { $0.name < $1.name }.map(BenchmarkMeasurement.init)
            } else {
                measurements = [BenchmarkMeasurement(notApplicable: definition.unavailableReason)]
            }
            return BenchmarkMetricRow(id: definition.id, title: definition.title, measurements: measurements)
        }

        return BenchmarkReport(
            schemaVersion: 1,
            run: BenchmarkRunMetadata(
                mode: "deterministic",
                repositorySHA: repositorySHA,
                corpusManifestSHA256: corpusManifestSHA256,
                generatedAt: Self.timestamp(clock())
            ),
            metrics: rows
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
