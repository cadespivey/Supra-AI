import Foundation
import SupraCore
import SupraRuntimeInterface

final class SupraRuntimeService: NSObject, SupraRuntimeServiceProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private let eventBuffer = GenerationEventBuffer()
    private let modelController: any ChatModelController = MLXModelController()
    private let embeddingController: any EmbeddingModelController = MLXEmbeddingModelController()
    private lazy var generationCoordinator = RuntimeGenerationCoordinator(
        eventBuffer: eventBuffer,
        modelController: modelController
    )

    private var loadedModelID: ModelID?
    private var currentModelRequest: LoadModelRequest?
    /// The XPC connection that started the in-flight generation, so a dropped
    /// client can have its orphaned generation cancelled (guarded by stateLock).
    private weak var activeGenerationConnection: NSXPCConnection?
    // Milestone 3 embedding state, guarded by stateLock.
    private var loadedEmbeddingModelID: DocumentEmbeddingModelID?
    private var embeddingDimension: Int?

    func loadChatModel(
        _ request: LoadModelRequest,
        reply: @escaping (LoadModelResponse) -> Void
    ) {
        guard !request.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reply(
                LoadModelResponse(
                    status: .failed,
                    modelID: request.modelID,
                    error: RuntimeErrorMapper.invalidRequest("A model path is required.")
                )
            )
            return
        }

        let reply = RuntimeReply(reply)
        Task { [weak self, modelController, reply] in
            do {
                let metrics = try await modelController.loadModel(bookmark: request.modelBookmark, path: request.modelPath)
                self?.setLoadedModel(request)
                reply(LoadModelResponse(status: .loaded, modelID: request.modelID, metrics: metrics))
            } catch {
                reply(
                    LoadModelResponse(
                        status: .failed,
                        modelID: request.modelID,
                        error: RuntimeErrorMapper.modelLoadFailed(error)
                    )
                )
            }
        }
    }

    func generate(
        _ request: GenerateRequest,
        eventSink: GenerationEventSinkProtocol,
        reply: @escaping (GenerateStartResponse) -> Void
    ) {
        stateLock.lock()
        let loadedModelID = loadedModelID
        stateLock.unlock()

        guard loadedModelID == request.modelID else {
            reply(
                GenerateStartResponse(
                    status: .modelNotLoaded,
                    generationID: request.generationID,
                    error: RuntimeErrorMapper.modelNotLoaded()
                )
            )
            return
        }

        generationCoordinator.startGeneration(request, eventSink: eventSink, reply: reply)
    }

    /// Cancels the active generation if it was started by a connection that has
    /// just dropped, freeing the single generation slot for future clients.
    func handleConnectionTermination(_ connection: NSXPCConnection?) {
        guard let activeID = generationCoordinator.activeGenerationID() else { return }
        stateLock.lock()
        let owner = activeGenerationConnection
        stateLock.unlock()
        // Only cancel on a POSITIVE ownership match. A generation that cannot be
        // positively attributed to the dropped connection is left alone — cancelling
        // on a "can't tell" (nil owner/connection) could kill a newer, live
        // generation owned by a different client when a stale handler runs late.
        guard let owner, let connection, owner === connection else { return }
        _ = generationCoordinator.cancelGeneration(activeID)
        stateLock.lock()
        activeGenerationConnection = nil
        stateLock.unlock()
    }

    func cancelGeneration(
        _ generationID: GenerationID,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        reply(generationCoordinator.cancelGeneration(generationID))
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int,
        reply: @escaping ([GenerationEvent]) -> Void
    ) {
        reply(eventBuffer.recentEvents(for: generationID, after: sequenceNumber))
    }

    func unloadModel(reply: @escaping (UnloadModelResponse) -> Void) {
        guard generationCoordinator.activeGenerationID() == nil else {
            reply(UnloadModelResponse(status: .failed, error: RuntimeErrorMapper.unloadWhileGenerating()))
            return
        }

        stateLock.lock()
        guard loadedModelID != nil else {
            stateLock.unlock()
            reply(UnloadModelResponse(status: .noModelLoaded))
            return
        }

        loadedModelID = nil
        currentModelRequest = nil
        stateLock.unlock()

        Task { [modelController] in
            try? await modelController.unload()
        }

        reply(UnloadModelResponse(status: .unloaded))
    }

    func reloadCurrentModel(reply: @escaping (LoadModelResponse) -> Void) {
        stateLock.lock()
        let currentModelRequest = currentModelRequest
        stateLock.unlock()

        guard let currentModelRequest else {
            reply(
                LoadModelResponse(
                    status: .failed,
                    error: RuntimeErrorMapper.modelNotLoaded()
                )
            )
            return
        }

        loadChatModel(currentModelRequest, reply: reply)
    }

    func runtimeStatus(reply: @escaping (RuntimeStatus) -> Void) {
        let activeGenerationID = generationCoordinator.activeGenerationID()
        stateLock.lock()
        let loadedModelID = loadedModelID
        stateLock.unlock()

        let state: RuntimeServiceState
        if activeGenerationID != nil {
            state = .generating
        } else if loadedModelID != nil {
            state = .modelLoaded
        } else {
            state = .modelUnloaded
        }

        stateLock.lock()
        let loadedEmbeddingModelID = loadedEmbeddingModelID
        stateLock.unlock()

        reply(
            RuntimeStatus(
                state: state,
                loadedModelID: loadedModelID,
                activeGenerationID: activeGenerationID,
                message: "Runtime service available.",
                metrics: nil,
                embeddingModelID: loadedEmbeddingModelID
            )
        )
    }

    // MARK: - Milestone 3: embeddings

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest,
        reply: @escaping (LoadEmbeddingModelResponse) -> Void
    ) {
        guard !request.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reply(LoadEmbeddingModelResponse(
                state: .failed,
                embeddingModelID: request.embeddingModelID,
                error: RuntimeErrorMapper.invalidRequest("An embedding model path is required.")
            ))
            return
        }

        let reply = RuntimeReply(reply)
        Task { [weak self, embeddingController, reply] in
            let startedAt = Date()
            do {
                let dimension = try await embeddingController.loadModel(bookmark: request.modelBookmark, path: request.modelPath)
                if let expected = request.expectedDimension, expected != dimension {
                    await embeddingController.unload()
                    self?.clearLoadedEmbeddingModel()
                    reply(LoadEmbeddingModelResponse(
                        state: .failed,
                        embeddingModelID: request.embeddingModelID,
                        error: RuntimeErrorMapper.invalidRequest(
                            "Embedding dimension mismatch: expected \(expected), model produced \(dimension)."
                        )
                    ))
                    return
                }
                self?.setLoadedEmbeddingModel(request.embeddingModelID, dimension: dimension)
                reply(LoadEmbeddingModelResponse(
                    state: .loaded,
                    embeddingModelID: request.embeddingModelID,
                    dimension: dimension,
                    loadTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
            } catch {
                self?.clearLoadedEmbeddingModel()
                reply(LoadEmbeddingModelResponse(
                    state: .failed,
                    embeddingModelID: request.embeddingModelID,
                    error: RuntimeErrorMapper.modelLoadFailed(error)
                ))
            }
        }
    }

    func embedTexts(
        _ request: EmbedTextRequest,
        reply: @escaping (EmbedTextResponse) -> Void
    ) {
        stateLock.lock()
        let loadedEmbeddingModelID = loadedEmbeddingModelID
        let embeddingDimension = embeddingDimension
        stateLock.unlock()

        guard loadedEmbeddingModelID == request.embeddingModelID else {
            reply(EmbedTextResponse(
                state: .unloaded,
                error: RuntimeErrorMapper.invalidRequest("The requested embedding model is not loaded.")
            ))
            return
        }

        let reply = RuntimeReply(reply)
        Task { [embeddingController, reply] in
            do {
                let rawVectors = try await embeddingController.embed(texts: request.texts, normalize: request.normalize)
                // JSONEncoder throws on non-finite Floats; map NaN/±Inf to 0 so a
                // degenerate vector becomes a usable (if zeroed) response instead of
                // an encode failure that the client sees as a generic decode error.
                let vectors = rawVectors.map { $0.map { $0.isFinite ? $0 : 0 } }
                reply(EmbedTextResponse(
                    state: .loaded,
                    vectors: vectors,
                    dimension: vectors.first?.count ?? embeddingDimension,
                    normalized: request.normalize
                ))
            } catch {
                reply(EmbedTextResponse(
                    state: .failed,
                    error: RuntimeErrorMapper.embeddingFailed(error)
                ))
            }
        }
    }

    func embeddingStatus(reply: @escaping (EmbeddingModelStatus) -> Void) {
        stateLock.lock()
        let loadedEmbeddingModelID = loadedEmbeddingModelID
        let embeddingDimension = embeddingDimension
        stateLock.unlock()

        reply(EmbeddingModelStatus(
            state: loadedEmbeddingModelID == nil ? .unloaded : .loaded,
            embeddingModelID: loadedEmbeddingModelID,
            dimension: embeddingDimension,
            message: loadedEmbeddingModelID == nil ? "No embedding model loaded." : "Embedding model loaded."
        ))
    }

    private func setLoadedEmbeddingModel(_ id: DocumentEmbeddingModelID, dimension: Int) {
        stateLock.lock()
        loadedEmbeddingModelID = id
        embeddingDimension = dimension
        stateLock.unlock()
    }

    private func clearLoadedEmbeddingModel() {
        stateLock.lock()
        loadedEmbeddingModelID = nil
        embeddingDimension = nil
        stateLock.unlock()
    }

    private func setLoadedModel(_ request: LoadModelRequest) {
        stateLock.lock()
        loadedModelID = request.modelID
        // The plain bookmark carries a single-use sandbox extension that is dead
        // once the app releases its access, so it must not be replayed on reload.
        // Retain only the path; a sandboxed reload must be re-driven by the app
        // (via ModelLibrary.activateAndLoad) so a fresh bookmark is minted.
        currentModelRequest = LoadModelRequest(
            modelID: request.modelID,
            modelPath: request.modelPath,
            displayName: request.displayName,
            modelBookmark: nil
        )
        stateLock.unlock()
    }
}

