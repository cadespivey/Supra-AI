import Foundation
import SupraCore
import SupraRuntimeInterface

public enum RuntimeSafetyError: Error, LocalizedError, Equatable, Sendable {
    case recoveryRequired(message: String)
    case recoveryFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .recoveryRequired(message):
            "The local runtime requires recovery: \(message)"
        case let .recoveryFailed(message):
            "The local runtime could not be recovered: \(message)"
        }
    }
}

/// Process-local safety state for ordinary runtime work. This is deliberately
/// not a feature reservation or scheduler: it only prevents a new data-plane
/// call from entering an XPC connection after cancellation failed to establish
/// that an earlier generation stopped.
public struct RuntimeRecoverySnapshot: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case available
        case recoveryRequired
        case recovering
    }

    public let phase: Phase
    public let message: String?

    public init(phase: Phase, message: String? = nil) {
        self.phase = phase
        self.message = message
    }

    public static let available = RuntimeRecoverySnapshot(phase: .available)
}

/// Exact terminal result of generation quiescence owned by
/// `RuntimeSafetyClient`. A scheduler must not admit successor data-plane work
/// until this result is available for the generation it interrupted.
public enum RuntimeGenerationQuiescenceResolution: Equatable, Sendable {
    case completedNormally(generationID: GenerationID)
    case cancellationConfirmed(generationID: GenerationID)
    case recoveryRequired(generationID: GenerationID, message: String)
}

struct RuntimeCancellationConfirmationPolicy: Sendable {
    let maxStatusPollAttempts: Int
    let statusPollInterval: Duration

    init(maxStatusPollAttempts: Int, statusPollInterval: Duration) {
        precondition(maxStatusPollAttempts > 0)
        self.maxStatusPollAttempts = maxStatusPollAttempts
        self.statusPollInterval = statusPollInterval
    }

    static let live = RuntimeCancellationConfirmationPolicy(
        maxStatusPollAttempts: 3_000,
        statusPollInterval: .milliseconds(10)
    )
}

