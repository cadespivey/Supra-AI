import Foundation

public enum PerformanceBenchmarkError: Error, Equatable, Sendable {
    case invalidDocumentCount
    case invalidDuration
    case emptySamples(String)
    case invalidCount(String)
}

public struct PerformanceScaleMeasurement: Codable, Equatable, Sendable {
    public var documentCount: Int
    public var inputBytes: Int
    public var importIndexSeconds: Double
    public var fastRetrievalMilliseconds: [Double]
    public var retrievalMilliseconds: [Double]
    public var ledgerWriteMilliseconds: [Double]
    public var structureWriteMilliseconds: [Double]
    public var peakRSSMiB: Double
    public var importedDocumentCount: Int
    public var persistedLedgerRowCount: Int
    public var persistedStructureNodeCount: Int
    public var fastRetrievalP50Milliseconds: Double
    public var fastRetrievalP95Milliseconds: Double
    public var retrievalP50Milliseconds: Double
    public var retrievalP95Milliseconds: Double
    public var ledgerWriteP50Milliseconds: Double
    public var ledgerWriteP95Milliseconds: Double
    public var structureWriteP50Milliseconds: Double
    public var structureWriteP95Milliseconds: Double
    public var documentsPerMinute: Double
    public var mebibytesPerSecond: Double

    public init(
        documentCount: Int,
        inputBytes: Int,
        importIndexSeconds: Double,
        fastRetrievalMilliseconds: [Double]? = nil,
        retrievalMilliseconds: [Double],
        ledgerWriteMilliseconds: [Double],
        structureWriteMilliseconds: [Double],
        peakRSSMiB: Double,
        importedDocumentCount: Int,
        persistedLedgerRowCount: Int,
        persistedStructureNodeCount: Int,
        documentsPerMinuteOverride: Double? = nil,
        mebibytesPerSecondOverride: Double? = nil,
        retrievalP50Override: Double? = nil,
        retrievalP95Override: Double? = nil
    ) throws {
        guard documentCount > 0 else { throw PerformanceBenchmarkError.invalidDocumentCount }
        guard importIndexSeconds > 0 else { throw PerformanceBenchmarkError.invalidDuration }
        guard !retrievalMilliseconds.isEmpty else {
            throw PerformanceBenchmarkError.emptySamples("retrieval")
        }
        let resolvedFastRetrieval = fastRetrievalMilliseconds ?? retrievalMilliseconds
        guard !resolvedFastRetrieval.isEmpty else {
            throw PerformanceBenchmarkError.emptySamples("fast_retrieval")
        }
        guard !ledgerWriteMilliseconds.isEmpty else {
            throw PerformanceBenchmarkError.emptySamples("ledger")
        }
        guard !structureWriteMilliseconds.isEmpty else {
            throw PerformanceBenchmarkError.emptySamples("structure")
        }
        guard inputBytes >= 0, importedDocumentCount >= 0,
              persistedLedgerRowCount >= 0, persistedStructureNodeCount >= 0 else {
            throw PerformanceBenchmarkError.invalidCount("scale")
        }
        self.documentCount = documentCount
        self.inputBytes = inputBytes
        self.importIndexSeconds = importIndexSeconds
        self.fastRetrievalMilliseconds = resolvedFastRetrieval
        self.retrievalMilliseconds = retrievalMilliseconds
        self.ledgerWriteMilliseconds = ledgerWriteMilliseconds
        self.structureWriteMilliseconds = structureWriteMilliseconds
        self.peakRSSMiB = peakRSSMiB
        self.importedDocumentCount = importedDocumentCount
        self.persistedLedgerRowCount = persistedLedgerRowCount
        self.persistedStructureNodeCount = persistedStructureNodeCount
        fastRetrievalP50Milliseconds = Self.nearestRank(resolvedFastRetrieval, percentile: 0.50)
        fastRetrievalP95Milliseconds = Self.nearestRank(resolvedFastRetrieval, percentile: 0.95)
        retrievalP50Milliseconds = retrievalP50Override
            ?? Self.nearestRank(retrievalMilliseconds, percentile: 0.50)
        retrievalP95Milliseconds = retrievalP95Override
            ?? Self.nearestRank(retrievalMilliseconds, percentile: 0.95)
        ledgerWriteP50Milliseconds = Self.nearestRank(ledgerWriteMilliseconds, percentile: 0.50)
        ledgerWriteP95Milliseconds = Self.nearestRank(ledgerWriteMilliseconds, percentile: 0.95)
        structureWriteP50Milliseconds = Self.nearestRank(structureWriteMilliseconds, percentile: 0.50)
        structureWriteP95Milliseconds = Self.nearestRank(structureWriteMilliseconds, percentile: 0.95)
        documentsPerMinute = documentsPerMinuteOverride
            ?? Double(importedDocumentCount) * 60 / importIndexSeconds
        mebibytesPerSecond = mebibytesPerSecondOverride
            ?? (Double(inputBytes) / 1_048_576) / importIndexSeconds
    }

