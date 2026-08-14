import Foundation
import SupraCore
@testable import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest

final class RuntimeSafetyClientTests: XCTestCase {
    func testTRuntimeSafe01UnconfirmedCancellationQuarantinesEveryLaterDataPlaneCall() async throws {
        // T-RUNTIME-SAFE-01 expected RED: RuntimeSafetyClient does not exist.
        // The retired exclusive-Review wrapper is currently the only owner of
        // generic cancellation confirmation and recovery quarantine.
        let generationID = GenerationID()
        let base = RuntimeSafetyBaseClient(cancellationFailures: 1)
        let client = RuntimeSafetyClient(base: base)
        let stream = try client.generate(request(
            generationID: generationID,
            prompt: "ordinary-cancellation-needs-recovery-817"
        ))
        let consumer = Task { try await drainRuntimeSafetyStream(stream) }
        try await waitForRuntimeSafety("ordinary generation reaches base") {
            base.generatedPrompts == ["ordinary-cancellation-needs-recovery-817"]
        }

        consumer.cancel()
        _ = await consumer.result
        try await waitForRuntimeSafety("generic recovery quarantine") {
            client.currentRecoverySnapshot().phase == .recoveryRequired
        }

        let blockedError = await runtimeSafetyError {
            _ = try await client.countTokens(
                CountTokensRequest(modelID: ModelID(), texts: ["blocked-data-plane-821"])
            )
        }
        guard case let .recoveryRequired(message) = blockedError as? RuntimeSafetyError else {
            return XCTFail("expected typed recovery quarantine, got \(String(describing: blockedError))")
        }
        XCTAssertTrue(message.contains("cancellation"))
        XCTAssertEqual(base.countTokenCallCount, 0, "quarantined work must not reach XPC")

        // Observation and cancellation remain usable while data-plane work is
        // quarantined, so an operator can diagnose and unwind safely.
        try await client.connect()
        _ = try await client.runtimeStatus()
        _ = try await client.embeddingStatus()
        _ = try await client.recentEvents(for: generationID, after: 17)
        let cancellation = try await client.cancelGeneration(generationID)
        XCTAssertEqual(cancellation.status, .cancelled)
        XCTAssertEqual(base.connectCallCount, 1)
        XCTAssertEqual(base.explicitRecentEventRequests, [17])
        XCTAssertEqual(base.cancelCallCount, 2)
    }

    func testTRuntimeSafe02RecoveryWaitsForEveryAlreadyAdmittedOrdinaryCall() async throws {
        // T-RUNTIME-SAFE-02 expected RED: the neutral safety facade does not
        // exist. Recovery must not reconnect while a token/embedding/model call
        // admitted before quarantine is still using the runtime connection.
        let base = RuntimeSafetyBaseClient(cancellationFailures: 1, holdTokenCounts: true)
        let client = RuntimeSafetyClient(base: base)
        let heldCount = Task {
            try await client.countTokens(
                CountTokensRequest(modelID: ModelID(), texts: ["already-admitted-ordinary-call-823"])
            )
        }
        defer {
            base.releaseTokenCounts()
            heldCount.cancel()
        }
        try await waitForRuntimeSafety("token count is admitted and held") {
            base.countTokenCallCount == 1
        }

        let generationID = GenerationID()
        let stream = try client.generate(request(
            generationID: generationID,
            prompt: "second-call-cannot-confirm-cancellation-827"
        ))
        let consumer = Task { try await drainRuntimeSafetyStream(stream) }
        try await waitForRuntimeSafety("generation reaches base") {
            base.generatedPrompts == ["second-call-cannot-confirm-cancellation-827"]
        }
        consumer.cancel()
        _ = await consumer.result
        try await waitForRuntimeSafety("cancellation enters recovery") {
            client.currentRecoverySnapshot().phase == .recoveryRequired
        }

        let prematureError = await runtimeSafetyError {
            try await client.recoverRuntime()
        }
        guard case let .recoveryFailed(message) = prematureError as? RuntimeSafetyError else {
            return XCTFail("expected typed recovery deferral, got \(String(describing: prematureError))")
        }
        XCTAssertTrue(message.contains("admitted runtime operation"))
        XCTAssertEqual(base.restartCallCount, 0)

        base.releaseTokenCounts()
        let response = try await heldCount.value
        XCTAssertEqual(response.counts, [37])
        try await client.recoverRuntime()

        XCTAssertEqual(client.currentRecoverySnapshot(), .available)
        XCTAssertEqual(base.restartCallCount, 1)
    }

