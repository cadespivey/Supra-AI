import SupraCore
import SupraRuntimeInterface

public protocol RuntimeClientProtocol: Sendable {
    /// Eagerly establishes the XPC connection. Reserved for explicit lifecycle
    /// management; the connection is otherwise established lazily on first use.
    func connect() async throws
    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse
    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error>
    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse
    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent]
    func unloadModel() async throws -> UnloadModelResponse
    func reloadCurrentModel() async throws -> LoadModelResponse
    func runtimeStatus() async throws -> RuntimeStatus
    /// Tears down and re-establishes the XPC connection. Reserved for runtime
    /// recovery; not currently invoked from a UI path.
    func restartRuntimeService() async throws

    // MARK: - Milestone 3: embeddings

    func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse
    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse
    func embeddingStatus() async throws -> EmbeddingModelStatus
}

public extension RuntimeClientProtocol {
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