    public static func nearestRank(_ samples: [Double], percentile: Double) -> Double {
        guard !samples.isEmpty else { return .nan }
        let ordered = samples.sorted()
        let bounded = min(1, max(0, percentile))
        let rank = max(1, Int(ceil(bounded * Double(ordered.count))))
        return ordered[min(ordered.count - 1, rank - 1)]
    }
}

public struct IncrementalPerformanceMeasurement: Codable, Equatable, Sendable {
    public var documentCount: Int
    public var changedDocumentCount: Int
    public var unaffectedDocumentsTouched: Int
    public var rowsTouched: Int
    public var bytesTouched: Int
    public var wallClockMilliseconds: Double

    public init(
        documentCount: Int,
        changedDocumentCount: Int,
        unaffectedDocumentsTouched: Int,
        rowsTouched: Int,
        bytesTouched: Int,
        wallClockMilliseconds: Double
    ) {
        self.documentCount = documentCount
        self.changedDocumentCount = changedDocumentCount
        self.unaffectedDocumentsTouched = unaffectedDocumentsTouched
        self.rowsTouched = rowsTouched
        self.bytesTouched = bytesTouched
        self.wallClockMilliseconds = wallClockMilliseconds
    }
}

public struct PerformanceRunMetadata: Codable, Equatable, Sendable {
    public var repositorySHA: String
    public var generatedAt: String
    public var hardwareIdentifier: String
    public var operatingSystem: String
    public var xcodeVersion: String
    public var swiftVersion: String
    public var thermalState: String
    public var protocolVersion: String

    public init(
        repositorySHA: String,
        generatedAt: String,
        hardwareIdentifier: String,
        operatingSystem: String,
        xcodeVersion: String,
        swiftVersion: String,
        thermalState: String,
        protocolVersion: String
    ) {
        self.repositorySHA = repositorySHA
        self.generatedAt = generatedAt
        self.hardwareIdentifier = hardwareIdentifier
        self.operatingSystem = operatingSystem
        self.xcodeVersion = xcodeVersion
        self.swiftVersion = swiftVersion
        self.thermalState = thermalState
        self.protocolVersion = protocolVersion
    }
}