    func testTRuntimeSafe03RecoveryRequiresRestartAndConfirmedIdleStatus() async throws {
        // T-RUNTIME-SAFE-03 expected RED: the neutral recovery API is missing.
        // A reconnect alone cannot clear quarantine while the service still
        // reports an active generation.
        let generationID = GenerationID()
        let base = RuntimeSafetyBaseClient(cancellationFailures: 1)
        let client = RuntimeSafetyClient(base: base)
        let stream = try client.generate(request(
            generationID: generationID,
            prompt: "recovery-must-confirm-idle-829"
        ))
        let consumer = Task { try await drainRuntimeSafetyStream(stream) }
        try await waitForRuntimeSafety("generation reaches base") {
            base.generatedPrompts == ["recovery-must-confirm-idle-829"]
        }
        consumer.cancel()
        _ = await consumer.result
        try await waitForRuntimeSafety("recovery quarantine") {
            client.currentRecoverySnapshot().phase == .recoveryRequired
        }

        base.setStatus(RuntimeStatus(
            state: .generating,
            loadedModelID: ModelID(),
            activeGenerationID: generationID,
            message: nil,
            metrics: nil
        ))
        let nonidleError = await runtimeSafetyError {
            try await client.recoverRuntime()
        }
        guard case .recoveryFailed = nonidleError as? RuntimeSafetyError else {
            return XCTFail("active runtime must keep recovery quarantined")
        }
        XCTAssertEqual(client.currentRecoverySnapshot().phase, .recoveryRequired)

        base.setStatus(RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ModelID(),
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        ))
        try await client.recoverRuntime()
        XCTAssertEqual(client.currentRecoverySnapshot(), .available)
        XCTAssertEqual(base.restartCallCount, 2)
    }

    func testTXPCCancel01MismatchedCancellationIdentityFailsClosed() async throws {
        // T-XPC-CANCEL-01 expected RED: cancellation confirmation has no
        // injectable bounded policy, so the exact mismatch/timeout matrix is
        // not deterministically executable before the retired wrapper is gone.
        let generationID = GenerationID()
        let mismatchedID = GenerationID()
        let base = RuntimeSafetyBaseClient(
            cancellationFailures: 0,
            cancellationReply: .mismatched(mismatchedID)
        )
        let client = RuntimeSafetyClient(
            base: base,
            cancellationConfirmationPolicy: .test(attempts: 3)
        )

        try await cancelRuntimeSafetyGeneration(
            generationID,
            prompt: "mismatched-cancel-identity-907",
            client: client,
            base: base
        )

        XCTAssertEqual(client.currentRecoverySnapshot().phase, .recoveryRequired)
        XCTAssertEqual(base.cancelCallCount, 1)
        XCTAssertEqual(base.runtimeStatusCallCount, 0)
        XCTAssertEqual(base.returnedCancellationIDs, [mismatchedID])
    }

    func testTXPCCancel01FailedCancellationStatusFailsClosed() async throws {
        let generationID = GenerationID()
        let base = RuntimeSafetyBaseClient(
            cancellationFailures: 0,
            cancellationReply: .failed
        )
        let client = RuntimeSafetyClient(
            base: base,
            cancellationConfirmationPolicy: .test(attempts: 3)
        )

        try await cancelRuntimeSafetyGeneration(
            generationID,
            prompt: "failed-cancel-status-911",
            client: client,
            base: base
        )

        XCTAssertEqual(client.currentRecoverySnapshot().phase, .recoveryRequired)
        XCTAssertEqual(base.cancelCallCount, 1)
        XCTAssertEqual(base.runtimeStatusCallCount, 0)
    }

    func testTXPCCancel01NotFoundRequiresExactQuiescenceAndTimesOutBoundedly() async throws {
        let generationID = GenerationID()
        let base = RuntimeSafetyBaseClient(
            cancellationFailures: 0,
            cancellationReply: .notFound
        )
        base.setStatus(RuntimeStatus(
            state: .generating,
            loadedModelID: ModelID(),
            activeGenerationID: generationID,
            message: "same generation remains active 919",
            metrics: nil
        ))
        let client = RuntimeSafetyClient(
            base: base,
            cancellationConfirmationPolicy: .test(attempts: 3)
        )

        try await cancelRuntimeSafetyGeneration(
            generationID,
            prompt: "not-found-still-active-929",
            client: client,
            base: base
        )

        XCTAssertEqual(client.currentRecoverySnapshot().phase, .recoveryRequired)
        XCTAssertEqual(base.runtimeStatusCallCount, 3)
        XCTAssertEqual(base.countTokenCallCount, 0)
    }

    func testTXPCCancel01NotFoundAcceptsOnlyIdleAndRejectsAnotherActiveIdentity() async throws {
        let idleGenerationID = GenerationID()
        let idleBase = RuntimeSafetyBaseClient(
            cancellationFailures: 0,
            cancellationReply: .notFound
        )
        idleBase.setStatus(RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ModelID(),
            activeGenerationID: nil,
            message: "idle-after-not-found-937",
            metrics: nil
        ))
        let idleClient = RuntimeSafetyClient(
            base: idleBase,
            cancellationConfirmationPolicy: .test(attempts: 3)
        )
        try await cancelRuntimeSafetyGeneration(
            idleGenerationID,
            prompt: "not-found-idle-941",
            client: idleClient,
            base: idleBase,
            expectedPhase: .available
        )
        XCTAssertEqual(idleBase.runtimeStatusCallCount, 1)
        _ = try await idleClient.countTokens(
            CountTokensRequest(modelID: ModelID(), texts: ["admitted-after-idle-947"])
        )
        XCTAssertEqual(idleBase.countTokenCallCount, 1)

        let requestedID = GenerationID()
        let otherActiveID = GenerationID()
        let otherBase = RuntimeSafetyBaseClient(
            cancellationFailures: 0,
            cancellationReply: .notFound
        )
        otherBase.setStatus(RuntimeStatus(
            state: .generating,
            loadedModelID: ModelID(),
            activeGenerationID: otherActiveID,
            message: "different generation active 953",
            metrics: nil
        ))
        let otherClient = RuntimeSafetyClient(
            base: otherBase,
            cancellationConfirmationPolicy: .test(attempts: 3)
        )
        try await cancelRuntimeSafetyGeneration(
            requestedID,
            prompt: "not-found-other-active-967",
            client: otherClient,
            base: otherBase
        )
        XCTAssertEqual(otherClient.currentRecoverySnapshot().phase, .recoveryRequired)
        XCTAssertEqual(otherBase.runtimeStatusCallCount, 1)
    }

    private func request(generationID: GenerationID, prompt: String) -> GenerateRequest {
        GenerateRequest(
            generationID: generationID,
            modelID: ModelID(),
            prompt: prompt,
            systemPrompt: nil,
            contextWorkload: .ordinaryConversation,
            options: GenerationOptions(maxOutputTokens: 32)
        )
    }
}

