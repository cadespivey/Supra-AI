import Foundation
@testable import SupraTestKit
import XCTest

final class PerformanceBenchmarkTests: XCTestCase {
    func testBPERF01NearestRankLatencyAndBPERF02ThroughputArePinned() throws {
        // B-PERF-01/02 expected RED: the catalog has placeholder rows only; no
        // fixed-protocol percentile or scale measurement contract exists.
        let scale = try PerformanceScaleMeasurement(
            documentCount: 50,
            inputBytes: 5 * 1_048_576,
            importIndexSeconds: 120,
            fastRetrievalMilliseconds: [4, 1, 2],
            retrievalMilliseconds: [9, 1, 5, 7, 3],
            ledgerWriteMilliseconds: [4, 2, 3],
            structureWriteMilliseconds: [8, 6, 7],
            peakRSSMiB: 512,
            importedDocumentCount: 50,
            persistedLedgerRowCount: 50,
            persistedStructureNodeCount: 100
        )

        XCTAssertEqual(scale.fastRetrievalP50Milliseconds, 2)
        XCTAssertEqual(scale.fastRetrievalP95Milliseconds, 4)
        XCTAssertEqual(scale.retrievalP50Milliseconds, 5)
        XCTAssertEqual(scale.retrievalP95Milliseconds, 9)
        XCTAssertEqual(scale.ledgerWriteP50Milliseconds, 3)
        XCTAssertEqual(scale.structureWriteP95Milliseconds, 8)
        XCTAssertEqual(scale.documentsPerMinute, 25, accuracy: 0.0001)
        XCTAssertEqual(scale.mebibytesPerSecond, 5.0 / 120.0, accuracy: 0.0001)
        XCTAssertEqual(scale.persistedLedgerRowCount, 50)
        XCTAssertEqual(scale.persistedStructureNodeCount, 100)
    }

    func testBPERF03UnaffectedWorkIsAnImmediateDeterministicReleaseGate() throws {
        // B-PERF-03 expected RED: no incremental-work report or zero-unaffected
        // release rule exists.
        let clean = try report(unaffectedDocumentsTouched: 0)
        let dirty = try report(unaffectedDocumentsTouched: 3)
        let thresholds = PerformanceThresholdManifest.pendingFixture

        XCTAssertTrue(
            PerformanceReleaseGate.evaluate(
                report: clean,
                thresholds: thresholds,
                requireApprovedStatisticalThresholds: false
            ).violations.isEmpty
        )
        let dirtyEvaluation = PerformanceReleaseGate.evaluate(
            report: dirty,
            thresholds: thresholds,
            requireApprovedStatisticalThresholds: false
        )
        XCTAssertEqual(dirtyEvaluation.violations.map(\.metricID), ["B-PERF-03"])
        XCTAssertTrue(try XCTUnwrap(dirtyEvaluation.violations.first?.detail).contains("3"))
    }

    func testApprovedPlusOrMinusTenPercentBandsGateLatencyAndThroughput() throws {
        // B-PERF-01/02 expected RED: pending proposals cannot be evaluated and
        // no approved baseline-relative threshold gate is implemented.
        let baseline = try report(
            retrievalP50: 50,
            retrievalP95: 100,
            documentsPerMinute: 60,
            mebibytesPerSecond: 2,
            peakRSSMiB: 700,
            incrementalMilliseconds: 20
        )
        let thresholds = PerformanceThresholdManifest.approvedFixture(from: baseline)
        let passing = try report(
            retrievalP50: 55,
            retrievalP95: 110,
            documentsPerMinute: 54,
            mebibytesPerSecond: 1.8,
            peakRSSMiB: 800,
            incrementalMilliseconds: 22
        )
        let failing = try report(
            retrievalP50: 56,
            retrievalP95: 111,
            documentsPerMinute: 53,
            mebibytesPerSecond: 1.79,
            peakRSSMiB: 801,
            incrementalMilliseconds: 23
        )

        XCTAssertTrue(PerformanceReleaseGate.evaluate(
            report: passing,
            thresholds: thresholds,
            requireApprovedStatisticalThresholds: true
        ).violations.isEmpty)
        XCTAssertEqual(
            Set(PerformanceReleaseGate.evaluate(
                report: failing,
                thresholds: thresholds,
                requireApprovedStatisticalThresholds: true
            ).violations.map(\.metricID)),
            Set(["B-PERF-01", "B-PERF-02", "B-PERF-03"])
        )
    }

    func testPendingOwnerApprovalFailsClosedOnlyWhenReleaseGateIsRequested() throws {
        // D-09 expected RED: threshold ownership lives in prose and cannot make a
        // release-gate invocation fail closed while still allowing baseline capture.
        let report = try report(unaffectedDocumentsTouched: 0)
        let capture = PerformanceReleaseGate.evaluate(
            report: report,
            thresholds: .pendingFixture,
            requireApprovedStatisticalThresholds: false
        )
        let release = PerformanceReleaseGate.evaluate(
            report: report,
            thresholds: .pendingFixture,
            requireApprovedStatisticalThresholds: true
        )

        XCTAssertTrue(capture.violations.isEmpty)
        XCTAssertEqual(release.violations.map(\.metricID), ["B-PERF-01", "B-PERF-02", "B-PERF-03"])
        XCTAssertTrue(release.violations.allSatisfy { $0.detail.contains("owner approval") })
    }

