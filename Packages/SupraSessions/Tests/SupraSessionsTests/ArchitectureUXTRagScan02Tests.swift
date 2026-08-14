import Foundation
@testable import SupraSessions
import XCTest

/// T-RAG-SCAN-02
///
/// Expected RED before WP-3.3: no large-corpus proof bounds live page/vector/
/// heap state, and cancellation has no observable release-before-publication
/// contract.
final class ArchitectureUXTRagScan02Tests: XCTestCase {
    func testLargeCorpusStaysBoundedAtNAndNPlusOne() throws {
        for count in [30, 31] {
            let fixture = try ArchitectureUXRagScanFixture.make(prefix: "scan-02-\(count)")
            defer { fixture.remove() }
            let vectors = (0..<count).map { index in
                (
                    chunkID: String(format: "large-candidate-%03d-731", index),
                    vector: [Float(1), Float(0), Float(0)]
                )
            }
            let documentID = try fixture.addDocument(
                id: "t-rag-scan-large-\(count)-731",
                vectors: vectors
            )
            let instrumentation = BoundedSemanticScanInstrumentation()
            let result = try BoundedSemanticScanner(
                store: fixture.store,
                instrumentation: instrumentation
            ).scan(
                matterID: fixture.matterID,
                documentIDs: [documentID],
                queryVector: [1, 0, 0],
                activeModel: fixture.activeModel,
                configuration: BoundedSemanticScanConfiguration(
                    pageSize: 3,
                    candidateLimit: 2,
                    minimumSimilarity: 0.5
                )
            )
            XCTAssertEqual(result.metrics.scannedRows, count)
            XCTAssertLessThanOrEqual(result.metrics.maximumLivePageRows, 3)
            XCTAssertLessThanOrEqual(result.metrics.maximumHeapEntries, 2)
            XCTAssertLessThanOrEqual(result.metrics.maximumLiveVectorBytes, 36)
            XCTAssertEqual(result.candidates.map(\.chunkID), [
                "large-candidate-000-731",
                "large-candidate-001-731",
            ])
            XCTAssertEqual(instrumentation.snapshot().currentLiveBytes, 0)
            XCTAssertFalse(result.candidates.map(\.chunkID).contains("DEFAULT-000"))
        }
    }

    func testCancellationReleasesPageAndHeapWithoutPublishingCandidates() throws {
        let fixture = try ArchitectureUXRagScanFixture.make(prefix: "scan-02-cancel")
        defer { fixture.remove() }
        let documentID = try fixture.addDocument(
            id: "t-rag-scan-cancel-731",
            vectors: (0..<17).map {
                (String(format: "cancel-candidate-%03d-731", $0), [Float(1), 0, 0])
            }
        )
        let instrumentation = BoundedSemanticScanInstrumentation()
        let cancellation = RagScanCancellation(afterChecks: 7)
        var publishedResult: BoundedSemanticScanResult?

        XCTAssertThrowsError(
            publishedResult = try BoundedSemanticScanner(
                store: fixture.store,
                instrumentation: instrumentation
            ).scan(
                matterID: fixture.matterID,
                documentIDs: [documentID],
                queryVector: [1, 0, 0],
                activeModel: fixture.activeModel,
                configuration: BoundedSemanticScanConfiguration(
                    pageSize: 3,
                    candidateLimit: 2,
                    minimumSimilarity: 0.5
                ),
                cancellationCheck: cancellation.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(publishedResult)
        let snapshot = instrumentation.snapshot()
        XCTAssertEqual(snapshot.currentLiveBytes, 0)
        XCTAssertEqual(snapshot.currentPageRows, 0)
        XCTAssertEqual(snapshot.currentHeapEntries, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumLivePageRows, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumHeapEntries, 2)
        XCTAssertLessThanOrEqual(snapshot.maximumLiveVectorBytes, 36)
        XCTAssertGreaterThan(snapshot.scannedRows, 0)
        XCTAssertLessThan(snapshot.scannedRows, 17)
        XCTAssertEqual(ArchitectureUXRagScanFixture.cacheCeilingBytes, 17)
        XCTAssertEqual(ArchitectureUXRagScanFixture.query, "QUERY_713")
        XCTAssertNotEqual(ArchitectureUXRagScanFixture.candidateK, 60)
    }

    func testHostedAppAndXPCResourceEnvelopeIsWiredToTheExactScan() throws {
        let metricsSource = try source(
            "Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/DTOs/RuntimeMetrics.swift"
        )
        let serviceSource = try source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )
        let probeSource = try source(
            "Packages/SupraSessions/Sources/SupraSessions/BoundedSemanticScanner.swift"
        )
        let viewSource = try source(
            "Apps/SupraAI/SupraAI/RuntimeXPCIntegrationView.swift"
        )
        let hostedTestSource = try source(
            "Apps/SupraAI/SupraAIUITests/RuntimeXPCIntegrationTests.swift"
        )

        XCTAssertTrue(
            metricsSource.contains("public let currentMemoryMb: Int?"),
            "Expected RED: XPC status exposes only peak memory, so combined current usage cannot be measured"
        )
        XCTAssertTrue(
            serviceSource.contains("currentMemoryMb: Self.currentResidentMiB()"),
            "Expected RED: the hosted XPC does not publish current resident memory"
        )
        for exactWire in [
            "public struct HostedRAGScanResourceProbe",
            "T_RAG_SCAN_02_WIRE_731",
            "QUERY_713",
            "pageSize: 3",
            "candidateLimit: 2",
            "cacheCeilingBytes: 17",
        ] {
            XCTAssertTrue(
                probeSource.contains(exactWire),
                "Expected RED: missing hosted RAG resource probe wire \(exactWire)"
            )
        }
        for exactWire in [
            "scenario == \"rag-scan\"",
            "HostedRAGScanResourceProbe",
            "runtimeXPCIntegration.ragScan.result",
            "runtimeXPCIntegration.ragScan.combinedPeakDeltaMiB",
        ] {
            XCTAssertTrue(
                viewSource.contains(exactWire),
                "Expected RED: hosted app/XPC surface is missing \(exactWire)"
            )
        }
        XCTAssertTrue(
            hostedTestSource.contains("func testBoundedLargeCorpusRAGResourceEnvelope()"),
            "the signed hosted test must execute the app/XPC resource scenario"
        )
        XCTAssertTrue(
            hostedTestSource.contains(
                #"let app = launchIntegrationApp(scenario: "rag-scan")"#
            )
        )
        XCTAssertTrue(hostedTestSource.contains("T_RAG_SCAN_02_WIRE_731"))
        XCTAssertTrue(
            hostedTestSource.contains(
                #"XCTAssertFalse(detail.contains("T_RAG_SCAN_02_DEFAULT-000"))"#
            )
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }
}

private final class RagScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let afterChecks: Int
    private var checks = 0

    init(afterChecks: Int) {
        self.afterChecks = afterChecks
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        if checks > afterChecks { throw CancellationError() }
    }
}
