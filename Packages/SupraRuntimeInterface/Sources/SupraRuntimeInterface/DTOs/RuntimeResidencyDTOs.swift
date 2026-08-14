import Foundation

/// Content-free runtime facts used by the app-side residency authority. The
/// service reports only stable artifact identity and bounded resource counts;
/// paths, prompts, and model bytes never cross this control-plane response.
public enum RuntimeServiceResidentKind: String, Codable, Equatable, Sendable {
    case chat
    case embedding
    case reranker
}

public struct RuntimeServiceResidentArtifact: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let kind: RuntimeServiceResidentKind
    public let estimatedBytes: Int
    public let isActive: Bool
    public let lastUseSequence: UInt64

    public init(
        modelID: String,
        revision: String,
        kind: RuntimeServiceResidentKind,
        estimatedBytes: Int,
        isActive: Bool,
        lastUseSequence: UInt64
    ) {
        self.modelID = modelID
        self.revision = revision
        self.kind = kind
        self.estimatedBytes = estimatedBytes
        self.isActive = isActive
        self.lastUseSequence = lastUseSequence
    }
}

public struct RuntimeServiceResidencySnapshot: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let unifiedMemoryCeilingBytes: Int
    public let fixedResidentBytes: Int
    public let replayGenerationCount: Int
    public let bufferedEventCount: Int
    public let residents: [RuntimeServiceResidentArtifact]
    public let activeTaskCount: Int

    public init(
        epoch: UInt64,
        unifiedMemoryCeilingBytes: Int,
        fixedResidentBytes: Int,
        replayGenerationCount: Int,
        bufferedEventCount: Int,
        residents: [RuntimeServiceResidentArtifact],
        activeTaskCount: Int
    ) {
        self.epoch = epoch
        self.unifiedMemoryCeilingBytes = unifiedMemoryCeilingBytes
        self.fixedResidentBytes = fixedResidentBytes
        self.replayGenerationCount = replayGenerationCount
        self.bufferedEventCount = bufferedEventCount
        self.residents = residents
        self.activeTaskCount = activeTaskCount
    }
}

public struct RuntimeServiceArtifactEvictionRequest: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let kind: RuntimeServiceResidentKind

    public init(modelID: String, revision: String, kind: RuntimeServiceResidentKind) {
        self.modelID = modelID
        self.revision = revision
        self.kind = kind
    }
}

public struct RuntimeServiceArtifactEvictionResponse: Codable, Equatable, Sendable {
    public let evictedModelID: String?
    public let error: RuntimeError?

    public init(evictedModelID: String?, error: RuntimeError?) {
        self.evictedModelID = evictedModelID
        self.error = error
    }
}

public struct RuntimeServiceResetRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let expectedEpoch: UInt64

    public init(requestID: String, expectedEpoch: UInt64) {
        self.requestID = requestID
        self.expectedEpoch = expectedEpoch
    }
}

public struct RuntimeServiceResetReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let previousEpoch: UInt64
    public let newEpoch: UInt64
    public let unloadedChatModelIDs: [String]
    public let unloadedEmbeddingModelIDs: [String]
    public let clearedReplayGenerationCount: Int
    public let clearedBufferedEventCount: Int

    public init(
        requestID: String,
        previousEpoch: UInt64,
        newEpoch: UInt64,
        unloadedChatModelIDs: [String],
        unloadedEmbeddingModelIDs: [String],
        clearedReplayGenerationCount: Int,
        clearedBufferedEventCount: Int
    ) {
        self.requestID = requestID
        self.previousEpoch = previousEpoch
        self.newEpoch = newEpoch
        self.unloadedChatModelIDs = unloadedChatModelIDs
        self.unloadedEmbeddingModelIDs = unloadedEmbeddingModelIDs
        self.clearedReplayGenerationCount = clearedReplayGenerationCount
        self.clearedBufferedEventCount = clearedBufferedEventCount
    }
}

public struct RuntimeServiceResetResponse: Codable, Equatable, Sendable {
    public let receipt: RuntimeServiceResetReceipt?
    public let error: RuntimeError?

    public init(receipt: RuntimeServiceResetReceipt?, error: RuntimeError?) {
        self.receipt = receipt
        self.error = error
    }
}