public struct FixedPerformanceReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var run: PerformanceRunMetadata
    public var scales: [PerformanceScaleMeasurement]
    public var incremental: IncrementalPerformanceMeasurement

    public init(
        schemaVersion: Int,
        run: PerformanceRunMetadata,
        scales: [PerformanceScaleMeasurement],
        incremental: IncrementalPerformanceMeasurement
    ) {
        self.schemaVersion = schemaVersion
        self.run = run
        self.scales = scales
        self.incremental = incremental
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum PerformanceThresholdApprovalStatus: String, Codable, Equatable, Sendable {
    case pendingOwnerApproval = "pending_owner_approval"
    case approved
}

public struct PerformanceEnvironmentFingerprint: Codable, Equatable, Sendable {
    public var hardwareIdentifier: String
    public var operatingSystem: String
    public var xcodeVersion: String
    public var swiftVersion: String
    public var thermalState: String
    public var protocolVersion: String

    public init(run: PerformanceRunMetadata) {
        hardwareIdentifier = run.hardwareIdentifier
        operatingSystem = run.operatingSystem
        xcodeVersion = run.xcodeVersion
        swiftVersion = run.swiftVersion
        thermalState = run.thermalState
        protocolVersion = run.protocolVersion
    }
}

public struct PerformanceThresholdBaseline: Codable, Equatable, Sendable {
    public var environment: PerformanceEnvironmentFingerprint
    public var fastRetrievalP50Milliseconds: Double
    public var fastRetrievalP95Milliseconds: Double
    public var retrievalP50Milliseconds: Double
    public var retrievalP95Milliseconds: Double
    public var ledgerWriteP50Milliseconds: Double
    public var ledgerWriteP95Milliseconds: Double
    public var structureWriteP50Milliseconds: Double
    public var structureWriteP95Milliseconds: Double
    public var documentsPerMinute: Double
    public var mebibytesPerSecond: Double
    public var peakRSSMiB: Double
    public var incrementalWallClockMilliseconds: Double

    public init(report: FixedPerformanceReport) {
        environment = PerformanceEnvironmentFingerprint(run: report.run)
        let scale = report.scales.first(where: { $0.documentCount == 200 })
            ?? report.scales.max(by: { $0.documentCount < $1.documentCount })
        fastRetrievalP50Milliseconds = scale?.fastRetrievalP50Milliseconds ?? .infinity
        fastRetrievalP95Milliseconds = scale?.fastRetrievalP95Milliseconds ?? .infinity
        retrievalP50Milliseconds = scale?.retrievalP50Milliseconds ?? .infinity
        retrievalP95Milliseconds = scale?.retrievalP95Milliseconds ?? .infinity
        ledgerWriteP50Milliseconds = scale?.ledgerWriteP50Milliseconds ?? .infinity
        ledgerWriteP95Milliseconds = scale?.ledgerWriteP95Milliseconds ?? .infinity
        structureWriteP50Milliseconds = scale?.structureWriteP50Milliseconds ?? .infinity
        structureWriteP95Milliseconds = scale?.structureWriteP95Milliseconds ?? .infinity
        documentsPerMinute = scale?.documentsPerMinute ?? 0
        mebibytesPerSecond = scale?.mebibytesPerSecond ?? 0
        peakRSSMiB = scale?.peakRSSMiB ?? .infinity
        incrementalWallClockMilliseconds = report.incremental.wallClockMilliseconds
    }
}

public struct PerformanceThresholdManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var baselinePath: String
    public var approvalStatus: PerformanceThresholdApprovalStatus
    public var approvedBy: String?
    public var approvedAt: String?
    public var latencyRegressionFraction: Double
    public var throughputRegressionFraction: Double
    public var peakRSSCeilingMiB: Double?
    public var incrementalWallClockRegressionFraction: Double?
    public var requireZeroUnaffectedDocumentsTouched: Bool
    public var baseline: PerformanceThresholdBaseline?

    public init(
        schemaVersion: Int,
        baselinePath: String,
        approvalStatus: PerformanceThresholdApprovalStatus,
        approvedBy: String?,
        approvedAt: String?,
        latencyRegressionFraction: Double,
        throughputRegressionFraction: Double,
        peakRSSCeilingMiB: Double?,
        incrementalWallClockRegressionFraction: Double?,
        requireZeroUnaffectedDocumentsTouched: Bool,
        baseline: PerformanceThresholdBaseline?
    ) {
        self.schemaVersion = schemaVersion
        self.baselinePath = baselinePath
        self.approvalStatus = approvalStatus
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
        self.latencyRegressionFraction = latencyRegressionFraction
        self.throughputRegressionFraction = throughputRegressionFraction
        self.peakRSSCeilingMiB = peakRSSCeilingMiB
        self.incrementalWallClockRegressionFraction = incrementalWallClockRegressionFraction
        self.requireZeroUnaffectedDocumentsTouched = requireZeroUnaffectedDocumentsTouched
        self.baseline = baseline
    }
}

public struct PerformanceGateViolation: Codable, Equatable, Sendable {
    public var metricID: String
    public var detail: String

    public init(metricID: String, detail: String) {
        self.metricID = metricID
        self.detail = detail
    }
}

public struct PerformanceGateEvaluation: Codable, Equatable, Sendable {
    public var violations: [PerformanceGateViolation]

    public init(violations: [PerformanceGateViolation]) {
        self.violations = violations
    }
}

