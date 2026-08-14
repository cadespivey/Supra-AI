import Foundation
import SupraRuntimeClient
import SupraRuntimeInterface

/// Shipping adapter joining the XPC service's authoritative model/buffer facts,
/// the one process-wide model scheduler, and every live derived RAG cache. It
/// owns no legal workflow state and never treats caches as authoritative work.
public final class ProcessRuntimeResidencyControlPlane: RuntimeResidencyControlPlane,
    @unchecked Sendable {
    private let runtimeClient: any RuntimeResidencyClientProtocol
    private let modelExecutionCoordinator: ModelExecutionCoordinator
    private let cacheRegistry: RAGDerivedCacheRegistry
    private let pressureLock = NSLock()
    private var pressure: RuntimeMemoryPressureLevel = .normal

    public convenience init(
        runtimeClient: any RuntimeResidencyClientProtocol,
        modelExecutionCoordinator: ModelExecutionCoordinator
    ) {
        self.init(
            runtimeClient: runtimeClient,
            modelExecutionCoordinator: modelExecutionCoordinator,
            cacheRegistry: .shared
        )
    }

    init(
        runtimeClient: any RuntimeResidencyClientProtocol,
        modelExecutionCoordinator: ModelExecutionCoordinator,
        cacheRegistry: RAGDerivedCacheRegistry
    ) {
        self.runtimeClient = runtimeClient
        self.modelExecutionCoordinator = modelExecutionCoordinator
        self.cacheRegistry = cacheRegistry
    }

    public func setMemoryPressure(_ level: RuntimeMemoryPressureLevel) {
        pressureLock.withLock { pressure = level }
    }

    public func residencySnapshot() async throws -> RuntimeResidencySnapshot {
        let service = try await runtimeClient.runtimeResidencySnapshot()
        let schedulerActive = await modelExecutionCoordinator.runtimeResidencyActiveTaskCount
        return RuntimeResidencySnapshot(
            epoch: service.epoch,
            pressure: pressureLock.withLock { pressure },
            unifiedMemoryCeilingBytes: service.unifiedMemoryCeilingBytes,
            fixedResidentBytes: service.fixedResidentBytes,
            derivedCacheBytes: cacheRegistry.totalBytes(),
            replayGenerationCount: service.replayGenerationCount,
            bufferedEventCount: service.bufferedEventCount,
            residents: service.residents.map(Self.artifact),
            activeTaskCount: max(service.activeTaskCount, schedulerActive)
        )
    }

    public func apply(_ action: RuntimeResidencyAction) async throws {
        switch action {
        case let .cancelQueuedWork(ids):
            for id in ids {
                await modelExecutionCoordinator.cancel(
                    taskID: ModelExecutionTaskID(rawValue: id)
                )
            }
        case .purgeDerivedCaches:
            cacheRegistry.purgeAll()
        case let .evictEmbeddingModel(id, revision):
            _ = try await runtimeClient.evictRuntimeArtifact(
                RuntimeServiceArtifactEvictionRequest(
                    modelID: id,
                    revision: revision,
                    kind: .embedding
                )
            )
        case let .evictChatModel(id, revision):
            _ = try await runtimeClient.evictRuntimeArtifact(
                RuntimeServiceArtifactEvictionRequest(
                    modelID: id,
                    revision: revision,
                    kind: .chat
                )
            )
        case let .evictRerankerModel(id, revision):
            _ = try await runtimeClient.evictRuntimeArtifact(
                RuntimeServiceArtifactEvictionRequest(
                    modelID: id,
                    revision: revision,
                    kind: .reranker
                )
            )
        }
    }

    public func resetRuntime(_ request: RuntimeResetRequest) async throws -> RuntimeResetReceipt {
        let schedulerActive = await modelExecutionCoordinator.runtimeResidencyActiveTaskCount
        let schedulerQueued = await modelExecutionCoordinator.queuedTaskCount
        let schedulerWork = schedulerActive + schedulerQueued
        guard schedulerWork == 0 else {
            throw RuntimeResidencyError.activeWorkPreventsReset(
                activeTaskCount: schedulerWork
            )
        }
        let cacheBytes = cacheRegistry.totalBytes()
        let serviceReceipt = try await runtimeClient.resetRuntime(
            RuntimeServiceResetRequest(
                requestID: request.requestID,
                expectedEpoch: request.expectedEpoch
            )
        )
        cacheRegistry.purgeAll()
        pressureLock.withLock { pressure = .normal }
        return RuntimeResetReceipt(
            requestID: serviceReceipt.requestID,
            previousEpoch: serviceReceipt.previousEpoch,
            newEpoch: serviceReceipt.newEpoch,
            unloadedChatModelIDs: serviceReceipt.unloadedChatModelIDs,
            unloadedEmbeddingModelIDs: serviceReceipt.unloadedEmbeddingModelIDs,
            purgedDerivedCacheBytes: cacheBytes,
            clearedReplayGenerationCount: serviceReceipt.clearedReplayGenerationCount,
            clearedBufferedEventCount: serviceReceipt.clearedBufferedEventCount
        )
    }

    private static func artifact(
        _ value: RuntimeServiceResidentArtifact
    ) -> RuntimeResidentArtifact {
        let kind: RuntimeResidentModelKind
        switch value.kind {
        case .chat: kind = .chat
        case .embedding: kind = .embedding
        case .reranker: kind = .reranker
        }
        return RuntimeResidentArtifact(
            modelID: value.modelID,
            revision: value.revision,
            kind: kind,
            estimatedBytes: value.estimatedBytes,
            isActive: value.isActive,
            lastUseSequence: value.lastUseSequence
        )
    }
}
