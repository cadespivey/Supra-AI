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

    private func request(generationID: GenerationID, prompt: String) -> GenerateRequest {
        GenerateRequest(
            generationID: generationID,
            modelID: ModelID(),
            prompt: prompt,
            systemPrompt: nil,
            options: GenerationOptions(maxOutputTokens: 32)
        )
    }
}

private final class RuntimeSafetyBaseClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingCancellationFailures: Int
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
    private var storedRecentEventRequests: [Int] = []

    init(cancellationFailures: Int, holdTokenCounts: Bool = false) {
        remainingCancellationFailures = cancellationFailures
        tokenCountGateOpen = !holdTokenCounts
    }

    var generatedPrompts: [String] { lock.withLock { storedGeneratedPrompts } }
    var countTokenCallCount: Int { lock.withLock { storedCountTokenCallCount } }
    var connectCallCount: Int { lock.withLock { storedConnectCallCount } }
    var restartCallCount: Int { lock.withLock { storedRestartCallCount } }
    var cancelCallCount: Int { lock.withLock { storedCancelCallCount } }
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
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
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
        lock.withLock { storedStatus }
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
