import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// Runtime facade scoped to one admitted invocation and its exact model.
///
/// Feature code holds this permit through preparation, token counting,
/// generation, and its terminal flush. The coordinator remains the sole owner
/// of physical-lane admission; the wrapped RuntimeSafetyClient remains the sole
/// owner of cancellation confirmation and fail-closed quarantine.
public final class ModelExecutionPermit: RuntimeFeatureClientProtocol, @unchecked Sendable {
    public let modelBinding: ModelExecutionModelBinding?

    private let taskID: ModelExecutionTaskID
    private let runtimeClient: RuntimeSafetyClient
    private let coordinator: ModelExecutionCoordinator
    private let generationState = ModelExecutionPermitGenerationState()

    init(
        taskID: ModelExecutionTaskID,
        modelBinding: ModelExecutionModelBinding?,
        runtimeClient: RuntimeSafetyClient,
        coordinator: ModelExecutionCoordinator
    ) {
        self.taskID = taskID
        self.modelBinding = modelBinding
        self.runtimeClient = runtimeClient
        self.coordinator = coordinator
    }

    /// Projects the shared lifecycle once preparation has reached execution.
    public func markRunning() async {
        await coordinator.markRunning(taskID: taskID)
    }

    /// Relinquishes the physical lane only between bounded background batches.
    /// The call returns after this invocation has been admitted again.
    public func yieldAtSafeBoundary() async throws {
        try await coordinator.yieldAtSafeBoundary(taskID: taskID)
    }

    public func connect() async throws {
        try await runtimeClient.connect()
    }

    public func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        try validate(modelID: request.modelID)
        if modelBinding != nil {
            guard let contentBinding = request.contentBinding else {
                throw ModelExecutionError.modelBindingMismatch
            }
            try validate(
                repositoryID: contentBinding.repositoryID,
                revision: contentBinding.revision,
                fingerprintSHA256: contentBinding.fingerprintSHA256
            )
        }
        return try await runtimeClient.loadModel(request)
    }

    public func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try validate(modelID: request.modelID)
        var authorizedRequest = request
        if let modelBinding {
            if let expectedModelSHA256 = request.expectedModelSHA256 {
                guard expectedModelSHA256 == modelBinding.artifactFingerprintSHA256 else {
                    throw ModelExecutionError.modelBindingMismatch
                }
            } else {
                // Feature requests created before content-bound admission do not
                // own runtime authority. Project the permit's already-verified
                // artifact identity into the wire request so the XPC boundary
                // still receives an exact fingerprint. A caller-supplied,
                // conflicting fingerprint continues to fail closed above.
                authorizedRequest = GenerateRequest(
                    generationID: request.generationID,
                    modelID: request.modelID,
                    expectedModelSHA256: modelBinding.artifactFingerprintSHA256,
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    history: request.history,
                    contextWorkload: request.contextWorkload,
                    allowsExactSourceRepacking: request.allowsExactSourceRepacking,
                    options: request.options
                )
            }
            guard authorizedRequest.expectedModelSHA256
                    == modelBinding.artifactFingerprintSHA256 else {
                throw ModelExecutionError.modelBindingMismatch
            }
        }
        let runtimeStream = try runtimeClient.generate(authorizedRequest)
        generationState.begin(generationID: request.generationID)
        return runtimeStream
    }

    public func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        try validate(modelID: request.modelID)
        return try await runtimeClient.countTokens(request)
    }

    public func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        try await runtimeClient.cancelGeneration(generationID)
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
        try await runtimeClient.unloadModel()
    }

    public func reloadCurrentModel() async throws -> LoadModelResponse {
        try await runtimeClient.reloadCurrentModel()
    }

    public func runtimeStatus() async throws -> RuntimeStatus {
        try await runtimeClient.runtimeStatus()
    }

    public func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        try validate(modelID: ModelID(request.embeddingModelID.rawValue))
        if modelBinding != nil {
            guard let contentBinding = request.contentBinding else {
                throw ModelExecutionError.modelBindingMismatch
            }
            try validate(
                repositoryID: contentBinding.repositoryID,
                revision: contentBinding.revision,
                fingerprintSHA256: contentBinding.fingerprintSHA256
            )
        }
        return try await runtimeClient.loadEmbeddingModel(request)
    }

    public func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        try validate(modelID: ModelID(request.embeddingModelID.rawValue))
        return try await runtimeClient.embedTexts(request)
    }

    public func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await runtimeClient.embeddingStatus()
    }

    private func validate(modelID: ModelID) throws {
        guard modelBinding?.modelID == modelID || modelBinding == nil else {
            throw ModelExecutionError.modelBindingMismatch
        }
    }

    private func validate(
        repositoryID: String,
        revision: String,
        fingerprintSHA256: String
    ) throws {
        guard let modelBinding,
              modelBinding.repositoryID == repositoryID,
              modelBinding.revision == revision,
              modelBinding.artifactFingerprintSHA256 == fingerprintSHA256 else {
            throw ModelExecutionError.modelBindingMismatch
        }
    }

    func awaitGenerationQuiescenceIfNeeded() async -> RuntimeGenerationQuiescenceResolution? {
        guard let generationID = generationState.generationAwaitingCancellation else {
            return nil
        }
        return await runtimeClient.awaitQuiescenceResolution(for: generationID)
    }
}

private final class ModelExecutionPermitGenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generationID: GenerationID?

    var generationAwaitingCancellation: GenerationID? {
        lock.withLock { generationID }
    }

    func begin(generationID: GenerationID) {
        lock.withLock { self.generationID = generationID }
    }
}
