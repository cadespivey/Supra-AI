import Foundation

public struct RuntimeStreamBufferPolicy: Equatable, Sendable {
    public let wireID: String
    public let modelArtifactID: String
    public let modelRevision: String
    public let maxReplayEventCount: Int
    public let maxReplayEncodedBytes: Int
    public let maxUIChunkUTF8Bytes: Int
    public let maxPersistenceBatchUTF8Bytes: Int
    public let coalescingWindow: Duration
    public let coalescingUTF8Bytes: Int

    public init(
        wireID: String,
        modelArtifactID: String,
        modelRevision: String,
        maxReplayEventCount: Int,
        maxReplayEncodedBytes: Int,
        maxUIChunkUTF8Bytes: Int,
        maxPersistenceBatchUTF8Bytes: Int,
        coalescingWindow: Duration,
        coalescingUTF8Bytes: Int
    ) {
        self.wireID = wireID
        self.modelArtifactID = modelArtifactID
        self.modelRevision = modelRevision
        self.maxReplayEventCount = max(1, maxReplayEventCount)
        self.maxReplayEncodedBytes = max(1, maxReplayEncodedBytes)
        self.maxUIChunkUTF8Bytes = max(1, maxUIChunkUTF8Bytes)
        self.maxPersistenceBatchUTF8Bytes = max(1, maxPersistenceBatchUTF8Bytes)
        self.coalescingWindow = coalescingWindow
        self.coalescingUTF8Bytes = max(1, coalescingUTF8Bytes)
    }

    public static let production = RuntimeStreamBufferPolicy(
        wireID: "runtime-stream-v1",
        modelArtifactID: "runtime-bound-model",
        modelRevision: "runtime-bound-revision",
        maxReplayEventCount: 256,
        maxReplayEncodedBytes: 2 * 1_024 * 1_024,
        maxUIChunkUTF8Bytes: 16 * 1_024,
        maxPersistenceBatchUTF8Bytes: 64 * 1_024,
        coalescingWindow: .milliseconds(16),
        coalescingUTF8Bytes: 8 * 1_024
    )
}

public enum RuntimeStreamFlushReason: Equatable, Sendable {
    case completion
    case cancellation
    case reconnect
    case terminal(GenerationEventType)
}

public struct RuntimeStreamBufferSnapshot: Equatable, Sendable {
    public let retainedReplayEventCount: Int
    public let retainedReplayEncodedBytes: Int
    public let retainedSequenceNumbers: [Int]
}

public struct RuntimeStreamFlushReceipt: Equatable, Sendable {
    public let wireID: String
    public let modelArtifactID: String
    public let modelRevision: String
    public let finalOutputUTF8: Data
    public let coalescedUIChunks: [String]
    public let persistenceBatches: [Data]
    public let retainedReplayEventCount: Int
    public let retainedReplayEncodedBytes: Int
    public let maximumUIChunkUTF8Bytes: Int
    public let maximumPersistenceBatchUTF8Bytes: Int
    public let terminalEventType: GenerationEventType?
}

public struct RuntimeGenerationStreamBuffer: Sendable {
    public let policy: RuntimeStreamBufferPolicy

    private var seenSequenceNumbers: Set<Int> = []
    private var retainedReplay: [(event: GenerationEvent, encodedBytes: Int)] = []
    private var retainedReplayEncodedBytes = 0
    private var tokenSegments: [String] = []
    private var pendingUI = ""
    private var pendingUIStartedAt: Date?
    private var coalescedUIChunks: [String] = []
    private var pendingPersistence = Data()
    private var persistenceBatches: [Data] = []
    private var maximumUIChunkUTF8Bytes = 0
    private var maximumPersistenceBatchUTF8Bytes = 0
    private var terminalEventType: GenerationEventType?

    public init(policy: RuntimeStreamBufferPolicy) {
        self.policy = policy
    }

    public var snapshot: RuntimeStreamBufferSnapshot {
        RuntimeStreamBufferSnapshot(
            retainedReplayEventCount: retainedReplay.count,
            retainedReplayEncodedBytes: retainedReplayEncodedBytes,
            retainedSequenceNumbers: retainedReplay.map(\.event.sequenceNumber)
        )
    }

    public mutating func ingest(_ event: GenerationEvent) throws {
        guard seenSequenceNumbers.insert(event.sequenceNumber).inserted else {
            return
        }

        let encodedBytes = try RuntimeXPCCodec.encode(event).count
        retainedReplay.append((event, encodedBytes))
        retainedReplayEncodedBytes += encodedBytes
        compactReplayIfNeeded()

        if let token = event.tokenText, !token.isEmpty {
            tokenSegments.append(token)
            appendUI(token, at: event.timestamp)
            appendPersistence(Data(token.utf8))
        }

        if event.type.isTerminal {
            terminalEventType = event.type
            flushPendingUI()
            flushPendingPersistence()
        }
    }

