import Foundation
import SupraCore
import SupraRuntimeInterface

/// Identifies the app-level operation that temporarily owns every mutating or
/// model-backed runtime call in this process.
public enum RuntimeLeasePurpose: Equatable, Sendable {
    case caseFileReview(runID: String)

    public var runID: String {
        switch self {
        case let .caseFileReview(runID): runID
        }
    }
}

public enum RuntimeLeaseError: Error, LocalizedError, Equatable, Sendable {
    case reserved(purpose: RuntimeLeasePurpose)
    case recoveryRequired(purpose: RuntimeLeasePurpose)
    case runtimeRecoveryRequired(message: String)
    case recoveryFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .reserved(purpose):
            "The local runtime is reserved for \(purpose.description)."
        case let .recoveryRequired(purpose):
            "The local runtime requires recovery after \(purpose.description)."
        case let .runtimeRecoveryRequired(message):
            "The local runtime requires recovery: \(message)"
        case let .recoveryFailed(message):
            "The local runtime could not be recovered: \(message)"
        }
    }
}

public extension RuntimeLeasePurpose {
    var description: String {
        switch self {
        case let .caseFileReview(runID):
            "Case File Review \(runID)"
        }
    }
}

/// App-admission state is deliberately separate from XPC runtime status. The
/// service can be idle between Review partitions while this process still owns
/// the right to issue the next model request.
public struct RuntimeAdmissionSnapshot: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case available
        case waiting
        case exclusive
        case recoveryRequired
    }

    public let phase: Phase
    public let purpose: RuntimeLeasePurpose?
    public let message: String?

    public init(
        phase: Phase,
        purpose: RuntimeLeasePurpose? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.purpose = purpose
        self.message = message
    }

    public var blocksOrdinaryWork: Bool { phase != .available }

    public static let available = RuntimeAdmissionSnapshot(phase: .available)
}

/// Handle scoped to one admitted owner. Release is idempotent and waits for any
/// owner data-plane call already in flight before making the runtime available.
public final class ExclusiveRuntimeLease: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: RuntimeAdmissionCoordinator
    private let token: UUID
    public let purpose: RuntimeLeasePurpose
    private var didRelease = false

    fileprivate init(
        coordinator: RuntimeAdmissionCoordinator,
        token: UUID,
        purpose: RuntimeLeasePurpose
    ) {
        self.coordinator = coordinator
        self.token = token
        self.purpose = purpose
    }

    public func release() async {
        let shouldRelease = lock.withLock {
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        guard shouldRelease else { return }
        await coordinator.releaseLease(token: token)
    }

    /// Quarantines the admission boundary when Review cancellation could not
    /// prove that the runtime stopped. The normal scope cleanup cannot clear it.
    public func markRecoveryRequired(message: String) async {
        coordinator.markRecoveryRequired(
            token: token,
            purpose: purpose,
            message: message
        )
    }
}

private enum RuntimeLeaseTaskContext {
    @TaskLocal static var ownerToken: UUID?
}

