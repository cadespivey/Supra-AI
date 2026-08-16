import SupraCore
import SupraRuntimeInterface

/// Feature-facing runtime surface. GPU-backed methods are admitted by the
/// shared model-execution coordinator; observation and exact cancellation are
/// independently admitted. Recovery/reset methods are deliberately absent.
public protocol RuntimeFeatureClientProtocol: Sendable {
    /// Eagerly establishes the XPC connection. Reserved for explicit lifecycle
    /// management; the connection is otherwise established lazily on first use.
    func connect() async throws
    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse
    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error>
    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse
    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse
    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent]
    func unloadModel() async throws -> UnloadModelResponse
    func reloadCurrentModel() async throws -> LoadModelResponse
    func runtimeStatus() async throws -> RuntimeStatus
    // MARK: - Milestone 3: embeddings

    func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse
    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse
    func embeddingStatus() async throws -> EmbeddingModelStatus
}

/// Privileged process-lifecycle controls. Ordinary feature gateways and scoped
/// model-execution permits intentionally expose only
/// `RuntimeFeatureClientProtocol`.
public protocol RuntimeResidencyClientProtocol: Sendable {
    func runtimeResidencySnapshot() async throws -> RuntimeServiceResidencySnapshot
    func evictRuntimeArtifact(
        _ request: RuntimeServiceArtifactEvictionRequest
    ) async throws -> RuntimeServiceArtifactEvictionResponse
    func resetRuntime(_ request: RuntimeServiceResetRequest) async throws -> RuntimeServiceResetReceipt
}

/// Privileged lifecycle surface held only by the process composition and
/// RuntimeSafety recovery owner.
public protocol RuntimeRecoveryClientProtocol: RuntimeResidencyClientProtocol {
    /// Tears down and re-establishes the XPC connection.
    func restartRuntimeService() async throws
}

/// Backward-compatible transport surface for low-level clients and test
/// doubles. Ordinary feature code receives only `RuntimeFeatureClientProtocol`
/// through `ModelExecutionGateway`; production transport owners additionally
/// conform to `RuntimeRecoveryClientProtocol`.
public protocol RuntimeClientProtocol: RuntimeFeatureClientProtocol {
    func restartRuntimeService() async throws
}

public extension RuntimeFeatureClientProtocol {
    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        throw RuntimeClientError.remoteInvocationFailed(
            "Token counting is not supported by this runtime client."
        )
    }

    // Default implementations so non-embedding test doubles need not implement
    // the M3 embedding surface. The real RuntimeClient overrides all three.
    func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse {
        LoadEmbeddingModelResponse(
            state: .failed,
            embeddingModelID: request.embeddingModelID,
            error: RuntimeError(category: "unsupported", message: "Embeddings are not supported by this runtime client.")
        )
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(
            state: .failed,
            error: RuntimeError(category: "unsupported", message: "Embeddings are not supported by this runtime client.")
        )
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .unloaded)
    }
}
