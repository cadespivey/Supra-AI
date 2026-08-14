@testable import SupraRuntimeClient
import XCTest

/// T-RUNTIME-RESET-01
///
/// Expected RED before WP-3.4: restart only replaces an XPC connection; no
/// authoritative reset receipt proves containers and buffers cleared or epoch
/// advancement.
final class ArchitectureUXTRuntimeReset01Tests: XCTestCase {
    func testActiveWorkRefusesResetWithoutEpochOrStateMutation() async throws {
        let active = RuntimeResidentArtifact(
            modelID: "model-wire-713",
            revision: "rev-7",
            kind: .chat,
            estimatedBytes: 250,
            isActive: true,
            lastUseSequence: 7
        )
        let before = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 1_200,
            residents: [active]
        )
        let controlPlane = ArchitectureUXRuntimeResidencyControlPlane(snapshot: before)
        let coordinator = RuntimeResidencyCoordinator(
            controlPlane: controlPlane,
            policy: RuntimeResidencyPolicy(maximumActions: 7)
        )

        do {
            _ = try await coordinator.reset(
                RuntimeResetRequest(
                    requestID: "T_RUNTIME_RESET_01_WIRE_731",
                    expectedEpoch: 7
                )
            )
            XCTFail("active runtime work must prevent reset")
        } catch {
            XCTAssertEqual(
                error as? RuntimeResidencyError,
                .activeWorkPreventsReset(activeTaskCount: 1)
            )
        }
        let after = await controlPlane.snapshotForAssertion()
        XCTAssertEqual(after, before)
    }

    func testIdleResetClearsResidencyBuffersCachesAndAdvancesEpochOnce() async throws {
        let before = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 1_200,
            residents: [
                ArchitectureUXRuntimeResidencyWire.chatArtifact,
                ArchitectureUXRuntimeResidencyWire.embeddingArtifact,
            ]
        )
        let controlPlane = ArchitectureUXRuntimeResidencyControlPlane(snapshot: before)
        let coordinator = RuntimeResidencyCoordinator(
            controlPlane: controlPlane,
            policy: RuntimeResidencyPolicy(maximumActions: 7)
        )
        let request = RuntimeResetRequest(
            requestID: "T_RUNTIME_RESET_01_WIRE_731",
            expectedEpoch: 7
        )
        let receipt = try await coordinator.reset(request)
        let retry = try await coordinator.reset(request)

        XCTAssertEqual(receipt, retry)
        XCTAssertEqual(receipt.previousEpoch, 7)
        XCTAssertEqual(receipt.newEpoch, 8)
        XCTAssertEqual(receipt.unloadedChatModelIDs, ["model-wire-713"])
        XCTAssertEqual(receipt.unloadedEmbeddingModelIDs, ["embedding-wire-719"])
        XCTAssertEqual(receipt.purgedDerivedCacheBytes, 17)
        XCTAssertEqual(receipt.clearedReplayGenerationCount, 3)
        XCTAssertEqual(receipt.clearedBufferedEventCount, 7)

        let after = await controlPlane.snapshotForAssertion()
        XCTAssertEqual(after.epoch, 8)
        XCTAssertEqual(after.residents, [])
        XCTAssertEqual(after.derivedCacheBytes, 0)
        XCTAssertEqual(after.replayGenerationCount, 0)
        XCTAssertEqual(after.bufferedEventCount, 0)
        XCTAssertFalse(String(describing: receipt).contains("DEFAULT-000"))
    }

    func testDistinctResetRequestAdvancesExactlyOneAdditionalEpoch() async throws {
        let controlPlane = ArchitectureUXRuntimeResidencyControlPlane(
            snapshot: ArchitectureUXRuntimeResidencyWire.snapshot(
                ceiling: 1_200,
                residents: []
            )
        )
        let coordinator = RuntimeResidencyCoordinator(
            controlPlane: controlPlane,
            policy: RuntimeResidencyPolicy(maximumActions: 7)
        )
        let first = try await coordinator.reset(RuntimeResetRequest(
            requestID: "T_RUNTIME_RESET_01_WIRE_731",
            expectedEpoch: 7
        ))
        XCTAssertEqual(first.newEpoch, 8)
        let second = try await coordinator.reset(RuntimeResetRequest(
            requestID: "T_RUNTIME_RESET_01_WIRE_739",
            expectedEpoch: 8
        ))

        XCTAssertEqual(second.previousEpoch, 8)
        XCTAssertEqual(second.newEpoch, 9)
    }
}
