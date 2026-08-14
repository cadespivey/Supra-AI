import Foundation
import SupraRuntimeClient

public enum ModelExecutionPriority: Int, CaseIterable, Equatable, Sendable {
    case speculative = 0
    case backgroundMaintenance = 1
    case userInitiatedBatch = 2
    case foregroundInteractive = 3
}

public enum ModelExecutionOperation: Equatable, Sendable {
    case generation
    case embeddingBatch
    case rerank
    case modelLoad
    case prewarm(supersessionKey: String)
}

public struct ModelExecutionConfiguration: Equatable, Sendable {
    public let maximumQueuedTasks: Int
    public let agingIntervalTicks: UInt64

    public init(maximumQueuedTasks: Int, agingIntervalTicks: UInt64) {
        precondition(maximumQueuedTasks > 0, "the model execution queue must be finite and positive")
        precondition(agingIntervalTicks > 0, "the scheduler aging interval must be positive")
        self.maximumQueuedTasks = maximumQueuedTasks
        self.agingIntervalTicks = agingIntervalTicks
    }
}

/// Process-wide admission owner for GPU-backed local-model operations.
///
/// This actor is deliberately narrower than a workflow coordinator: it owns a
/// finite priority queue, one physical execution lane, lifecycle projection,
/// model binding, and cancellation admission. Prompts, legal workflow state,
/// persistence, provenance, publication, and navigation remain feature-owned.
public actor ModelExecutionCoordinator {
    private struct WaitingAdmission {
        let request: ModelExecutionRequest
        let enqueuedAt: UInt64
        let sequence: UInt64
        let resumesRunningTask: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let runtimeClient: RuntimeSafetyClient
    private let configuration: ModelExecutionConfiguration
    private let monotonicNow: @Sendable () -> UInt64

    private var activeTaskID: ModelExecutionTaskID?
    private var waiting: [WaitingAdmission] = []
    private var nextSequence: UInt64 = 0
    private var requests: [ModelExecutionTaskID: ModelExecutionRequest] = [:]
    private var snapshots: [ModelExecutionTaskID: ModelExecutionSnapshot] = [:]
    private var duplicateOwners: [String: ModelExecutionTaskID] = [:]
    private var cancellationRequested: Set<ModelExecutionTaskID> = []
    private var activeCancellation: [ModelExecutionTaskID: @Sendable () -> Void] = [:]

    public init(
        runtimeClient: RuntimeSafetyClient,
        configuration: ModelExecutionConfiguration,
        monotonicNow: @escaping @Sendable () -> UInt64
    ) {
        self.runtimeClient = runtimeClient
        self.configuration = configuration
        self.monotonicNow = monotonicNow
    }

    public var queuedTaskCount: Int {
        waiting.count
    }

    public func snapshot(taskID: ModelExecutionTaskID) -> ModelExecutionSnapshot? {
        snapshots[taskID]
    }

    public func execute<ResultValue: Sendable>(
        _ request: ModelExecutionRequest,
        operation: @escaping @Sendable (ModelExecutionPermit) async throws -> ResultValue
    ) async throws -> ResultValue {
        try register(request)

        do {
            try await acquireInitialAdmission(for: request)
        } catch {
            removeNonterminalOwnership(for: request)
            throw error
        }

        let permit = ModelExecutionPermit(
            taskID: request.taskID,
            modelBinding: request.modelBinding,
            runtimeClient: runtimeClient,
            coordinator: self
        )
        let operationTask = Task<ResultValue, any Error> {
            try await operation(permit)
        }
        activeCancellation[request.taskID] = { operationTask.cancel() }
        if cancellationRequested.contains(request.taskID) {
            operationTask.cancel()
        }

        do {
            let value = try await operationTask.value
            if cancellationRequested.contains(request.taskID) {
                throw await finishCancellation(for: request, permit: permit)
            }
            finish(request, lifecycle: .completed)
            return value
        } catch {
            if cancellationRequested.contains(request.taskID) {
                throw await finishCancellation(for: request, permit: permit)
            }
            let mappedError = finishFailure(request, error: error)
            throw mappedError
        }
    }

    public func cancel(taskID: ModelExecutionTaskID) {
        if let index = waiting.firstIndex(where: { $0.request.taskID == taskID }) {
            let entry = waiting.remove(at: index)
            if entry.resumesRunningTask {
                cancellationRequested.insert(taskID)
                snapshots[taskID] = snapshot(for: entry.request, lifecycle: .cancelling)
                activeCancellation[taskID]?()
            } else {
                snapshots[taskID] = snapshot(for: entry.request, lifecycle: .failed)
                removeNonterminalOwnership(for: entry.request)
            }
            entry.continuation.resume(
                throwing: ModelExecutionError.cancelled(taskID: taskID)
            )
            if activeTaskID == nil {
                admitNextIfPossible()
            }
            return
        }

        guard activeTaskID == taskID,
              let request = requests[taskID] else { return }
        cancellationRequested.insert(taskID)
        snapshots[taskID] = snapshot(for: request, lifecycle: .cancelling)
        activeCancellation[taskID]?()
    }

    func markRunning(taskID: ModelExecutionTaskID) {
        guard activeTaskID == taskID,
              !cancellationRequested.contains(taskID),
              let request = requests[taskID] else { return }
        snapshots[taskID] = snapshot(for: request, lifecycle: .running)
    }

    func yieldAtSafeBoundary(taskID: ModelExecutionTaskID) async throws {
        guard activeTaskID == taskID,
              let request = requests[taskID] else {
            if cancellationRequested.contains(taskID) {
                throw ModelExecutionError.cancelled(taskID: taskID)
            }
            throw ModelExecutionError.recoveryRequired
        }
        guard !cancellationRequested.contains(taskID) else {
            throw ModelExecutionError.cancelled(taskID: taskID)
        }
        guard runtimeIsAvailable else {
            snapshots[taskID] = snapshot(for: request, lifecycle: .recoveryRequired)
            throw ModelExecutionError.recoveryRequired
        }
        guard shouldYield(request) else { return }

        activeTaskID = nil
        snapshots[taskID] = snapshot(for: request, lifecycle: .queued)
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(WaitingAdmission(
                request: request,
                enqueuedAt: monotonicNow(),
                sequence: takeSequence(),
                resumesRunningTask: true,
                continuation: continuation
            ))
            admitNextIfPossible()
        }
    }

    private var runtimeIsAvailable: Bool {
        runtimeClient.currentRecoverySnapshot().phase == .available
    }

    private func register(_ request: ModelExecutionRequest) throws {
        guard runtimeIsAvailable else {
            snapshots[request.taskID] = snapshot(for: request, lifecycle: .recoveryRequired)
            throw ModelExecutionError.recoveryRequired
        }

        if let existing = requests[request.taskID] {
            throw ModelExecutionError.duplicateInvocation(existingTaskID: existing.taskID)
        }
        if let duplicateKey = request.duplicateKey,
           let existingTaskID = duplicateOwners[duplicateKey] {
            throw ModelExecutionError.duplicateInvocation(existingTaskID: existingTaskID)
        }

        requests[request.taskID] = request
        if let duplicateKey = request.duplicateKey {
            duplicateOwners[duplicateKey] = request.taskID
        }
    }

    private func acquireInitialAdmission(for request: ModelExecutionRequest) async throws {
        if activeTaskID == nil, waiting.isEmpty {
            activeTaskID = request.taskID
            snapshots[request.taskID] = snapshot(for: request, lifecycle: .preparing)
            return
        }

        supersedeObsoletePrewarm(with: request)
        guard waiting.count < configuration.maximumQueuedTasks else {
            snapshots[request.taskID] = snapshot(for: request, lifecycle: .failed)
            throw ModelExecutionError.queueFull(capacity: configuration.maximumQueuedTasks)
        }

        snapshots[request.taskID] = snapshot(for: request, lifecycle: .queued)
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(WaitingAdmission(
                request: request,
                enqueuedAt: monotonicNow(),
                sequence: takeSequence(),
                resumesRunningTask: false,
                continuation: continuation
            ))
            if activeTaskID == nil {
                admitNextIfPossible()
            }
        }
    }

    private func supersedeObsoletePrewarm(with request: ModelExecutionRequest) {
        guard case let .prewarm(supersessionKey) = request.operation else { return }
        let obsolete = waiting.indices.filter { index in
            guard case let .prewarm(existingKey) = waiting[index].request.operation else {
                return false
            }
            return existingKey == supersessionKey
        }

        for index in obsolete.reversed() {
            let entry = waiting.remove(at: index)
            snapshots[entry.request.taskID] = snapshot(
                for: entry.request,
                lifecycle: .failed
            )
            removeNonterminalOwnership(for: entry.request)
            entry.continuation.resume(throwing: ModelExecutionError.superseded(
                taskID: entry.request.taskID,
                by: request.taskID
            ))
        }
    }

    private func shouldYield(_ activeRequest: ModelExecutionRequest) -> Bool {
        let activeRank = activeRequest.priority.rawValue
        return waiting.contains { effectivePriority(of: $0) > activeRank }
    }

    private func effectivePriority(of entry: WaitingAdmission) -> Int {
        let elapsed = monotonicNow() >= entry.enqueuedAt
            ? monotonicNow() - entry.enqueuedAt
            : 0
        let promotions = Int(elapsed / configuration.agingIntervalTicks)
        return min(ModelExecutionPriority.foregroundInteractive.rawValue,
                   entry.request.priority.rawValue + promotions)
    }

    private func admitNextIfPossible() {
        guard activeTaskID == nil else { return }
        guard runtimeIsAvailable else {
            failQueuedForRecovery()
            return
        }
        guard !waiting.isEmpty else { return }

        let index = waiting.indices.min { lhs, rhs in
            let lhsEntry = waiting[lhs]
            let rhsEntry = waiting[rhs]
            let lhsPriority = effectivePriority(of: lhsEntry)
            let rhsPriority = effectivePriority(of: rhsEntry)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhsEntry.sequence < rhsEntry.sequence
        }!
        let entry = waiting.remove(at: index)
        activeTaskID = entry.request.taskID
        snapshots[entry.request.taskID] = snapshot(
            for: entry.request,
            lifecycle: entry.resumesRunningTask ? .running : .preparing
        )
        entry.continuation.resume()
    }

    private func finish(
        _ request: ModelExecutionRequest,
        lifecycle: ModelExecutionLifecycle
    ) {
        activeCancellation[request.taskID] = nil
        cancellationRequested.remove(request.taskID)
        snapshots[request.taskID] = snapshot(for: request, lifecycle: lifecycle)
        removeNonterminalOwnership(for: request)
        releaseLaneIfOwned(by: request.taskID)
    }

    private func finishFailure(
        _ request: ModelExecutionRequest,
        error: any Error
    ) -> any Error {
        activeCancellation[request.taskID] = nil
        cancellationRequested.remove(request.taskID)

        let recoveryRequired = !runtimeIsAvailable || error is RuntimeSafetyError
        snapshots[request.taskID] = snapshot(
            for: request,
            lifecycle: recoveryRequired ? .recoveryRequired : .failed
        )
        removeNonterminalOwnership(for: request)
        releaseLaneIfOwned(by: request.taskID, admitSuccessor: !recoveryRequired)
        if recoveryRequired {
            failQueuedForRecovery()
            return ModelExecutionError.recoveryRequired
        }
        return error
    }

    private func finishCancellation(
        for request: ModelExecutionRequest,
        permit: ModelExecutionPermit
    ) async -> ModelExecutionError {
        let quiescenceResolution = await permit.awaitGenerationQuiescenceIfNeeded()

        activeCancellation[request.taskID] = nil
        cancellationRequested.remove(request.taskID)
        let recoveryRequired: Bool
        switch quiescenceResolution {
        case .completedNormally, .cancellationConfirmed, nil:
            recoveryRequired = !runtimeIsAvailable
        case .recoveryRequired:
            recoveryRequired = true
        }
        snapshots[request.taskID] = snapshot(
            for: request,
            lifecycle: recoveryRequired ? .recoveryRequired : .failed
        )
        removeNonterminalOwnership(for: request)
        releaseLaneIfOwned(by: request.taskID, admitSuccessor: !recoveryRequired)

        if recoveryRequired {
            failQueuedForRecovery()
            return .recoveryRequired
        }
        return .cancelled(taskID: request.taskID)
    }

    private func releaseLaneIfOwned(
        by taskID: ModelExecutionTaskID,
        admitSuccessor: Bool = true
    ) {
        guard activeTaskID == taskID else { return }
        activeTaskID = nil
        if admitSuccessor {
            admitNextIfPossible()
        }
    }

    private func failQueuedForRecovery() {
        let entries = waiting
        waiting.removeAll()
        for entry in entries {
            snapshots[entry.request.taskID] = snapshot(
                for: entry.request,
                lifecycle: .recoveryRequired
            )
            activeCancellation[entry.request.taskID]?()
            removeNonterminalOwnership(for: entry.request)
            entry.continuation.resume(throwing: ModelExecutionError.recoveryRequired)
        }
    }

    private func removeNonterminalOwnership(for request: ModelExecutionRequest) {
        requests[request.taskID] = nil
        if let duplicateKey = request.duplicateKey,
           duplicateOwners[duplicateKey] == request.taskID {
            duplicateOwners[duplicateKey] = nil
        }
    }

    private func snapshot(
        for request: ModelExecutionRequest,
        lifecycle: ModelExecutionLifecycle
    ) -> ModelExecutionSnapshot {
        ModelExecutionSnapshot(
            taskID: request.taskID,
            operation: request.operation,
            priority: request.priority,
            modelBinding: request.modelBinding,
            lifecycle: lifecycle
        )
    }

    private func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }
}