/// The sole normal-process facade around `RuntimeClientProtocol`. Control-plane
/// calls remain available for observation and cancellation; all model/data-plane
/// calls pass through one writer-preferring admission coordinator.
public final class ExclusiveRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let base: any RuntimeClientProtocol
    private let coordinator = RuntimeAdmissionCoordinator()

    public init(base: any RuntimeClientProtocol) {
        self.base = base
    }

    public var ordinaryWorkIsBlocked: Bool {
        coordinator.snapshot().blocksOrdinaryWork
    }

    public func currentAdmissionSnapshot() async -> RuntimeAdmissionSnapshot {
        coordinator.snapshot()
    }

    public func admissionSnapshots() -> AsyncStream<RuntimeAdmissionSnapshot> {
        let observerID = UUID()
        return AsyncStream { [coordinator] continuation in
            continuation.onTermination = { @Sendable _ in
                coordinator.removeObserver(observerID)
            }
            coordinator.addObserver(observerID, continuation: continuation)
        }
    }

    public func withExclusiveLease<Result>(
        purpose: RuntimeLeasePurpose,
        operation: (ExclusiveRuntimeLease) async throws -> Result
    ) async throws -> Result {
        let token = try await coordinator.acquireExclusive(purpose: purpose)
        let lease = ExclusiveRuntimeLease(
            coordinator: coordinator,
            token: token,
            purpose: purpose
        )
        do {
            let result = try await RuntimeLeaseTaskContext.$ownerToken.withValue(token) {
                try await operation(lease)
            }
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Recovery is the only path that bypasses admission for a service restart.
    /// Quarantine clears only after the restarted service reports a quiescent state.
    public func recoverRuntime() async throws {
        _ = try coordinator.beginRecovery()
        do {
            try await base.restartRuntimeService()
            let status = try await base.runtimeStatus()
            let idleStates: Set<RuntimeServiceState> = [.connected, .modelUnloaded, .modelLoaded]
            guard status.activeGenerationID == nil, idleStates.contains(status.state) else {
                throw RuntimeLeaseError.recoveryFailed(
                    message: "the restarted service did not report an idle state"
                )
            }
            coordinator.finishRecovery(succeeded: true)
        } catch {
            coordinator.finishRecovery(succeeded: false)
            if let typed = error as? RuntimeLeaseError { throw typed }
            throw RuntimeLeaseError.recoveryFailed(message: error.localizedDescription)
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

    public func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await base.embeddingStatus()
    }

    // MARK: Data plane

    public func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.loadModel(request)
    }

    public func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let permit = try admittedDataPlanePermit()
        let baseStream: AsyncThrowingStream<GenerationEvent, Error>
        do {
            baseStream = try base.generate(request)
        } catch {
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
                    } else {
                        // Fail closed: a waiting exclusive owner must not enter an
                        // XPC slot whose prior generation may still be unwinding.
                        permit.failClosed(
                            message: "Generation cancellation did not confirm runtime quiescence."
                        )
                    }
                } else {
                    permit.release()
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
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.countTokens(request)
    }

    public func unloadModel() async throws -> UnloadModelResponse {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.unloadModel()
    }

    public func reloadCurrentModel() async throws -> LoadModelResponse {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.reloadCurrentModel()
    }

    public func restartRuntimeService() async throws {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        try await base.restartRuntimeService()
    }

    public func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.loadEmbeddingModel(request)
    }

    public func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        let permit = try admittedDataPlanePermit()
        defer { permit.release() }
        return try await base.embedTexts(request)
    }

    private func admittedDataPlanePermit() throws -> RuntimeAdmissionPermit {
        try coordinator.acquireDataPlane(ownerToken: RuntimeLeaseTaskContext.ownerToken)
    }

    private func generationCancellationWasConfirmed(_ generationID: GenerationID) async -> Bool {
        let base = base
        let confirmation = Task.detached { () -> Bool in
            do {
                let response = try await base.cancelGeneration(generationID)
                guard response.generationID == generationID,
                      response.error == nil,
                      response.status == .cancelled || response.status == .notFound else {
                    return false
                }
                guard response.status == .notFound else { return true }
                for attempt in 0..<3_000 {
                    let status = try await base.runtimeStatus()
                    guard let activeGenerationID = status.activeGenerationID else { return true }
                    guard activeGenerationID == generationID else { return false }
                    if attempt < 2_999 {
                        try await Task<Never, Never>.sleep(for: .milliseconds(10))
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

private final class RuntimeAdmissionPermit: @unchecked Sendable {
    enum Ownership: Sendable {
        case ordinary
        case lease(UUID)
    }

    private let lock = NSLock()
    private let coordinator: RuntimeAdmissionCoordinator
    private let ownership: Ownership
    private var didRelease = false

    init(coordinator: RuntimeAdmissionCoordinator, ownership: Ownership) {
        self.coordinator = coordinator
        self.ownership = ownership
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldRelease {
            coordinator.releaseDataPlane(ownership: ownership)
        }
    }

    /// Converts an unconfirmed operation into recovery quarantine. Ordinary
    /// work has no exclusive lease purpose, so its quarantine remains unowned.
    func failClosed(message: String) {
        let shouldFail = lock.withLock {
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldFail {
            coordinator.failDataPlane(ownership: ownership, message: message)
        }
    }

    deinit {
        release()
    }
}

private final class RuntimeAdmissionCoordinator: @unchecked Sendable {
    private struct ActiveLease {
        var token: UUID
        var waiterID: UUID
        var purpose: RuntimeLeasePurpose
        var acquisitionClaimed: Bool
        var operationCount: Int
        var releaseRequested: Bool
        var releaseWaiters: [CheckedContinuation<Void, Never>]
    }

    private struct ExclusiveWaiter {
        var id: UUID
        var purpose: RuntimeLeasePurpose
        var continuation: CheckedContinuation<UUID, Error>
    }

    private struct RecoveryState {
        var purpose: RuntimeLeasePurpose?
        var message: String
    }

    private let lock = NSLock()
    private var ordinaryOperationCount = 0
    private var activeLease: ActiveLease?
    private var exclusiveWaiters: [ExclusiveWaiter] = []
    private var preCancelledWaiterIDs: Set<UUID> = []
    private var recovery: RecoveryState?
    private var recoveryInProgress = false
    private var observers: [UUID: AsyncStream<RuntimeAdmissionSnapshot>.Continuation] = [:]
    private var terminatedObserverIDs: Set<UUID> = []

    func snapshot() -> RuntimeAdmissionSnapshot {
        lock.withLock { snapshotLocked() }
    }

    func addObserver(
        _ id: UUID,
        continuation: AsyncStream<RuntimeAdmissionSnapshot>.Continuation
    ) {
        let initial: RuntimeAdmissionSnapshot? = lock.withLock {
            guard terminatedObserverIDs.remove(id) == nil else { return nil }
            observers[id] = continuation
            return snapshotLocked()
        }
        if let initial { continuation.yield(initial) }
    }

    func removeObserver(_ id: UUID) {
        lock.withLock {
            if observers.removeValue(forKey: id) == nil {
                terminatedObserverIDs.insert(id)
            }
        }
    }

    func acquireDataPlane(ownerToken: UUID?) throws -> RuntimeAdmissionPermit {
        let ownership: RuntimeAdmissionPermit.Ownership = try lock.withLock {
            if let recovery {
                throw recoveryError(for: recovery)
            }
            if var activeLease {
                guard ownerToken == activeLease.token else {
                    throw RuntimeLeaseError.reserved(purpose: activeLease.purpose)
                }
                activeLease.operationCount += 1
                self.activeLease = activeLease
                return .lease(activeLease.token)
            }
            if let waiter = exclusiveWaiters.first {
                throw RuntimeLeaseError.reserved(purpose: waiter.purpose)
            }
            ordinaryOperationCount += 1
            return .ordinary
        }
        return RuntimeAdmissionPermit(coordinator: self, ownership: ownership)
    }

    func releaseDataPlane(ownership: RuntimeAdmissionPermit.Ownership) {
        var activated: (ExclusiveWaiter, UUID)?
        var leaseReleaseWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch ownership {
        case .ordinary:
            ordinaryOperationCount = max(ordinaryOperationCount - 1, 0)
        case let .lease(token):
            if var lease = activeLease, lease.token == token {
                lease.operationCount = max(lease.operationCount - 1, 0)
                if lease.operationCount == 0, lease.releaseRequested {
                    leaseReleaseWaiters = lease.releaseWaiters
                    activeLease = nil
                } else {
                    activeLease = lease
                }
            }
        }
        activated = activateNextLocked()
        lock.unlock()

        for waiter in leaseReleaseWaiters { waiter.resume() }
        if let activated {
            activated.0.continuation.resume(returning: activated.1)
        }
        publishSnapshot()
    }

    func failDataPlane(
        ownership: RuntimeAdmissionPermit.Ownership,
        message: String
    ) {
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch ownership {
        case .ordinary:
            ordinaryOperationCount = max(ordinaryOperationCount - 1, 0)
            recovery = RecoveryState(
                purpose: exclusiveWaiters.first?.purpose,
                message: message
            )
            recoveryInProgress = false
        case let .lease(token):
            if let lease = activeLease, lease.token == token {
                releaseWaiters = lease.releaseWaiters
                activeLease = nil
                recovery = RecoveryState(purpose: lease.purpose, message: message)
                recoveryInProgress = false
            }
        }
        lock.unlock()

        for waiter in releaseWaiters { waiter.resume() }
        publishSnapshot()
    }

    func acquireExclusive(purpose: RuntimeLeasePurpose) async throws -> UUID {
        let waiterID = UUID()
        let token = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let admitted = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UUID, Error>) in
                enqueueExclusive(
                    id: waiterID,
                    purpose: purpose,
                    continuation: continuation
                )
            }
            guard claimExclusive(waiterID: waiterID, token: admitted) else {
                throw CancellationError()
            }
            return admitted
        } onCancel: {
            self.cancelExclusiveWaiter(id: waiterID)
        }

        if Task.isCancelled {
            await releaseLease(token: token)
            discardPreCancellation(waiterID)
            throw CancellationError()
        }
        discardPreCancellation(waiterID)
        return token
    }

    func releaseLease(token: UUID) async {
        await withCheckedContinuation { continuation in
            var resumeNow = false
            var activated: (ExclusiveWaiter, UUID)?
            lock.lock()
            if var lease = activeLease, lease.token == token {
                if lease.operationCount == 0 {
                    activeLease = nil
                    resumeNow = true
                    activated = activateNextLocked()
                } else {
                    lease.releaseRequested = true
                    lease.releaseWaiters.append(continuation)
                    activeLease = lease
                }
            } else {
                resumeNow = true
            }
            lock.unlock()

            if resumeNow { continuation.resume() }
            if let activated {
                activated.0.continuation.resume(returning: activated.1)
            }
            publishSnapshot()
        }
    }

    func markRecoveryRequired(
        token: UUID,
        purpose: RuntimeLeasePurpose,
        message: String
    ) {
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let lease = activeLease, lease.token == token {
            releaseWaiters = lease.releaseWaiters
            activeLease = nil
            recovery = RecoveryState(purpose: purpose, message: message)
            recoveryInProgress = false
        } else if recovery?.purpose == purpose {
            recovery?.message = message
        }
        lock.unlock()

        for waiter in releaseWaiters { waiter.resume() }
        publishSnapshot()
    }

    func beginRecovery() throws -> RuntimeLeasePurpose? {
        try lock.withLock {
            guard let recovery else {
                throw RuntimeLeaseError.recoveryFailed(message: "recovery is not required")
            }
            guard ordinaryOperationCount == 0 else {
                let suffix = ordinaryOperationCount == 1 ? "operation" : "operations"
                throw RuntimeLeaseError.recoveryFailed(
                    message: "recovery is waiting for \(ordinaryOperationCount) admitted runtime \(suffix) to finish"
                )
            }
            guard !recoveryInProgress else {
                throw RuntimeLeaseError.recoveryFailed(message: "recovery is already in progress")
            }
            recoveryInProgress = true
            return recovery.purpose
        }
    }

    func finishRecovery(succeeded: Bool) {
        var activated: (ExclusiveWaiter, UUID)?
        lock.lock()
        recoveryInProgress = false
        if succeeded {
            recovery = nil
            ordinaryOperationCount = 0
            activated = activateNextLocked()
        }
        lock.unlock()

        if let activated {
            activated.0.continuation.resume(returning: activated.1)
        }
        publishSnapshot()
    }

    private func enqueueExclusive(
        id: UUID,
        purpose: RuntimeLeasePurpose,
        continuation: CheckedContinuation<UUID, Error>
    ) {
        var failure: Error?
        var activated: (ExclusiveWaiter, UUID)?
        lock.lock()
        if preCancelledWaiterIDs.remove(id) != nil {
            failure = CancellationError()
        } else if let recovery {
            failure = recoveryError(for: recovery)
        } else {
            exclusiveWaiters.append(ExclusiveWaiter(
                id: id,
                purpose: purpose,
                continuation: continuation
            ))
            activated = activateNextLocked()
        }
        lock.unlock()

        if let failure {
            continuation.resume(throwing: failure)
        }
        if let activated {
            activated.0.continuation.resume(returning: activated.1)
        }
        publishSnapshot()
    }

    private func cancelExclusiveWaiter(id: UUID) {
        var cancelledWaiter: ExclusiveWaiter?
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        var activated: (ExclusiveWaiter, UUID)?
        lock.lock()
        if let index = exclusiveWaiters.firstIndex(where: { $0.id == id }) {
            cancelledWaiter = exclusiveWaiters.remove(at: index)
        } else if let lease = activeLease,
                  lease.waiterID == id,
                  !lease.acquisitionClaimed,
                  lease.operationCount == 0 {
            releaseWaiters = lease.releaseWaiters
            activeLease = nil
            activated = activateNextLocked()
        } else {
            preCancelledWaiterIDs.insert(id)
        }
        lock.unlock()

        cancelledWaiter?.continuation.resume(throwing: CancellationError())
        for waiter in releaseWaiters { waiter.resume() }
        if let activated {
            activated.0.continuation.resume(returning: activated.1)
        }
        publishSnapshot()
    }

    private func claimExclusive(waiterID: UUID, token: UUID) -> Bool {
        lock.withLock {
            guard preCancelledWaiterIDs.remove(waiterID) == nil,
                  var lease = activeLease,
                  lease.waiterID == waiterID,
                  lease.token == token else {
                return false
            }
            lease.acquisitionClaimed = true
            activeLease = lease
            return true
        }
    }

    private func discardPreCancellation(_ waiterID: UUID) {
        _ = lock.withLock {
            preCancelledWaiterIDs.remove(waiterID)
        }
    }

    private func activateNextLocked() -> (ExclusiveWaiter, UUID)? {
        guard recovery == nil,
              activeLease == nil,
              ordinaryOperationCount == 0,
              !exclusiveWaiters.isEmpty else { return nil }
        let waiter = exclusiveWaiters.removeFirst()
        let token = UUID()
        activeLease = ActiveLease(
            token: token,
            waiterID: waiter.id,
            purpose: waiter.purpose,
            acquisitionClaimed: false,
            operationCount: 0,
            releaseRequested: false,
            releaseWaiters: []
        )
        return (waiter, token)
    }

    private func snapshotLocked() -> RuntimeAdmissionSnapshot {
        if let recovery {
            return RuntimeAdmissionSnapshot(
                phase: .recoveryRequired,
                purpose: recovery.purpose,
                message: recovery.message
            )
        }
        if let activeLease {
            return RuntimeAdmissionSnapshot(
                phase: .exclusive,
                purpose: activeLease.purpose
            )
        }
        if let waiter = exclusiveWaiters.first {
            return RuntimeAdmissionSnapshot(
                phase: .waiting,
                purpose: waiter.purpose
            )
        }
        return .available
    }

    private func recoveryError(for recovery: RecoveryState) -> RuntimeLeaseError {
        if let purpose = recovery.purpose {
            return .recoveryRequired(purpose: purpose)
        }
        return .runtimeRecoveryRequired(message: recovery.message)
    }

    private func publishSnapshot() {
        let publication = lock.withLock {
            (snapshotLocked(), Array(observers.values))
        }
        for observer in publication.1 {
            observer.yield(publication.0)
        }
    }
}