/// Normal-process runtime facade that preserves cancellation confirmation and
/// idle recovery without retaining the retired exclusive Review admission path.
/// Observation and cancellation calls remain available during quarantine; every
/// model/data-plane call fails closed until recovery restarts the service and
/// observes an idle status.
public final class RuntimeSafetyClient: RuntimeClientProtocol, RuntimeRecoveryClientProtocol,
    @unchecked Sendable {
    private let base: any RuntimeClientProtocol
    private let residencyBase: (any RuntimeResidencyClientProtocol)?
    private let cancellationConfirmationPolicy: RuntimeCancellationConfirmationPolicy
    private let coordinator = RuntimeSafetyCoordinator()
    private let cancellationResolutions = RuntimeCancellationResolutionCoordinator()

    public init(base: any RuntimeClientProtocol) {
        self.base = base
        residencyBase = base as? any RuntimeResidencyClientProtocol
        cancellationConfirmationPolicy = .live
    }

    init(
        base: any RuntimeClientProtocol,
        cancellationConfirmationPolicy: RuntimeCancellationConfirmationPolicy
    ) {
        self.base = base
        residencyBase = base as? any RuntimeResidencyClientProtocol
        self.cancellationConfirmationPolicy = cancellationConfirmationPolicy
    }

    public func currentRecoverySnapshot() -> RuntimeRecoverySnapshot {
        coordinator.snapshot()
    }

    /// Suspends until stream termination has completed normally, confirmed
    /// exact cancellation, or established the fail-closed recovery quarantine.
    /// Already-resolved generations return immediately.
    public func awaitQuiescenceResolution(
        for generationID: GenerationID
    ) async -> RuntimeGenerationQuiescenceResolution {
        await cancellationResolutions.resolution(for: generationID)
    }

    public func recoverRuntime() async throws {
        try coordinator.beginRecovery()
        do {
            try await base.restartRuntimeService()
            let status = try await base.runtimeStatus()
            let idleStates: Set<RuntimeServiceState> = [.connected, .modelUnloaded, .modelLoaded]
            guard status.activeGenerationID == nil, idleStates.contains(status.state) else {
                throw RuntimeSafetyError.recoveryFailed(
                    message: "the restarted service did not report an idle state"
                )
            }
            guard let residencyBase else {
                throw RuntimeSafetyError.recoveryFailed(
                    message: "the restarted service does not expose deterministic reset controls"
                )
            }
            let snapshot = try await residencyBase.runtimeResidencySnapshot()
            let (expectedNewEpoch, overflow) = snapshot.epoch.addingReportingOverflow(1)
            guard !overflow else {
                throw RuntimeSafetyError.recoveryFailed(
                    message: "the runtime residency epoch cannot advance safely"
                )
            }
            let resetRequest = RuntimeServiceResetRequest(
                requestID: "runtime-recovery-\(UUID().uuidString.lowercased())",
                expectedEpoch: snapshot.epoch
            )
            let receipt = try await residencyBase.resetRuntime(resetRequest)
            guard receipt.requestID == resetRequest.requestID,
                  receipt.previousEpoch == snapshot.epoch,
                  receipt.newEpoch == expectedNewEpoch else {
                throw RuntimeSafetyError.recoveryFailed(
                    message: "the runtime returned an invalid deterministic reset receipt"
                )
            }
            coordinator.finishRecovery(succeeded: true)
        } catch {
            coordinator.finishRecovery(succeeded: false)
            if let typed = error as? RuntimeSafetyError { throw typed }
            throw RuntimeSafetyError.recoveryFailed(message: error.localizedDescription)
        }
    }

    // MARK: Control plane

    public func connect() async throws {
        try await base.connect()
    }

    public func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        try await base.cancelGeneration(generationID)
    }

    public func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        try await base.recentEvents(for: generationID, after: sequenceNumber)
    }

    public func runtimeStatus() async throws -> RuntimeStatus {
        try await base.runtimeStatus()
    }

    public func runtimeResidencySnapshot() async throws -> RuntimeServiceResidencySnapshot {
        guard let residencyBase else {
            throw RuntimeClientError.remoteInvocationFailed(
                "Runtime residency snapshots are unavailable on this control plane."
            )
        }
        return try await residencyBase.runtimeResidencySnapshot()
    }

    public func evictRuntimeArtifact(
        _ request: RuntimeServiceArtifactEvictionRequest
    ) async throws -> RuntimeServiceArtifactEvictionResponse {
        guard let residencyBase else {
            throw RuntimeClientError.remoteInvocationFailed(
                "Runtime artifact eviction is unavailable on this control plane."
            )
        }
        return try await residencyBase.evictRuntimeArtifact(request)
    }

    public func resetRuntime(
        _ request: RuntimeServiceResetRequest
    ) async throws -> RuntimeServiceResetReceipt {
        guard let residencyBase else {
            throw RuntimeClientError.remoteInvocationFailed(
                "Deterministic runtime reset is unavailable on this control plane."
            )
        }
        return try await residencyBase.resetRuntime(request)
    }

    public func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await base.embeddingStatus()
    }

    // MARK: Data plane

    public func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.loadModel(request)
    }

    public func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let permit = try coordinator.acquirePermit()
        cancellationResolutions.begin(generationID: request.generationID)
        let baseStream: AsyncThrowingStream<GenerationEvent, Error>
        do {
            baseStream = try base.generate(request)
        } catch {
            cancellationResolutions.discardPending(generationID: request.generationID)
            permit.release()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                do {
                    for try await event in baseStream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if Task.isCancelled {
                    if await generationCancellationWasConfirmed(request.generationID) {
                        permit.release()
                        cancellationResolutions.resolve(.cancellationConfirmed(
                            generationID: request.generationID
                        ))
                    } else {
                        let message = "Generation cancellation did not confirm runtime quiescence."
                        permit.failClosed(message: message)
                        cancellationResolutions.resolve(.recoveryRequired(
                            generationID: request.generationID,
                            message: message
                        ))
                    }
                } else {
                    permit.release()
                    cancellationResolutions.resolve(.completedNormally(
                        generationID: request.generationID
                    ))
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    forwardingTask.cancel()
                }
            }
        }
    }

    public func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.countTokens(request)
    }

    public func unloadModel() async throws -> UnloadModelResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.unloadModel()
    }

    public func reloadCurrentModel() async throws -> LoadModelResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.reloadCurrentModel()
    }

    public func restartRuntimeService() async throws {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        try await base.restartRuntimeService()
    }

    public func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.loadEmbeddingModel(request)
    }

    public func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        let permit = try coordinator.acquirePermit()
        defer { permit.release() }
        return try await base.embedTexts(request)
    }

    private func generationCancellationWasConfirmed(_ generationID: GenerationID) async -> Bool {
        let base = base
        let policy = cancellationConfirmationPolicy
        let confirmation = Task.detached { () -> Bool in
            do {
                let response = try await base.cancelGeneration(generationID)
                guard response.generationID == generationID,
                      response.error == nil,
                      response.status == .cancelled || response.status == .notFound else {
                    return false
                }
                guard response.status == .notFound else { return true }
                for attempt in 0..<policy.maxStatusPollAttempts {
                    let status = try await base.runtimeStatus()
                    guard let activeGenerationID = status.activeGenerationID else { return true }
                    guard activeGenerationID == generationID else { return false }
                    if attempt < policy.maxStatusPollAttempts - 1 {
                        try await Task<Never, Never>.sleep(for: policy.statusPollInterval)
                    }
                }
                return false
            } catch {
                return false
            }
        }
        return await confirmation.value
    }
}

