import Foundation
import SupraRuntimeClient

enum ArchitectureUXRuntimeResidencyWire {
    static let chatArtifact = RuntimeResidentArtifact(
        modelID: "model-wire-713",
        revision: "rev-7",
        kind: .chat,
        estimatedBytes: 250,
        isActive: false,
        lastUseSequence: 7
    )

    static let embeddingArtifact = RuntimeResidentArtifact(
        modelID: "embedding-wire-719",
        revision: "embed-rev-7",
        kind: .embedding,
        estimatedBytes: 200,
        isActive: false,
        lastUseSequence: 6
    )

    static func snapshot(
        ceiling: Int,
        residents: [RuntimeResidentArtifact],
        pressure: RuntimeMemoryPressureLevel = .normal,
        epoch: UInt64 = 7
    ) -> RuntimeResidencySnapshot {
        RuntimeResidencySnapshot(
            epoch: epoch,
            pressure: pressure,
            unifiedMemoryCeilingBytes: ceiling,
            fixedResidentBytes: 400,
            derivedCacheBytes: 17,
            replayGenerationCount: 3,
            bufferedEventCount: 7,
            residents: residents,
            activeTaskCount: residents.filter(\.isActive).count
        )
    }
}

actor ArchitectureUXRuntimeResidencyControlPlane: RuntimeResidencyControlPlane {
    private var currentSnapshot: RuntimeResidencySnapshot
    private var appliedActions: [RuntimeResidencyAction] = []
    private var resetReceipts: [String: RuntimeResetReceipt] = [:]

    init(snapshot: RuntimeResidencySnapshot) {
        currentSnapshot = snapshot
    }

    func residencySnapshot() async throws -> RuntimeResidencySnapshot {
        currentSnapshot
    }

    func apply(_ action: RuntimeResidencyAction) async throws {
        appliedActions.append(action)
    }

    func resetRuntime(_ request: RuntimeResetRequest) async throws -> RuntimeResetReceipt {
        if let receipt = resetReceipts[request.requestID] { return receipt }
        guard currentSnapshot.activeTaskCount == 0 else {
            throw RuntimeResidencyError.activeWorkPreventsReset(
                activeTaskCount: currentSnapshot.activeTaskCount
            )
        }
        guard request.expectedEpoch == currentSnapshot.epoch else {
            throw RuntimeResidencyError.epochMismatch(
                expected: request.expectedEpoch,
                actual: currentSnapshot.epoch
            )
        }
        let receipt = RuntimeResetReceipt(
            requestID: request.requestID,
            previousEpoch: currentSnapshot.epoch,
            newEpoch: currentSnapshot.epoch + 1,
            unloadedChatModelIDs: currentSnapshot.residents
                .filter { $0.kind == .chat }
                .map(\.modelID)
                .sorted(),
            unloadedEmbeddingModelIDs: currentSnapshot.residents
                .filter { $0.kind == .embedding }
                .map(\.modelID)
                .sorted(),
            purgedDerivedCacheBytes: currentSnapshot.derivedCacheBytes,
            clearedReplayGenerationCount: currentSnapshot.replayGenerationCount,
            clearedBufferedEventCount: currentSnapshot.bufferedEventCount
        )
        currentSnapshot = RuntimeResidencySnapshot(
            epoch: receipt.newEpoch,
            pressure: .normal,
            unifiedMemoryCeilingBytes: currentSnapshot.unifiedMemoryCeilingBytes,
            fixedResidentBytes: currentSnapshot.fixedResidentBytes,
            derivedCacheBytes: 0,
            replayGenerationCount: 0,
            bufferedEventCount: 0,
            residents: [],
            activeTaskCount: 0
        )
        resetReceipts[request.requestID] = receipt
        return receipt
    }

    func actions() -> [RuntimeResidencyAction] { appliedActions }
    func snapshotForAssertion() -> RuntimeResidencySnapshot { currentSnapshot }
}
