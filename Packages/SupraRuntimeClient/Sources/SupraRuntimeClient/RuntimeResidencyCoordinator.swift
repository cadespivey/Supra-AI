import Foundation

public enum RuntimeMemoryPressureLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

public enum RuntimeResidentModelKind: String, Codable, Equatable, Sendable {
    case chat
    case embedding
    case reranker
}

public enum RuntimeResidencyWorkClass: String, Codable, Equatable, Hashable, Sendable {
    case foreground
    case userInitiated
    case background
    case speculative

    fileprivate var isNonessential: Bool {
        self == .background || self == .speculative
    }
}

public struct RuntimeResidentArtifact: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let kind: RuntimeResidentModelKind
    public let estimatedBytes: Int
    public let isActive: Bool
    public let lastUseSequence: UInt64

    public init(
        modelID: String,
        revision: String,
        kind: RuntimeResidentModelKind,
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

public struct RuntimeResidencySnapshot: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let pressure: RuntimeMemoryPressureLevel
    public let unifiedMemoryCeilingBytes: Int
    public let fixedResidentBytes: Int
    public let derivedCacheBytes: Int
    public let replayGenerationCount: Int
    public let bufferedEventCount: Int
    public let residents: [RuntimeResidentArtifact]
    public let activeTaskCount: Int

    public init(
        epoch: UInt64,
        pressure: RuntimeMemoryPressureLevel,
        unifiedMemoryCeilingBytes: Int,
        fixedResidentBytes: Int,
        derivedCacheBytes: Int,
        replayGenerationCount: Int,
        bufferedEventCount: Int,
        residents: [RuntimeResidentArtifact],
        activeTaskCount: Int
    ) {
        self.epoch = epoch
        self.pressure = pressure
        self.unifiedMemoryCeilingBytes = unifiedMemoryCeilingBytes
        self.fixedResidentBytes = fixedResidentBytes
        self.derivedCacheBytes = derivedCacheBytes
        self.replayGenerationCount = replayGenerationCount
        self.bufferedEventCount = bufferedEventCount
        self.residents = residents
        self.activeTaskCount = activeTaskCount
    }
}

public struct RuntimePrewarmRequest: Equatable, Sendable {
    public let wireID: String
    public let artifact: RuntimeResidentArtifact
    public let workClass: RuntimeResidencyWorkClass

    public init(
        wireID: String,
        artifact: RuntimeResidentArtifact,
        workClass: RuntimeResidencyWorkClass
    ) {
        self.wireID = wireID
        self.artifact = artifact
        self.workClass = workClass
    }
}

public struct RuntimeQueuedResidencyWork: Equatable, Sendable {
    public let id: String
    public let workClass: RuntimeResidencyWorkClass

    public init(id: String, workClass: RuntimeResidencyWorkClass) {
        self.id = id
        self.workClass = workClass
    }
}

public enum RuntimeResidencyAction: Equatable, Sendable {
    case cancelQueuedWork(ids: [String])
    case purgeDerivedCaches(bytes: Int)
    case evictEmbeddingModel(id: String, revision: String)
    case evictChatModel(id: String, revision: String)
    case evictRerankerModel(id: String, revision: String)
}

public enum RuntimePrewarmDisposition: String, Equatable, Sendable {
    case admitted
    case admittedAfterEviction
    case deniedPressure
    case deniedActiveResidency
    case deniedInsufficientHeadroom
}

public struct RuntimePrewarmPlan: Equatable, Sendable {
    public let wireID: String
    public let disposition: RuntimePrewarmDisposition
    public let actions: [RuntimeResidencyAction]
    public let plannedPeakBytes: Int

    init(
        wireID: String,
        disposition: RuntimePrewarmDisposition,
        actions: [RuntimeResidencyAction],
        plannedPeakBytes: Int
    ) {
        self.wireID = wireID
        self.disposition = disposition
        self.actions = actions
        self.plannedPeakBytes = plannedPeakBytes
    }
}

public struct RuntimePressurePlan: Equatable, Sendable {
    public let level: RuntimeMemoryPressureLevel
    public let actions: [RuntimeResidencyAction]
    public let deniedWorkClasses: [RuntimeResidencyWorkClass]

    init(
        level: RuntimeMemoryPressureLevel,
        actions: [RuntimeResidencyAction],
        deniedWorkClasses: [RuntimeResidencyWorkClass]
    ) {
        self.level = level
        self.actions = actions
        self.deniedWorkClasses = deniedWorkClasses
    }
}

public struct RuntimeResetRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let expectedEpoch: UInt64

    public init(requestID: String, expectedEpoch: UInt64) {
        self.requestID = requestID
        self.expectedEpoch = expectedEpoch
    }
}

