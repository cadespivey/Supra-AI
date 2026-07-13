import Darwin
import Foundation
import SupraCore
import SupraRuntimeInterface

final class SupraRuntimeService: NSObject, SupraRuntimeServiceProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private let eventBuffer = GenerationEventBuffer()
    private let modelController: any ChatModelController = MLXModelController()
    private let embeddingController: any EmbeddingModelController = MLXEmbeddingModelController()
    /// Orders chat-model mutations by XPC arrival order. Without this, an async
    /// load could commit after a later unload and leave reported/runtime state split.
    private let modelOperations = RuntimeSerialOperationQueue()
    private let embeddingModelOperations = RuntimeSerialOperationQueue()
    private lazy var generationCoordinator = RuntimeGenerationCoordinator(
        eventBuffer: eventBuffer,
        modelController: modelController,
        onTerminal: { [weak self] generationID in
            self?.finishGeneration(generationID)
        }
    )

    private var loadedModelID: ModelID?
    private var currentModelRequest: LoadModelRequest?
    /// One state lock owns both model mutations and generation reservations. A
    /// request reserves its transition synchronously, before any actor hop, so
    /// load/unload can never slip underneath an accepted generation (or vice versa).
    private var pendingModelMutationCount = 0
    private var activeGenerationReservationID: GenerationID?
    /// The XPC connection that started the in-flight generation, so a dropped
    /// client can have its orphaned generation cancelled (guarded by stateLock).
    private weak var activeGenerationConnection: NSXPCConnection?
    private var activeGenerationOwnerID: GenerationID?
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

        guard reserveModelMutation() else {
            reply(
                LoadModelResponse(
                    status: .failed,
                    modelID: request.modelID,
                    error: RuntimeErrorMapper.modelMutationWhileGenerating()
                )
            )
            return
        }

        let reply = RuntimeReply(reply)
        modelOperations.enqueue { [self, modelController, reply] in
            defer { finishModelMutation() }
            do {
                let metrics = try await modelController.loadModel(
                    bookmark: request.modelBookmark,
                    path: request.modelPath,
                    managedRootPath: request.managedRootPath
                )
                setLoadedModel(request)
                reply(LoadModelResponse(status: .loaded, modelID: request.modelID, metrics: metrics))
            } catch let error as RuntimeModelDirectoryAccessError {
                reply(
                    LoadModelResponse(
                        status: .failed,
                        modelID: request.modelID,
                        error: RuntimeErrorMapper.modelAccessFailed(error)
                    )
                )
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
        beginGeneration(request, eventSink: eventSink, ownerConnection: nil, reply: reply)
    }

    private func beginGeneration(
        _ request: GenerateRequest,
        eventSink: GenerationEventSinkProtocol,
        ownerConnection: NSXPCConnection?,
        reply: @escaping (GenerateStartResponse) -> Void
    ) {
        stateLock.lock()
        let loadedModelID = loadedModelID
        guard loadedModelID == request.modelID else {
            stateLock.unlock()
            reply(
                GenerateStartResponse(
                    status: .modelNotLoaded,
                    generationID: request.generationID,
                    error: RuntimeErrorMapper.modelNotLoaded()
                )
            )
            return
        }

        guard pendingModelMutationCount == 0, activeGenerationReservationID == nil else {
            stateLock.unlock()
            reply(
                GenerateStartResponse(
                    status: .busy,
                    generationID: request.generationID,
                    error: RuntimeErrorMapper.generationBusy()
                )
            )
            return
        }

        // Reserve and attribute ownership before the coordinator publishes a
        // started reply. Rejected/busy requests never overwrite the real owner.
        activeGenerationReservationID = request.generationID
        activeGenerationConnection = ownerConnection
        activeGenerationOwnerID = ownerConnection == nil ? nil : request.generationID
        stateLock.unlock()

        generationCoordinator.startGeneration(request, eventSink: eventSink) { [weak self] response in
            if response.status != .started {
                self?.finishGeneration(request.generationID)
            }
            reply(response)
        }
    }

    /// Cancels the active generation if it was started by a connection that has
    /// just dropped, freeing the single generation slot for future clients.
    func handleConnectionTermination(_ connection: NSXPCConnection?) {
        stateLock.lock()
        let activeID = activeGenerationReservationID
        let owner = activeGenerationConnection
        let ownerID = activeGenerationOwnerID
        stateLock.unlock()
        // Only cancel on a POSITIVE ownership match. A generation that cannot be
        // positively attributed to the dropped connection is left alone — cancelling
        // on a "can't tell" (nil owner/connection) could kill a newer, live
        // generation owned by a different client when a stale handler runs late.
        guard let activeID,
              ownerID == activeID,
              let owner,
              let connection,
              owner === connection else { return }
        generationCoordinator.cancelGeneration(activeID) { _ in }
    }

    func cancelGeneration(
        _ generationID: GenerationID,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        generationCoordinator.cancelGeneration(generationID, reply: reply)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int,
        reply: @escaping ([GenerationEvent]) -> Void
    ) {
        reply(eventBuffer.recentEvents(for: generationID, after: sequenceNumber))
    }

    func unloadModel(reply: @escaping (UnloadModelResponse) -> Void) {
        guard reserveModelMutation() else {
            reply(UnloadModelResponse(status: .failed, error: RuntimeErrorMapper.unloadWhileGenerating()))
            return
        }

        let reply = RuntimeReply(reply)
        modelOperations.enqueue { [self, modelController, reply] in
            defer { finishModelMutation() }
            guard hasLoadedModel() else {
                reply(UnloadModelResponse(status: .noModelLoaded))
                return
            }

            do {
                try await modelController.unload()
                clearLoadedModel()
                reply(UnloadModelResponse(status: .unloaded))
            } catch {
                reply(
                    UnloadModelResponse(
                        status: .failed,
                        error: RuntimeErrorMapper.modelLoadFailed(error)
                    )
                )
            }
        }
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

        reply(
            LoadModelResponse(
                status: .failed,
                modelID: currentModelRequest.modelID,
                error: RuntimeErrorMapper.invalidRequest(
                    "Reload requires a fresh app-authorized bookmark; load the model through Model Library."
                )
            )
        )
    }

    func runtimeStatus(reply: @escaping (RuntimeStatus) -> Void) {
        stateLock.lock()
        let loadedModelID = loadedModelID
        let activeGenerationID = activeGenerationReservationID
        let hasPendingModelMutation = pendingModelMutationCount > 0
        let loadedEmbeddingModelID = loadedEmbeddingModelID
        stateLock.unlock()

        let state: RuntimeServiceState
        if activeGenerationID != nil {
            state = .generating
        } else if hasPendingModelMutation {
            state = .modelLoading
        } else if loadedModelID != nil {
            state = .modelLoaded
        } else {
            state = .modelUnloaded
        }

        reply(
            RuntimeStatus(
                state: state,
                loadedModelID: loadedModelID,
                activeGenerationID: activeGenerationID,
                message: "Runtime service available.",
                // This is RUSAGE_SELF inside the embedded XPC process, not the
                // UI host. The hosted qualification compares its peak across
                // repeated lifecycle runs to detect service-side growth.
                metrics: RuntimeMetrics(peakMemoryMb: Self.maximumResidentMiB()),
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
        embeddingModelOperations.enqueue { [self, embeddingController, reply] in
            let startedAt = Date()
            do {
                let dimension = try await embeddingController.loadModel(
                    bookmark: request.modelBookmark,
                    path: request.modelPath,
                    managedRootPath: request.managedRootPath,
                    expectedDimension: request.expectedDimension
                )
                setLoadedEmbeddingModel(request.embeddingModelID, dimension: dimension)
                reply(LoadEmbeddingModelResponse(
                    state: .loaded,
                    embeddingModelID: request.embeddingModelID,
                    dimension: dimension,
                    loadTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
            } catch let error as RuntimeModelDirectoryAccessError {
                reply(LoadEmbeddingModelResponse(
                    state: .failed,
                    embeddingModelID: request.embeddingModelID,
                    error: RuntimeErrorMapper.modelAccessFailed(error)
                ))
            } catch let error as EmbeddingModelControllerError {
                let runtimeError: RuntimeError
                if case .dimensionMismatch = error {
                    runtimeError = RuntimeErrorMapper.invalidRequest(error.localizedDescription)
                } else {
                    runtimeError = RuntimeErrorMapper.modelLoadFailed(error)
                }
                reply(LoadEmbeddingModelResponse(
                    state: .failed,
                    embeddingModelID: request.embeddingModelID,
                    error: runtimeError
                ))
            } catch {
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
            modelBookmark: nil,
            managedRootPath: request.managedRootPath
        )
        stateLock.unlock()
    }

    private func clearLoadedModel() {
        stateLock.lock()
        loadedModelID = nil
        currentModelRequest = nil
        stateLock.unlock()
    }

    private func reserveModelMutation() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeGenerationReservationID == nil else { return false }
        pendingModelMutationCount += 1
        return true
    }

    private func finishModelMutation() {
        stateLock.lock()
        precondition(pendingModelMutationCount > 0, "Unbalanced runtime model mutation reservation")
        pendingModelMutationCount -= 1
        stateLock.unlock()
    }

    private func finishGeneration(_ generationID: GenerationID) {
        stateLock.lock()
        if activeGenerationReservationID == generationID {
            activeGenerationReservationID = nil
        }
        if activeGenerationOwnerID == generationID {
            activeGenerationOwnerID = nil
            activeGenerationConnection = nil
        }
        stateLock.unlock()
    }

    private func hasLoadedModel() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadedModelID != nil
    }

    private static func maximumResidentMiB() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss / (1_024 * 1_024))
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

/// A lock-protected async tail queue. Enqueue order is the XPC request order;
/// each mutation waits for its predecessor before touching the model actor.
private final class RuntimeSerialOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let predecessor = tail
        let task = Task {
            await predecessor?.value
            await operation()
        }
        tail = task
        lock.unlock()
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
            let connection = NSXPCConnection.current()
            beginGeneration(
                request,
                eventSink: XPCGenerationEventSinkAdapter(eventSink: eventSink),
                ownerConnection: connection
            ) { response in
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