private final class RuntimeCancellationResolutionCoordinator: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<RuntimeGenerationQuiescenceResolution, Never>])
        case resolved(RuntimeGenerationQuiescenceResolution)
    }

    private let lock = NSLock()
    private let maximumRetainedResolutions = 256
    private var states: [GenerationID: State] = [:]
    private var resolutionOrder: [GenerationID] = []

    func begin(generationID: GenerationID) {
        lock.withLock {
            switch states[generationID] {
            case let .pending(waiters):
                states[generationID] = .pending(waiters)
            case .resolved, nil:
                states[generationID] = .pending([])
                resolutionOrder.removeAll { $0 == generationID }
            }
        }
    }

    func resolution(
        for generationID: GenerationID
    ) async -> RuntimeGenerationQuiescenceResolution {
        await withCheckedContinuation { continuation in
            let immediate: RuntimeGenerationQuiescenceResolution? = lock.withLock {
                switch states[generationID] {
                case let .resolved(resolution):
                    return resolution
                case let .pending(waiters):
                    states[generationID] = .pending(waiters + [continuation])
                    return nil
                case nil:
                    states[generationID] = .pending([continuation])
                    return nil
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func resolve(_ resolution: RuntimeGenerationQuiescenceResolution) {
        let generationID: GenerationID
        switch resolution {
        case let .completedNormally(resolvedGenerationID),
             let .cancellationConfirmed(resolvedGenerationID),
             let .recoveryRequired(resolvedGenerationID, _):
            generationID = resolvedGenerationID
        }

        let waiters = lock.withLock {
            let waiters: [CheckedContinuation<RuntimeGenerationQuiescenceResolution, Never>]
            if case let .pending(pendingWaiters) = states[generationID] {
                waiters = pendingWaiters
            } else {
                waiters = []
            }
            states[generationID] = .resolved(resolution)
            resolutionOrder.removeAll { $0 == generationID }
            resolutionOrder.append(generationID)
            trimResolvedStatesIfNeeded()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
    }

    func discardPending(generationID: GenerationID) {
        lock.withLock {
            guard case let .pending(waiters) = states[generationID],
                  waiters.isEmpty else { return }
            states[generationID] = nil
        }
    }

    private func trimResolvedStatesIfNeeded() {
        while resolutionOrder.count > maximumRetainedResolutions {
            let generationID = resolutionOrder.removeFirst()
            if case .resolved = states[generationID] {
                states[generationID] = nil
            }
        }
    }
}

private final class RuntimeSafetyPermit: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: RuntimeSafetyCoordinator
    private var didFinish = false

    init(coordinator: RuntimeSafetyCoordinator) {
        self.coordinator = coordinator
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldRelease { coordinator.releasePermit() }
    }

    func failClosed(message: String) {
        let shouldFail = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldFail { coordinator.failPermit(message: message) }
    }

    deinit {
        release()
    }
}

private final class RuntimeSafetyCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOperationCount = 0
    private var recoveryMessage: String?
    private var recoveryInProgress = false

    func snapshot() -> RuntimeRecoverySnapshot {
        lock.withLock {
            if recoveryInProgress {
                return RuntimeRecoverySnapshot(
                    phase: .recovering,
                    message: recoveryMessage
                )
            }
            if let recoveryMessage {
                return RuntimeRecoverySnapshot(
                    phase: .recoveryRequired,
                    message: recoveryMessage
                )
            }
            return .available
        }
    }

    func acquirePermit() throws -> RuntimeSafetyPermit {
        try lock.withLock {
            if let recoveryMessage {
                throw RuntimeSafetyError.recoveryRequired(message: recoveryMessage)
            }
            activeOperationCount += 1
            return RuntimeSafetyPermit(coordinator: self)
        }
    }

    func releasePermit() {
        lock.withLock {
            activeOperationCount = max(activeOperationCount - 1, 0)
        }
    }

    func failPermit(message: String) {
        lock.withLock {
            activeOperationCount = max(activeOperationCount - 1, 0)
            recoveryMessage = message
            recoveryInProgress = false
        }
    }

    func beginRecovery() throws {
        try lock.withLock {
            guard recoveryMessage != nil else {
                throw RuntimeSafetyError.recoveryFailed(message: "recovery is not required")
            }
            guard activeOperationCount == 0 else {
                let suffix = activeOperationCount == 1 ? "operation" : "operations"
                throw RuntimeSafetyError.recoveryFailed(
                    message: "recovery is waiting for \(activeOperationCount) admitted runtime \(suffix) to finish"
                )
            }
            guard !recoveryInProgress else {
                throw RuntimeSafetyError.recoveryFailed(message: "recovery is already in progress")
            }
            recoveryInProgress = true
        }
    }

    func finishRecovery(succeeded: Bool) {
        lock.withLock {
            recoveryInProgress = false
            if succeeded { recoveryMessage = nil }
        }
    }
}