public struct RuntimeResetReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let previousEpoch: UInt64
    public let newEpoch: UInt64
    public let unloadedChatModelIDs: [String]
    public let unloadedEmbeddingModelIDs: [String]
    public let purgedDerivedCacheBytes: Int
    public let clearedReplayGenerationCount: Int
    public let clearedBufferedEventCount: Int

    public init(
        requestID: String,
        previousEpoch: UInt64,
        newEpoch: UInt64,
        unloadedChatModelIDs: [String],
        unloadedEmbeddingModelIDs: [String],
        purgedDerivedCacheBytes: Int,
        clearedReplayGenerationCount: Int,
        clearedBufferedEventCount: Int
    ) {
        self.requestID = requestID
        self.previousEpoch = previousEpoch
        self.newEpoch = newEpoch
        self.unloadedChatModelIDs = unloadedChatModelIDs
        self.unloadedEmbeddingModelIDs = unloadedEmbeddingModelIDs
        self.purgedDerivedCacheBytes = purgedDerivedCacheBytes
        self.clearedReplayGenerationCount = clearedReplayGenerationCount
        self.clearedBufferedEventCount = clearedBufferedEventCount
    }
}

public enum RuntimeResidencyError: Error, Equatable, Sendable {
    case invalidSnapshot
    case invalidRequest
    case arithmeticOverflow
    case actionLimitExceeded(limit: Int, actual: Int)
    case activeWorkPreventsReset(activeTaskCount: Int)
    case epochMismatch(expected: UInt64, actual: UInt64)
    case invalidResetReceipt
}

public struct RuntimeResidencyPolicy: Sendable {
    public let maximumActions: Int

    public init(maximumActions: Int) {
        self.maximumActions = maximumActions
    }

    public func prewarmPlan(
        request: RuntimePrewarmRequest,
        snapshot: RuntimeResidencySnapshot
    ) throws -> RuntimePrewarmPlan {
        try validate(snapshot)
        guard maximumActions >= 0,
              Self.validIdentity(request.wireID),
              Self.valid(request.artifact) else {
            throw RuntimeResidencyError.invalidRequest
        }
        let startingPeak = try residentPeak(
            snapshot: snapshot,
            additionalBytes: request.artifact.estimatedBytes
        )
        if snapshot.pressure != .normal, request.workClass.isNonessential {
            return RuntimePrewarmPlan(
                wireID: request.wireID,
                disposition: .deniedPressure,
                actions: [],
                plannedPeakBytes: startingPeak
            )
        }
        if startingPeak <= snapshot.unifiedMemoryCeilingBytes {
            return RuntimePrewarmPlan(
                wireID: request.wireID,
                disposition: .admitted,
                actions: [],
                plannedPeakBytes: startingPeak
            )
        }

        var plannedPeak = startingPeak
        var actions: [RuntimeResidencyAction] = []
        for resident in evictionOrder(snapshot.residents) where !resident.isActive {
            plannedPeak -= resident.estimatedBytes
            actions.append(evictionAction(for: resident))
            if plannedPeak <= snapshot.unifiedMemoryCeilingBytes { break }
        }
        try validateActionCount(actions)
        if plannedPeak <= snapshot.unifiedMemoryCeilingBytes {
            return RuntimePrewarmPlan(
                wireID: request.wireID,
                disposition: .admittedAfterEviction,
                actions: actions,
                plannedPeakBytes: plannedPeak
            )
        }
        let activeResidencyBlocks = snapshot.residents.contains(where: \.isActive)
        return RuntimePrewarmPlan(
            wireID: request.wireID,
            disposition: activeResidencyBlocks
                ? .deniedActiveResidency
                : .deniedInsufficientHeadroom,
            actions: [],
            plannedPeakBytes: startingPeak
        )
    }

    public func pressurePlan(
        snapshot: RuntimeResidencySnapshot,
        queuedWork: [RuntimeQueuedResidencyWork]
    ) throws -> RuntimePressurePlan {
        try validate(snapshot)
        guard maximumActions >= 0,
              queuedWork.allSatisfy({ Self.validIdentity($0.id) }),
              Set(queuedWork.map(\.id)).count == queuedWork.count else {
            throw RuntimeResidencyError.invalidRequest
        }

        switch snapshot.pressure {
        case .normal:
            return RuntimePressurePlan(level: .normal, actions: [], deniedWorkClasses: [])
        case .warning:
            var actions: [RuntimeResidencyAction] = []
            if snapshot.derivedCacheBytes > 0 {
                actions.append(.purgeDerivedCaches(bytes: snapshot.derivedCacheBytes))
            }
            try validateActionCount(actions)
            return RuntimePressurePlan(
                level: .warning,
                actions: actions,
                deniedWorkClasses: [.background, .speculative]
            )
        case .critical:
            var actions: [RuntimeResidencyAction] = []
            let cancelledIDs = queuedWork
                .filter { $0.workClass.isNonessential }
                .map(\.id)
                .sorted()
            if !cancelledIDs.isEmpty {
                actions.append(.cancelQueuedWork(ids: cancelledIDs))
            }
            if snapshot.derivedCacheBytes > 0 {
                actions.append(.purgeDerivedCaches(bytes: snapshot.derivedCacheBytes))
            }
            actions.append(contentsOf: evictionOrder(snapshot.residents)
                .filter { !$0.isActive }
                .map(evictionAction(for:)))
            try validateActionCount(actions)
            return RuntimePressurePlan(
                level: .critical,
                actions: actions,
                deniedWorkClasses: [.background, .speculative]
            )
        }
    }