    public mutating func ingestReplay(_ events: [GenerationEvent]) throws {
        for event in events.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            try ingest(event)
        }
    }

    public mutating func flush(_ reason: RuntimeStreamFlushReason) throws -> RuntimeStreamFlushReceipt {
        switch reason {
        case .completion:
            terminalEventType = terminalEventType ?? .generationCompleted
        case .cancellation:
            terminalEventType = terminalEventType ?? .generationCancelled
        case .reconnect:
            break
        case let .terminal(type):
            terminalEventType = type
        }
        flushPendingUI()
        flushPendingPersistence()
        let finalOutput = tokenSegments.joined()
        return RuntimeStreamFlushReceipt(
            wireID: policy.wireID,
            modelArtifactID: policy.modelArtifactID,
            modelRevision: policy.modelRevision,
            finalOutputUTF8: Data(finalOutput.utf8),
            coalescedUIChunks: coalescedUIChunks,
            persistenceBatches: persistenceBatches,
            retainedReplayEventCount: retainedReplay.count,
            retainedReplayEncodedBytes: retainedReplayEncodedBytes,
            maximumUIChunkUTF8Bytes: maximumUIChunkUTF8Bytes,
            maximumPersistenceBatchUTF8Bytes: maximumPersistenceBatchUTF8Bytes,
            terminalEventType: terminalEventType
        )
    }

    private mutating func appendUI(_ token: String, at timestamp: Date) {
        let tokenBytes = token.utf8.count
        if tokenBytes > policy.maxUIChunkUTF8Bytes {
            flushPendingUI()
            for piece in token.utf8Chunks(maximumBytes: policy.maxUIChunkUTF8Bytes) {
                appendCompletedUI(piece)
            }
            return
        }
        if pendingUI.isEmpty {
            pendingUI = token
            pendingUIStartedAt = timestamp
            return
        }
        let elapsed = timestamp.timeIntervalSince(pendingUIStartedAt ?? timestamp)
        let withinWindow = elapsed <= policy.coalescingWindow.timeInterval
        let nextBytes = pendingUI.utf8.count + tokenBytes
        let withinCoalescingLimit = nextBytes <= policy.coalescingUTF8Bytes
        let withinUIChunkLimit = nextBytes <= policy.maxUIChunkUTF8Bytes
        if withinWindow, withinCoalescingLimit, withinUIChunkLimit {
            pendingUI.append(token)
        } else {
            flushPendingUI()
            pendingUI = token
            pendingUIStartedAt = timestamp
        }
    }

    private mutating func flushPendingUI() {
        guard !pendingUI.isEmpty else { return }
        appendCompletedUI(pendingUI)
        pendingUI = ""
        pendingUIStartedAt = nil
    }

    private mutating func appendCompletedUI(_ chunk: String) {
        coalescedUIChunks.append(chunk)
        maximumUIChunkUTF8Bytes = max(maximumUIChunkUTF8Bytes, chunk.utf8.count)
    }

    private mutating func appendPersistence(_ bytes: Data) {
        if bytes.count > policy.maxPersistenceBatchUTF8Bytes {
            flushPendingPersistence()
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + policy.maxPersistenceBatchUTF8Bytes)
                appendCompletedPersistence(bytes.subdata(in: offset..<end))
                offset = end
            }
            return
        }
        if pendingPersistence.count + bytes.count > policy.maxPersistenceBatchUTF8Bytes {
            flushPendingPersistence()
        }
        pendingPersistence.append(bytes)
    }

    private mutating func flushPendingPersistence() {
        guard !pendingPersistence.isEmpty else { return }
        appendCompletedPersistence(pendingPersistence)
        pendingPersistence = Data()
    }

    private mutating func appendCompletedPersistence(_ batch: Data) {
        persistenceBatches.append(batch)
        maximumPersistenceBatchUTF8Bytes = max(
            maximumPersistenceBatchUTF8Bytes,
            batch.count
        )
    }

    private mutating func compactReplayIfNeeded() {
        while retainedReplay.count > policy.maxReplayEventCount
            || retainedReplayEncodedBytes > policy.maxReplayEncodedBytes {
            guard retainedReplay.count > 1 else { break }
            retainedReplayEncodedBytes -= retainedReplay.removeFirst().encodedBytes
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private extension String {
    func utf8Chunks(maximumBytes: Int) -> [String] {
        guard utf8.count > maximumBytes else { return [self] }
        var chunks: [String] = []
        var current = ""
        for scalar in unicodeScalars {
            let value = String(scalar)
            if !current.isEmpty, current.utf8.count + value.utf8.count > maximumBytes {
                chunks.append(current)
                current = ""
            }
            current.append(value)
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

private extension GenerationEventType {
    var isTerminal: Bool {
        self == .generationCompleted || self == .generationCancelled || self == .generationFailed
    }
}