private struct RuntimeReply<Response: Sendable>: @unchecked Sendable {
    private let reply: (Response) -> Void

    init(_ reply: @escaping (Response) -> Void) {
        self.reply = reply
    }

    func callAsFunction(_ response: Response) {
        reply(response)
    }
}

extension SupraRuntimeService: SupraRuntimeXPCServiceProtocol {
    func loadChatModel(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let request = try RuntimeXPCCodec.decode(LoadModelRequest.self, from: requestData)
            loadChatModel(request) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(
                Self.encoded(
                    LoadModelResponse(
                        status: .failed,
                        error: RuntimeError(
                            category: "invalidRequest",
                            message: "The model load request could not be decoded.",
                            technicalDetails: error.localizedDescription
                        )
                    )
                )
            )
        }
    }

    func generate(
        _ requestData: Data,
        eventSink: SupraGenerationEventXPCSinkProtocol,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let request = try RuntimeXPCCodec.decode(GenerateRequest.self, from: requestData)
            // Record the owning connection so a dropped client can have its
            // orphaned generation cancelled (see handleConnectionTermination).
            let connection = NSXPCConnection.current()
            stateLock.lock()
            activeGenerationConnection = connection
            stateLock.unlock()
            generate(request, eventSink: XPCGenerationEventSinkAdapter(eventSink: eventSink)) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(
                Self.encoded(
                    GenerateStartResponse(
                        status: .invalidRequest,
                        generationID: GenerationID(),
                        error: RuntimeError(
                            category: "invalidRequest",
                            message: "The generation request could not be decoded.",
                            technicalDetails: error.localizedDescription
                        )
                    )
                )
            )
        }
    }

    func cancelGeneration(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let generationID = try RuntimeXPCCodec.decode(GenerationID.self, from: generationIDData)
            cancelGeneration(generationID) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(
                Self.encoded(
                    CancelGenerationResponse(
                        status: .failed,
                        generationID: GenerationID(),
                        error: RuntimeError(
                            category: "invalidRequest",
                            message: "The cancellation request could not be decoded.",
                            technicalDetails: error.localizedDescription
                        )
                    )
                )
            )
        }
    }

    func recentEvents(
        for generationIDData: Data,
        after sequenceNumber: Int,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let generationID = try RuntimeXPCCodec.decode(GenerationID.self, from: generationIDData)
            recentEvents(for: generationID, after: sequenceNumber) { events in
                reply(Self.encoded(events))
            }
        } catch {
            reply(Self.encoded([GenerationEvent]()))
        }
    }

    func unloadModel(withReply reply: @escaping (Data) -> Void) {
        unloadModel(reply: { response in
            reply(Self.encoded(response))
        })
    }

    func reloadCurrentModel(withReply reply: @escaping (Data) -> Void) {
        reloadCurrentModel(reply: { response in
            reply(Self.encoded(response))
        })
    }

    func runtimeStatus(withReply reply: @escaping (Data) -> Void) {
        runtimeStatus(reply: { status in
            reply(Self.encoded(status))
        })
    }

    func loadEmbeddingModel(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try RuntimeXPCCodec.decode(LoadEmbeddingModelRequest.self, from: requestData)
            loadEmbeddingModel(request) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(
                Self.encoded(
                    LoadEmbeddingModelResponse(
                        state: .failed,
                        error: RuntimeError(
                            category: "invalidRequest",
                            message: "The embedding load request could not be decoded.",
                            technicalDetails: error.localizedDescription
                        )
                    )
                )
            )
        }
    }

    func embedTexts(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try RuntimeXPCCodec.decode(EmbedTextRequest.self, from: requestData)
            embedTexts(request) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(
                Self.encoded(
                    EmbedTextResponse(
                        state: .failed,
                        error: RuntimeError(
                            category: "invalidRequest",
                            message: "The embedding request could not be decoded.",
                            technicalDetails: error.localizedDescription
                        )
                    )
                )
            )
        }
    }

    func embeddingStatus(withReply reply: @escaping (Data) -> Void) {
        embeddingStatus(reply: { status in
            reply(Self.encoded(status))
        })
    }

    // Response DTOs are plain Codable and the only non-finite-Float source
    // (embedding vectors) is sanitized before encode, so this never throws in
    // practice. A generic fallback can't produce a value the typed caller would
    // decode, so on the (unreachable) failure we return empty Data — the same
    // best-effort behavior, without a misleading undecodable envelope.
    private static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? RuntimeXPCCodec.encode(value)) ?? Data()
    }
}

private final class XPCGenerationEventSinkAdapter: GenerationEventSinkProtocol {
    private let eventSink: SupraGenerationEventXPCSinkProtocol

    init(eventSink: SupraGenerationEventXPCSinkProtocol) {
        self.eventSink = eventSink
    }

    func receive(_ event: GenerationEvent, reply: @escaping () -> Void) {
        do {
            eventSink.receive(try RuntimeXPCCodec.encode(event), withReply: reply)
        } catch {
            reply()
        }
    }
}
