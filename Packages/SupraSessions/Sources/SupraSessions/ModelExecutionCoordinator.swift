import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// Feature-facing runtime surface. Shipping composition provides the one shared
/// coordinator; the alias preserves lightweight transport doubles in package
/// tests without granting raw transport ownership to production features.
public typealias ModelExecutionGateway = RuntimeClientProtocol

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
    private var loadedChatBindings: [ModelID: ModelExecutionModelBinding] = [:]
    private var loadedEmbeddingBindings: [DocumentEmbeddingModelID: ModelExecutionModelBinding] = [:]
    private var generationTasks: [GenerationID: ModelExecutionTaskID] = [:]
    private var runtimeMemoryPressure: RuntimeMemoryPressureLevel = .normal

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

    public var runtimeResidencyActiveTaskCount: Int {
        activeTaskID == nil ? 0 : 1
    }

    public func runtimeResidencyQueuedWork() -> [RuntimeQueuedResidencyWork] {
        var work = waiting.map { entry in
            let workClass: RuntimeResidencyWorkClass
            switch entry.request.priority {
            case .foregroundInteractive: workClass = .foreground
            case .userInitiatedBatch: workClass = .userInitiated
            case .backgroundMaintenance: workClass = .background
            case .speculative: workClass = .speculative
            }
            return RuntimeQueuedResidencyWork(
                id: entry.request.taskID.rawValue,
                workClass: workClass
            )
        }
        if let activeTaskID,
           let active = requests[activeTaskID],
           (active.priority == .backgroundMaintenance || active.priority == .speculative) {
            let workClass: RuntimeResidencyWorkClass = active.priority == .speculative
                ? .speculative
                : .background
            work.append(RuntimeQueuedResidencyWork(
                id: activeTaskID.rawValue,
                workClass: workClass
            ))
        }
        return work
    }

    public func setRuntimeMemoryPressure(_ level: RuntimeMemoryPressureLevel) {
        runtimeMemoryPressure = level
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
        if runtimeMemoryPressure != .normal,
           (request.priority == .backgroundMaintenance || request.priority == .speculative) {
            throw ModelExecutionError.memoryPressure(level: runtimeMemoryPressure)
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

extension ModelExecutionCoordinator: RuntimeClientProtocol {
    public func connect() async throws {
        try await runtimeClient.connect()
    }

    public func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        let binding = request.contentBinding.map {
            ModelExecutionModelBinding(
                modelID: request.modelID,
                repositoryID: $0.repositoryID,
                revision: $0.revision,
                artifactFingerprintSHA256: $0.fingerprintSHA256
            )
        }
        let response = try await execute(
            gatewayRequest(operation: .modelLoad, priority: .userInitiatedBatch, binding: binding)
        ) { permit in
            await permit.markRunning()
            return try await permit.loadModel(request)
        }
        if response.status == .loaded {
            if let binding {
                loadedChatBindings[request.modelID] = binding
            } else {
                loadedChatBindings[request.modelID] = nil
            }
        }
        return response
    }

    public nonisolated func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let taskID = ModelExecutionTaskID(rawValue: UUID().uuidString.lowercased())
        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    try await self.executeGeneration(
                        request,
                        taskID: taskID,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                Task { await self.cancel(taskID: taskID) }
            }
        }
    }

    public func countTokens(
        _ request: CountTokensRequest
    ) async throws -> CountTokensResponse {
        try await execute(
            gatewayRequest(
                operation: .generation,
                priority: .foregroundInteractive,
                binding: loadedChatBindings[request.modelID]
            )
        ) { permit in
            await permit.markRunning()
            return try await permit.countTokens(request)
        }
    }

    public func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        if let taskID = generationTasks[generationID] {
            cancel(taskID: taskID)
        }
        return try await runtimeClient.cancelGeneration(generationID)
    }

    public func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        try await runtimeClient.recentEvents(
            for: generationID,
            after: sequenceNumber
        )
    }

    public func unloadModel() async throws -> UnloadModelResponse {
        let response = try await execute(
            gatewayRequest(operation: .modelLoad, priority: .userInitiatedBatch, binding: nil)
        ) { permit in
            await permit.markRunning()
            return try await permit.unloadModel()
        }
        if response.status == .unloaded {
            loadedChatBindings.removeAll()
        }
        return response
    }

    public func reloadCurrentModel() async throws -> LoadModelResponse {
        try await execute(
            gatewayRequest(operation: .modelLoad, priority: .userInitiatedBatch, binding: nil)
        ) { permit in
            await permit.markRunning()
            return try await permit.reloadCurrentModel()
        }
    }

    public func runtimeStatus() async throws -> RuntimeStatus {
        try await runtimeClient.runtimeStatus()
    }

    public func restartRuntimeService() async throws {
        try await runtimeClient.restartRuntimeService()
    }

    public func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        let modelID = ModelID(request.embeddingModelID.rawValue)
        let binding = request.contentBinding.map {
            ModelExecutionModelBinding(
                modelID: modelID,
                repositoryID: $0.repositoryID,
                revision: $0.revision,
                artifactFingerprintSHA256: $0.fingerprintSHA256
            )
        }
        let response = try await execute(
            gatewayRequest(operation: .modelLoad, priority: .userInitiatedBatch, binding: binding)
        ) { permit in
            await permit.markRunning()
            return try await permit.loadEmbeddingModel(request)
        }
        if response.state == .loaded {
            if let binding {
                loadedEmbeddingBindings[request.embeddingModelID] = binding
            } else {
                loadedEmbeddingBindings[request.embeddingModelID] = nil
            }
        }
        return response
    }

    public func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        try await execute(
            gatewayRequest(
                operation: .embeddingBatch,
                priority: .userInitiatedBatch,
                binding: loadedEmbeddingBindings[request.embeddingModelID]
            )
        ) { permit in
            await permit.markRunning()
            return try await permit.embedTexts(request)
        }
    }

    public func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await runtimeClient.embeddingStatus()
    }

    private func executeGeneration(
        _ request: GenerateRequest,
        taskID: ModelExecutionTaskID,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        generationTasks[request.generationID] = taskID
        defer { generationTasks[request.generationID] = nil }
        let executionRequest = ModelExecutionRequest(
            taskID: taskID,
            operation: .generation,
            priority: .foregroundInteractive,
            modelBinding: loadedChatBindings[request.modelID],
            duplicateKey: "generation-\(request.generationID.rawValue.uuidString.lowercased())"
        )
        try await execute(executionRequest) { permit in
            await permit.markRunning()
            for try await event in try permit.generate(request) {
                continuation.yield(event)
            }
        }
    }

    private func gatewayRequest(
        operation: ModelExecutionOperation,
        priority: ModelExecutionPriority,
        binding: ModelExecutionModelBinding?
    ) -> ModelExecutionRequest {
        ModelExecutionRequest(
            taskID: ModelExecutionTaskID(rawValue: UUID().uuidString.lowercased()),
            operation: operation,
            priority: priority,
            modelBinding: binding,
            duplicateKey: nil
        )
    }
}
