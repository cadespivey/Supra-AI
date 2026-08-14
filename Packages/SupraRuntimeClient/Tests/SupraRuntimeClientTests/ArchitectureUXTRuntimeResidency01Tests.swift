import Foundation
@testable import SupraRuntimeClient
import XCTest

/// T-RUNTIME-RESIDENCY-01
///
/// Expected RED before WP-3.4: no process-wide residency snapshot or policy
/// gates speculative prewarm, and ModelLibrary schedules prewarm directly.
final class ArchitectureUXTRuntimeResidency01Tests: XCTestCase {
    func testTightProfileEvictsInactiveEmbeddingBeforeAdmittingChatPrewarm() throws {
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 700,
            residents: [ArchitectureUXRuntimeResidencyWire.embeddingArtifact]
        )
        let request = RuntimePrewarmRequest(
            wireID: "T_RUNTIME_RESIDENCY_01_WIRE_731",
            artifact: ArchitectureUXRuntimeResidencyWire.chatArtifact,
            workClass: .speculative
        )
        let plan = try RuntimeResidencyPolicy(maximumActions: 7)
            .prewarmPlan(request: request, snapshot: snapshot)

        XCTAssertEqual(plan.wireID, "T_RUNTIME_RESIDENCY_01_WIRE_731")
        XCTAssertEqual(plan.disposition, .admittedAfterEviction)
        XCTAssertEqual(plan.actions, [
            .evictEmbeddingModel(
                id: "embedding-wire-719",
                revision: "embed-rev-7"
            ),
        ])
        XCTAssertEqual(plan.plannedPeakBytes, 650)
        XCTAssertLessThanOrEqual(plan.plannedPeakBytes, snapshot.unifiedMemoryCeilingBytes)
        XCTAssertFalse(String(describing: plan).contains("DEFAULT-000"))
        XCTAssertFalse(String(describing: plan).contains("default priority"))
    }

    func testActiveEmbeddingBlocksEvictionAndSpeculativePrewarm() throws {
        let activeEmbedding = RuntimeResidentArtifact(
            modelID: "embedding-wire-719",
            revision: "embed-rev-7",
            kind: .embedding,
            estimatedBytes: 200,
            isActive: true,
            lastUseSequence: 8
        )
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 700,
            residents: [activeEmbedding]
        )
        let plan = try RuntimeResidencyPolicy(maximumActions: 7).prewarmPlan(
            request: RuntimePrewarmRequest(
                wireID: "T_RUNTIME_RESIDENCY_01_WIRE_731",
                artifact: ArchitectureUXRuntimeResidencyWire.chatArtifact,
                workClass: .speculative
            ),
            snapshot: snapshot
        )

        XCTAssertEqual(plan.disposition, .deniedActiveResidency)
        XCTAssertEqual(plan.actions, [])
        XCTAssertEqual(plan.plannedPeakBytes, 850)
    }

    func testExactHeadroomAdmitsWithoutEviction() throws {
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 850,
            residents: [ArchitectureUXRuntimeResidencyWire.embeddingArtifact]
        )
        let plan = try RuntimeResidencyPolicy(maximumActions: 7).prewarmPlan(
            request: RuntimePrewarmRequest(
                wireID: "T_RUNTIME_RESIDENCY_01_WIRE_731",
                artifact: ArchitectureUXRuntimeResidencyWire.chatArtifact,
                workClass: .speculative
            ),
            snapshot: snapshot
        )

        XCTAssertEqual(plan.disposition, .admitted)
        XCTAssertEqual(plan.actions, [])
        XCTAssertEqual(plan.plannedPeakBytes, 850)
    }

    func testShippingPrewarmUsesResidencyOwner() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Packages/SupraSessions/Sources/SupraSessions/ModelLibrary.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("runtimeResidencyCoordinator.requestPrewarm("))
        XCTAssertFalse(source.contains("Task { await library.activateAndLoad"))
        XCTAssertFalse(source.contains("DEFAULT-000"))
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}