private extension RuntimeCancellationConfirmationPolicy {
    static func test(attempts: Int) -> RuntimeCancellationConfirmationPolicy {
        RuntimeCancellationConfirmationPolicy(
            maxStatusPollAttempts: attempts,
            statusPollInterval: .zero
        )
    }
}

private func cancelRuntimeSafetyGeneration(
    _ generationID: GenerationID,
    prompt: String,
    client: RuntimeSafetyClient,
    base: RuntimeSafetyBaseClient,
    expectedPhase: RuntimeRecoverySnapshot.Phase = .recoveryRequired
) async throws {
    let stream = try client.generate(GenerateRequest(
        generationID: generationID,
        modelID: ModelID(),
        prompt: prompt,
        systemPrompt: nil,
        contextWorkload: .ordinaryConversation,
        options: GenerationOptions(maxOutputTokens: 17)
    ))
    let consumer = Task { try await drainRuntimeSafetyStream(stream) }
    try await waitForRuntimeSafety("generation reaches cancellation base") {
        base.generatedPrompts == [prompt]
    }
    consumer.cancel()
    _ = await consumer.result
    try await waitForRuntimeSafety("cancellation reaches expected safety phase") {
        if expectedPhase == .available {
            return base.cancelCallCount == 1
                && base.runtimeStatusCallCount >= 1
                && client.currentRecoverySnapshot().phase == .available
        }
        return client.currentRecoverySnapshot().phase == expectedPhase
    }
}

private final class RuntimeSafetyBaseClient: RuntimeClientProtocol, @unchecked Sendable {
    enum CancellationReply: Sendable {
        case cancelled
        case mismatched(GenerationID)
        case notFound
        case failed
    }

