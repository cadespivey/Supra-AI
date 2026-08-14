import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions

enum ArchitectureUXRuntimeWire {
    static let modelID = ModelID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000713")!
    )
    static let otherModelID = ModelID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000811")!
    )
    static let repositoryID = "model-wire-713"
    static let revision = "rev-7"
    static let fingerprintSHA256 = String(repeating: "7", count: 64)
    static let otherFingerprintSHA256 = String(repeating: "8", count: 64)
    static let forbiddenDefault = "DEFAULT-000"
    static let queueCapacity = 7
    static let overflowOrdinal = 8

    static let binding = ModelExecutionModelBinding(
        modelID: modelID,
        repositoryID: repositoryID,
        revision: revision,
        artifactFingerprintSHA256: fingerprintSHA256
    )

    static let otherBinding = ModelExecutionModelBinding(
        modelID: otherModelID,
        repositoryID: "other-model-wire-811",
        revision: "rev-8",
        artifactFingerprintSHA256: otherFingerprintSHA256
    )

    static func taskID(_ suffix: String) -> ModelExecutionTaskID {
        ModelExecutionTaskID(rawValue: "runtime-task-\(suffix)")
    }

    static func request(
        _ suffix: String,
        operation: ModelExecutionOperation = .generation,
        priority: ModelExecutionPriority,
        binding: ModelExecutionModelBinding? = binding,
        duplicateKey: String? = nil
    ) -> ModelExecutionRequest {
        ModelExecutionRequest(
            taskID: taskID(suffix),
            operation: operation,
            priority: priority,
            modelBinding: binding,
            duplicateKey: duplicateKey
        )
    }

    static func generationRequest(
        generationID: GenerationID = GenerationID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000719")!
        ),
        modelID: ModelID = modelID,
        fingerprintSHA256: String = fingerprintSHA256,
        prompt: String = "runtime-binding-prompt-727"
    ) -> GenerateRequest {
        GenerateRequest(
            generationID: generationID,
            modelID: modelID,
            expectedModelSHA256: fingerprintSHA256,
            prompt: prompt,
            systemPrompt: "runtime-binding-system-733",
            contextWorkload: .ordinaryConversation,
            options: GenerationOptions(
                temperature: 0.17,
                topP: 0.73,
                maxContextTokens: 7_713,
                maxOutputTokens: 77
            )
        )
    }
}

final class ArchitectureUXManualRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { tick }
    }

    func advance(by delta: UInt64) {
        lock.withLock { tick += delta }
    }
}

actor ArchitectureUXAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        if !isOpen {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}

actor ArchitectureUXAsyncSignal {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(for target: Int = 1) async {
        if count >= target { return }
        await withCheckedContinuation { continuation in
            if count >= target {
                continuation.resume()
            } else {
                waiters.append((target, continuation))
            }
        }
    }
}

actor ArchitectureUXRuntimeLaneProbe {
    private(set) var trace: [String] = []
    private(set) var activeGPUOperations = 0
    private(set) var maximumActiveGPUOperations = 0

    func enter(_ label: String) {
        activeGPUOperations += 1
        maximumActiveGPUOperations = max(maximumActiveGPUOperations, activeGPUOperations)
        trace.append(label)
    }

    func leave() {
        activeGPUOperations -= 1
    }

    func record(_ label: String) {
        trace.append(label)
    }

    func snapshot() -> (trace: [String], active: Int, maximum: Int) {
        (trace, activeGPUOperations, maximumActiveGPUOperations)
    }
}

enum ArchitectureUXRuntimeTestFailure: Error, Equatable {
    case timedOut(String)
    case syntheticFailure713
}

func waitForArchitectureUXRuntime(
    _ label: String,
    attempts: Int = 2_000,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task<Never, Never>.sleep(for: .milliseconds(2))
    }
    throw ArchitectureUXRuntimeTestFailure.timedOut(label)
}

func architectureUXRuntimeCoordinator(
    base: any RuntimeClientProtocol = ArchitectureUXImmediateRuntimeClient(),
    clock: ArchitectureUXManualRuntimeClock = ArchitectureUXManualRuntimeClock(),
    queueCapacity: Int = ArchitectureUXRuntimeWire.queueCapacity,
    agingIntervalTicks: UInt64 = 10
) -> ModelExecutionCoordinator {
    ModelExecutionCoordinator(
        runtimeClient: RuntimeSafetyClient(base: base),
        configuration: ModelExecutionConfiguration(
            maximumQueuedTasks: queueCapacity,
            agingIntervalTicks: agingIntervalTicks
        ),
        monotonicNow: { clock.now() }
    )
}

final class ArchitectureUXImmediateRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCountModelIDs: [ModelID] = []
    private var storedGenerateRequests: [GenerateRequest] = []
    private var storedEmbeddingLoadRequests: [LoadEmbeddingModelRequest] = []

    var countModelIDs: [ModelID] { lock.withLock { storedCountModelIDs } }
    var generateRequests: [GenerateRequest] { lock.withLock { storedGenerateRequests } }
    var embeddingLoadRequests: [LoadEmbeddingModelRequest] {
        lock.withLock { storedEmbeddingLoadRequests }
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock { storedGenerateRequests.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 1,
                timestamp: Date(timeIntervalSince1970: 1_946_507_713),
                type: .generationStarted
            ))
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 2,
                timestamp: Date(timeIntervalSince1970: 1_946_507_719),
                type: .token,
                tokenText: "T_RUNTIME_BIND_739"
            ))
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 3,
                timestamp: Date(timeIntervalSince1970: 1_946_507_727),
                type: .generationCompleted
            ))
            continuation.finish()
        }
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        lock.withLock { storedCountModelIDs.append(request.modelID) }
        return CountTokensResponse(modelID: request.modelID, counts: request.texts.map { _ in 713 })
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: ArchitectureUXRuntimeWire.modelID)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ArchitectureUXRuntimeWire.modelID,
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        lock.withLock { storedEmbeddingLoadRequests.append(request) }
        LoadEmbeddingModelResponse(
            state: .loaded,
            embeddingModelID: request.embeddingModelID,
            dimension: request.expectedDimension ?? 7
        )
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(
            state: .loaded,
            vectors: request.texts.map { _ in [0.7, 0.1, 0.3] },
            dimension: 3
        )
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .loaded)
    }
}

final class ArchitectureUXCancellationMismatchRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var activeGenerationID: GenerationID?
    private var storedPrompts: [String] = []

    let started = ArchitectureUXAsyncSignal()

    var prompts: [String] { lock.withLock { storedPrompts } }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock {
            activeGenerationID = request.generationID
            storedPrompts.append(request.prompt)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 1,
                timestamp: Date(timeIntervalSince1970: 1_946_507_997),
                type: .generationStarted
            ))
            Task { await self.started.signal() }
            continuation.onTermination = { @Sendable _ in }
        }
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        CountTokensResponse(modelID: request.modelID, counts: request.texts.map { _ in 713 })
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(
            status: .cancelled,
            generationID: GenerationID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000997")!
            )
        )
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: ArchitectureUXRuntimeWire.modelID)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .generating,
            loadedModelID: ArchitectureUXRuntimeWire.modelID,
            activeGenerationID: lock.withLock { activeGenerationID },
            message: "cancellation-mismatch-wire-997",
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        LoadEmbeddingModelResponse(state: .loaded, embeddingModelID: request.embeddingModelID)
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(state: .loaded, vectors: request.texts.map { _ in [0.7] }, dimension: 1)
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .loaded)
    }
}

enum ArchitectureUXHeldRuntimeOperation: String, Sendable {
    case embeddingBatch
    case modelLoad
}

/// A non-streaming data-plane probe whose reply ignores cooperative Task
/// cancellation, matching RuntimeClient's checked-continuation XPC transport.
/// The service terminal is controlled explicitly by `allowTerminalReply`.
final class ArchitectureUXHeldRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    let operationStarted = ArchitectureUXAsyncSignal()
    let allowTerminalReply = ArchitectureUXAsyncGate()

    private let heldOperation: ArchitectureUXHeldRuntimeOperation
    private let fallback = ArchitectureUXImmediateRuntimeClient()

    init(heldOperation: ArchitectureUXHeldRuntimeOperation) {
        self.heldOperation = heldOperation
    }

    func connect() async throws {
        try await fallback.connect()
    }

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        if heldOperation == .modelLoad {
            await operationStarted.signal()
            await allowTerminalReply.wait()
        }
        return try await fallback.loadModel(request)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try fallback.generate(request)
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        try await fallback.countTokens(request)
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        try await fallback.cancelGeneration(generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        try await fallback.recentEvents(for: generationID, after: sequenceNumber)
    }

    func unloadModel() async throws -> UnloadModelResponse {
        try await fallback.unloadModel()
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        try await fallback.reloadCurrentModel()
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        try await fallback.runtimeStatus()
    }

    func restartRuntimeService() async throws {
        try await fallback.restartRuntimeService()
    }

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        try await fallback.loadEmbeddingModel(request)
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        if heldOperation == .embeddingBatch {
            await operationStarted.signal()
            await allowTerminalReply.wait()
        }
        return try await fallback.embedTexts(request)
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await fallback.embeddingStatus()
    }
}