    func testApprovedGateRejectsUnlikeFixedHardwareOrToolchainMetadata() throws {
        // B-PERF-01/02/03 expected RED: the measured baseline values do not retain
        // their fixed hardware/toolchain identity, so unlike runs compare as if
        // they used the release-candidate protocol.
        let baseline = try report(run: .fixture)
        let thresholds = PerformanceThresholdManifest.approvedFixture(from: baseline)
        var unlikeRun = PerformanceRunMetadata.fixture
        unlikeRun.hardwareIdentifier = "different-mac"
        unlikeRun.xcodeVersion = "different-xcode"
        let measured = try report(run: unlikeRun)

        XCTAssertEqual(
            PerformanceReleaseGate.evaluate(
                report: measured,
                thresholds: thresholds,
                requireApprovedStatisticalThresholds: true
            ).violations.map(\.metricID),
            ["B-PERF-01", "B-PERF-02", "B-PERF-03"]
        )
    }

    func testApprovedGateFailsClosedWhenMemoryOrIncrementalBandsAreMissing() throws {
        // D-09 expected RED: changing the manifest to approved while leaving the
        // owner-set B-PERF-02 memory and B-PERF-03 incremental bands nil silently
        // disables those two release gates.
        let baseline = try report()
        var thresholds = PerformanceThresholdManifest.approvedFixture(from: baseline)
        thresholds.peakRSSCeilingMiB = nil
        thresholds.incrementalWallClockRegressionFraction = nil

        XCTAssertEqual(
            PerformanceReleaseGate.evaluate(
                report: baseline,
                thresholds: thresholds,
                requireApprovedStatisticalThresholds: true
            ).violations.map(\.metricID),
            ["B-PERF-02", "B-PERF-03"]
        )
    }

    private func report(
        retrievalP50: Double = 50,
        retrievalP95: Double = 100,
        documentsPerMinute: Double = 60,
        mebibytesPerSecond: Double = 2,
        peakRSSMiB: Double = 700,
        incrementalMilliseconds: Double = 20,
        unaffectedDocumentsTouched: Int = 0,
        run: PerformanceRunMetadata = .fixture
    ) throws -> FixedPerformanceReport {
        FixedPerformanceReport(
            schemaVersion: 1,
            run: run,
            scales: [try PerformanceScaleMeasurement(
                documentCount: 200,
                inputBytes: 200 * 1_048_576,
                importIndexSeconds: 200 * 60 / documentsPerMinute,
                retrievalMilliseconds: [retrievalP50, retrievalP95],
                ledgerWriteMilliseconds: [10, 20],
                structureWriteMilliseconds: [10, 20],
                peakRSSMiB: peakRSSMiB,
                importedDocumentCount: 200,
                persistedLedgerRowCount: 200,
                persistedStructureNodeCount: 400,
                documentsPerMinuteOverride: documentsPerMinute,
                mebibytesPerSecondOverride: mebibytesPerSecond,
                retrievalP50Override: retrievalP50,
                retrievalP95Override: retrievalP95
            )],
            incremental: IncrementalPerformanceMeasurement(
                documentCount: 200,
                changedDocumentCount: 1,
                unaffectedDocumentsTouched: unaffectedDocumentsTouched,
                rowsTouched: 7,
                bytesTouched: 1_024,
                wallClockMilliseconds: incrementalMilliseconds
            )
        )
    }
}

private extension PerformanceRunMetadata {
    static let fixture = PerformanceRunMetadata(
        repositorySHA: "fixture-sha",
        generatedAt: "2026-07-18T00:00:00Z",
        hardwareIdentifier: "fixture-mac",
        operatingSystem: "macOS fixture",
        xcodeVersion: "Xcode fixture",
        swiftVersion: "Swift fixture",
        thermalState: "nominal",
        protocolVersion: "document-performance-v1"
    )
}

private extension PerformanceThresholdManifest {
    static let pendingFixture = PerformanceThresholdManifest(
        schemaVersion: 1,
        baselinePath: "fixture.json",
        approvalStatus: .pendingOwnerApproval,
        approvedBy: nil,
        approvedAt: nil,
        latencyRegressionFraction: 0.10,
        throughputRegressionFraction: 0.10,
        peakRSSCeilingMiB: nil,
        incrementalWallClockRegressionFraction: nil,
        requireZeroUnaffectedDocumentsTouched: true,
        baseline: nil
    )

    static func approvedFixture(from report: FixedPerformanceReport) -> PerformanceThresholdManifest {
        PerformanceThresholdManifest(
            schemaVersion: 1,
            baselinePath: "fixture.json",
            approvalStatus: .approved,
            approvedBy: "repo_owner",
            approvedAt: "2026-07-18",
            latencyRegressionFraction: 0.10,
            throughputRegressionFraction: 0.10,
            peakRSSCeilingMiB: 800,
            incrementalWallClockRegressionFraction: 0.10,
            requireZeroUnaffectedDocumentsTouched: true,
            baseline: PerformanceThresholdBaseline(report: report)
        )
    }
}