    private let lock = NSLock()
    private var remainingCancellationFailures: Int
    private let cancellationReply: CancellationReply
    private var tokenCountGateOpen: Bool
    private var tokenCountWaiters: [CheckedContinuation<Void, Never>] = []
    private var storedStatus = RuntimeStatus(
        state: .modelLoaded,
        loadedModelID: ModelID(),
        activeGenerationID: nil,
        message: nil,
        metrics: nil
    )
    private var storedGeneratedPrompts: [String] = []
    private var storedCountTokenCallCount = 0
    private var storedConnectCallCount = 0
    private var storedRestartCallCount = 0
    private var storedCancelCallCount = 0
    private var storedRuntimeStatusCallCount = 0
    private var storedReturnedCancellationIDs: [GenerationID] = []
    private var storedRecentEventRequests: [Int] = []

    init(
        cancellationFailures: Int,
        holdTokenCounts: Bool = false,
        cancellationReply: CancellationReply = .cancelled
    ) {
        remainingCancellationFailures = cancellationFailures
        tokenCountGateOpen = !holdTokenCounts
        self.cancellationReply = cancellationReply
    }

    var generatedPrompts: [String] { lock.withLock { storedGeneratedPrompts } }
    var countTokenCallCount: Int { lock.withLock { storedCountTokenCallCount } }
    var connectCallCount: Int { lock.withLock { storedConnectCallCount } }
    var restartCallCount: Int { lock.withLock { storedRestartCallCount } }
    var cancelCallCount: Int { lock.withLock { storedCancelCallCount } }
    var runtimeStatusCallCount: Int { lock.withLock { storedRuntimeStatusCallCount } }
    var returnedCancellationIDs: [GenerationID] {
        lock.withLock { storedReturnedCancellationIDs }
    }
    var explicitRecentEventRequests: [Int] { lock.withLock { storedRecentEventRequests } }

    func setStatus(_ status: RuntimeStatus) {
        lock.withLock { storedStatus = status }
    }

    func releaseTokenCounts() {
        let waiters = lock.withLock {
            guard !tokenCountGateOpen else { return [CheckedContinuation<Void, Never>]() }
            tokenCountGateOpen = true
            let pending = tokenCountWaiters
            tokenCountWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func connect() async throws {
        lock.withLock { storedConnectCallCount += 1 }
    }

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock { storedGeneratedPrompts.append(request.prompt) }
        return AsyncThrowingStream { continuation in
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                type: .generationStarted
            ))
        }
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        lock.withLock { storedCountTokenCallCount += 1 }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if tokenCountGateOpen { return true }
                tokenCountWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return CountTokensResponse(modelID: request.modelID, counts: request.texts.map { _ in 37 })
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        let shouldFail = lock.withLock {
            storedCancelCallCount += 1
            if remainingCancellationFailures > 0 {
                remainingCancellationFailures -= 1
                return true
            }
            return false
        }
        if shouldFail { throw RuntimeSafetyBaseError.cancellationRejected }
        let response: CancelGenerationResponse
        switch cancellationReply {
        case .cancelled:
            response = CancelGenerationResponse(status: .cancelled, generationID: generationID)
        case let .mismatched(returnedID):
            response = CancelGenerationResponse(status: .cancelled, generationID: returnedID)
        case .notFound:
            response = CancelGenerationResponse(status: .notFound, generationID: generationID)
        case .failed:
            response = CancelGenerationResponse(status: .failed, generationID: generationID)
        }
        lock.withLock { storedReturnedCancellationIDs.append(response.generationID) }
        return response
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        lock.withLock { storedRecentEventRequests.append(sequenceNumber) }
        return []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: lock.withLock { storedStatus.loadedModelID })
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        lock.withLock {
            storedRuntimeStatusCallCount += 1
            return storedStatus
        }
    }

    func restartRuntimeService() async throws {
        lock.withLock { storedRestartCallCount += 1 }
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .unloaded)
    }
}

private enum RuntimeSafetyBaseError: Error {
    case cancellationRejected
}

private func drainRuntimeSafetyStream(
    _ stream: AsyncThrowingStream<GenerationEvent, Error>
) async throws {
    for try await _ in stream {}
}

private func runtimeSafetyError(
    _ operation: () async throws -> Void
) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

private enum RuntimeSafetyTestTimeout: Error {
    case expired(String)
}

private func waitForRuntimeSafety(
    _ description: String,
    attempts: Int = 400,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task<Never, Never>.sleep(for: .milliseconds(5))
    }
    throw RuntimeSafetyTestTimeout.expired(description)
}