public enum PerformanceReleaseGate {
    public static func evaluate(
        report: FixedPerformanceReport,
        thresholds: PerformanceThresholdManifest,
        requireApprovedStatisticalThresholds: Bool
    ) -> PerformanceGateEvaluation {
        var violations: [PerformanceGateViolation] = []
        if thresholds.requireZeroUnaffectedDocumentsTouched,
           report.incremental.unaffectedDocumentsTouched != 0 {
            violations.append(.init(
                metricID: "B-PERF-03",
                detail: "Incremental work touched \(report.incremental.unaffectedDocumentsTouched) unaffected documents; required 0."
            ))
        }

        let approved = thresholds.approvalStatus == .approved
            && thresholds.approvedBy?.isEmpty == false
            && thresholds.approvedAt?.isEmpty == false
            && thresholds.baseline != nil
        guard approved, let baseline = thresholds.baseline else {
            if requireApprovedStatisticalThresholds {
                for metricID in ["B-PERF-01", "B-PERF-02", "B-PERF-03"] {
                    if !violations.contains(where: { $0.metricID == metricID }) {
                        violations.append(.init(
                            metricID: metricID,
                            detail: "Statistical release gating requires explicit repo owner approval."
                        ))
                    }
                }
            }
            return PerformanceGateEvaluation(violations: violations)
        }

        if !thresholds.latencyRegressionFraction.isFinite
            || thresholds.latencyRegressionFraction < 0 {
            violations.append(.init(
                metricID: "B-PERF-01",
                detail: "The approved latency regression band is invalid."
            ))
        }
        if !thresholds.throughputRegressionFraction.isFinite
            || !(0..<1).contains(thresholds.throughputRegressionFraction) {
            violations.append(.init(
                metricID: "B-PERF-02",
                detail: "The approved throughput regression band is invalid."
            ))
        }
        if thresholds.peakRSSCeilingMiB.map({ !$0.isFinite || $0 <= 0 }) ?? true,
           !violations.contains(where: { $0.metricID == "B-PERF-02" }) {
            violations.append(.init(
                metricID: "B-PERF-02",
                detail: "The approved peak RSS ceiling is missing or invalid."
            ))
        }
        if thresholds.incrementalWallClockRegressionFraction
            .map({ !$0.isFinite || $0 < 0 }) ?? true {
            violations.append(.init(
                metricID: "B-PERF-03",
                detail: "The approved incremental wall-time band is missing or invalid."
            ))
        }

        if PerformanceEnvironmentFingerprint(run: report.run) != baseline.environment {
            for metricID in ["B-PERF-01", "B-PERF-02", "B-PERF-03"] {
                if !violations.contains(where: { $0.metricID == metricID }) {
                    violations.append(.init(
                        metricID: metricID,
                        detail: "The run does not match the approved fixed hardware, OS, toolchain, thermal state, and protocol."
                    ))
                }
            }
            return PerformanceGateEvaluation(violations: violations)
        }

        guard let scale = report.scales.first(where: { $0.documentCount == 200 })
            ?? report.scales.max(by: { $0.documentCount < $1.documentCount }) else {
            return PerformanceGateEvaluation(violations: violations + [
                .init(metricID: "B-PERF-01", detail: "The report has no scale measurements."),
                .init(metricID: "B-PERF-02", detail: "The report has no scale measurements."),
            ])
        }
        let tolerance = 1e-9
        let latencyCeiling = 1 + thresholds.latencyRegressionFraction
        let latencyPairs = [
            (scale.fastRetrievalP50Milliseconds, baseline.fastRetrievalP50Milliseconds),
            (scale.fastRetrievalP95Milliseconds, baseline.fastRetrievalP95Milliseconds),
            (scale.retrievalP50Milliseconds, baseline.retrievalP50Milliseconds),
            (scale.retrievalP95Milliseconds, baseline.retrievalP95Milliseconds),
            (scale.ledgerWriteP50Milliseconds, baseline.ledgerWriteP50Milliseconds),
            (scale.ledgerWriteP95Milliseconds, baseline.ledgerWriteP95Milliseconds),
            (scale.structureWriteP50Milliseconds, baseline.structureWriteP50Milliseconds),
            (scale.structureWriteP95Milliseconds, baseline.structureWriteP95Milliseconds),
        ]
        if latencyPairs.contains(where: { measured, approved in
            measured > approved * latencyCeiling + tolerance
        }) {
            violations.append(.init(metricID: "B-PERF-01", detail: "Operation p50/p95 exceeded the approved regression band."))
        }
        let throughputFloor = 1 - thresholds.throughputRegressionFraction
        if scale.documentsPerMinute + tolerance < baseline.documentsPerMinute * throughputFloor
            || scale.mebibytesPerSecond + tolerance < baseline.mebibytesPerSecond * throughputFloor
            || thresholds.peakRSSCeilingMiB.map({ scale.peakRSSMiB > $0 + tolerance }) == true {
            violations.append(.init(metricID: "B-PERF-02", detail: "Throughput or peak RSS breached the approved threshold."))
        }
        if let fraction = thresholds.incrementalWallClockRegressionFraction,
           report.incremental.wallClockMilliseconds
            > baseline.incrementalWallClockMilliseconds * (1 + fraction) + tolerance,
           !violations.contains(where: { $0.metricID == "B-PERF-03" }) {
            violations.append(.init(metricID: "B-PERF-03", detail: "Incremental wall time exceeded the approved regression band."))
        }
        return PerformanceGateEvaluation(violations: violations)
    }
}