    private func validate(_ snapshot: RuntimeResidencySnapshot) throws {
        guard maximumActions >= 0,
              snapshot.unifiedMemoryCeilingBytes >= 0,
              snapshot.fixedResidentBytes >= 0,
              snapshot.derivedCacheBytes >= 0,
              snapshot.replayGenerationCount >= 0,
              snapshot.bufferedEventCount >= 0,
              snapshot.activeTaskCount >= 0,
              snapshot.residents.allSatisfy(Self.valid),
              Set(snapshot.residents.map { "\($0.kind.rawValue):\($0.modelID)" }).count
                == snapshot.residents.count else {
            throw RuntimeResidencyError.invalidSnapshot
        }
    }

    private func residentPeak(
        snapshot: RuntimeResidencySnapshot,
        additionalBytes: Int
    ) throws -> Int {
        var value = snapshot.fixedResidentBytes
        for bytes in snapshot.residents.map(\.estimatedBytes) + [additionalBytes] {
            let result = value.addingReportingOverflow(bytes)
            guard !result.overflow else { throw RuntimeResidencyError.arithmeticOverflow }
            value = result.partialValue
        }
        return value
    }

    private func validateActionCount(_ actions: [RuntimeResidencyAction]) throws {
        guard actions.count <= maximumActions else {
            throw RuntimeResidencyError.actionLimitExceeded(
                limit: maximumActions,
                actual: actions.count
            )
        }
    }

    private func evictionOrder(
        _ residents: [RuntimeResidentArtifact]
    ) -> [RuntimeResidentArtifact] {
        residents.sorted { lhs, rhs in
            let lhsKind = Self.evictionRank(lhs.kind)
            let rhsKind = Self.evictionRank(rhs.kind)
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            if lhs.lastUseSequence != rhs.lastUseSequence {
                return lhs.lastUseSequence < rhs.lastUseSequence
            }
            if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
            return lhs.revision < rhs.revision
        }
    }

    private func evictionAction(
        for resident: RuntimeResidentArtifact
    ) -> RuntimeResidencyAction {
        switch resident.kind {
        case .embedding:
            .evictEmbeddingModel(id: resident.modelID, revision: resident.revision)
        case .chat:
            .evictChatModel(id: resident.modelID, revision: resident.revision)
        case .reranker:
            .evictRerankerModel(id: resident.modelID, revision: resident.revision)
        }
    }

    private static func evictionRank(_ kind: RuntimeResidentModelKind) -> Int {
        switch kind {
        case .embedding: 0
        case .reranker: 1
        case .chat: 2
        }
    }

    private static func valid(_ artifact: RuntimeResidentArtifact) -> Bool {
        validIdentity(artifact.modelID)
            && validIdentity(artifact.revision)
            && artifact.estimatedBytes >= 0
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 256
    }
}

public protocol RuntimeResidencyControlPlane: Sendable {
    func residencySnapshot() async throws -> RuntimeResidencySnapshot
    func apply(_ action: RuntimeResidencyAction) async throws
    func resetRuntime(_ request: RuntimeResetRequest) async throws -> RuntimeResetReceipt
}

public actor RuntimeResidencyCoordinator {
    private let controlPlane: any RuntimeResidencyControlPlane
    private let policy: RuntimeResidencyPolicy

    public init(
        controlPlane: any RuntimeResidencyControlPlane,
        policy: RuntimeResidencyPolicy
    ) {
        self.controlPlane = controlPlane
        self.policy = policy
    }

    public func requestPrewarm(
        _ request: RuntimePrewarmRequest
    ) async throws -> RuntimePrewarmPlan {
        let snapshot = try await controlPlane.residencySnapshot()
        let plan = try policy.prewarmPlan(request: request, snapshot: snapshot)
        if plan.disposition == .admittedAfterEviction {
            for action in plan.actions { try await controlPlane.apply(action) }
        }
        return plan
    }

    public func handlePressure(
        queuedWork: [RuntimeQueuedResidencyWork]
    ) async throws -> RuntimePressurePlan {
        let snapshot = try await controlPlane.residencySnapshot()
        let plan = try policy.pressurePlan(snapshot: snapshot, queuedWork: queuedWork)
        for action in plan.actions { try await controlPlane.apply(action) }
        return plan
    }

    public func reset(_ request: RuntimeResetRequest) async throws -> RuntimeResetReceipt {
        let receipt = try await controlPlane.resetRuntime(request)
        guard receipt.requestID == request.requestID,
              receipt.previousEpoch == request.expectedEpoch,
              receipt.newEpoch == request.expectedEpoch.addingReportingOverflow(1).partialValue,
              receipt.newEpoch > receipt.previousEpoch,
              receipt.purgedDerivedCacheBytes >= 0,
              receipt.clearedReplayGenerationCount >= 0,
              receipt.clearedBufferedEventCount >= 0 else {
            throw RuntimeResidencyError.invalidResetReceipt
        }
        return receipt
    }
}
