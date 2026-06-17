import Foundation
import SupraCore

public protocol SupraRuntimeServiceProtocol {
    func loadChatModel(
        _ request: LoadModelRequest,
        reply: @escaping (LoadModelResponse) -> Void
    )

    func generate(
        _ request: GenerateRequest,
        eventSink: GenerationEventSinkProtocol,
        reply: @escaping (GenerateStartResponse) -> Void
    )

    func cancelGeneration(
        _ generationID: GenerationID,
        reply: @escaping (CancelGenerationResponse) -> Void
    )

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int,
        reply: @escaping ([GenerationEvent]) -> Void
    )

    func unloadModel(
        reply: @escaping (UnloadModelResponse) -> Void
    )

    func reloadCurrentModel(
        reply: @escaping (LoadModelResponse) -> Void
    )

    func runtimeStatus(
        reply: @escaping (RuntimeStatus) -> Void
    )

    // MARK: - Milestone 3: embeddings

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest,
        reply: @escaping (LoadEmbeddingModelResponse) -> Void
    )

    func embedTexts(
        _ request: EmbedTextRequest,
        reply: @escaping (EmbedTextResponse) -> Void
    )

    func embeddingStatus(
        reply: @escaping (EmbeddingModelStatus) -> Void
    )
}
