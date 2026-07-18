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
        onTerminal: { [weak self] generationID, epoch in
            self?.finishGeneration(generationID, epoch: epoch)
        }
    )

    private struct GenerationReservation {
        let generationID: GenerationID
        let epoch: RuntimeGenerationEpoch
        let isConnectionOwned: Bool
    }

    private var loadedModelID: ModelID?
    private var currentModelRequest: LoadModelRequest?
    /// One state lock owns both model mutations and generation reservations. A
    /// request reserves its transition synchronously, before any actor hop, so
    /// load/unload can never slip underneath an accepted generation (or vice versa).
    private var pendingModelMutationCount = 0
    private var activeGenerationReservation: GenerationReservation?
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
                let result = try await modelController.loadModel(
                    bookmark: request.modelBookmark,
                    path: request.modelPath,
                    managedRootPath: request.managedRootPath,
                    expectedIdentity: request.modelDirectoryIdentity,
                    contentBinding: request.contentBinding
                )
                setLoadedModel(request)
                reply(
                    LoadModelResponse(
                        status: .loaded,
                        modelID: request.modelID,
                        metrics: result.metrics,
                        verifiedModelSHA256: result.verifiedModelSHA256
                    )
                )
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

    func countTokens(
        _ request: CountTokensRequest,
        reply: @escaping (CountTokensResponse) -> Void
    ) {
        stateLock.lock()
        let isLoaded = loadedModelID == request.modelID
        stateLock.unlock()
        guard isLoaded else {
            reply(CountTokensResponse(
                modelID: request.modelID,
                counts: [],
                error: RuntimeErrorMapper.modelNotLoaded()
            ))
            return
        }

        let reply = RuntimeReply(reply)
        modelOperations.enqueue { [modelController, reply] in
            do {
                let counts = try await modelController.countTokens(texts: request.texts)
                reply(CountTokensResponse(modelID: request.modelID, counts: counts))
            } catch {
                reply(CountTokensResponse(
                    modelID: request.modelID,
                    counts: [],
                    error: RuntimeErrorMapper.tokenCountingFailed(error)
                ))
            }
        }
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

        guard pendingModelMutationCount == 0, activeGenerationReservation == nil else {
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
        let epoch = RuntimeGenerationEpoch()
        activeGenerationReservation = GenerationReservation(
            generationID: request.generationID,
            epoch: epoch,
            isConnectionOwned: ownerConnection != nil
        )
        activeGenerationConnection = ownerConnection
#if DEBUG
        if request.prompt == RuntimeLifecycleTestHooks.staleTerminationPrompt {
            RuntimeLifecycleTestHooks.shared.armStaleTermination(
                generationID: request.generationID,
                epoch: epoch
            )
        }
        // Stay inside stateLock until the DEBUG control enters the production
        // termination handler with this exact captured owner. The separate status
        // endpoint coordinates the seam without contending on production stateLock.
        if request.prompt == RuntimeLifecycleTestHooks.reservationRacePrompt,
           let ownerConnection {
            RuntimeLifecycleTestHooks.shared.pauseReservationBeforeAdmission(
                generationID: request.generationID,
                epoch: epoch,
                ownerConnection: ownerConnection
            )
        }
#endif

        let response = generationCoordinator.startGeneration(
            request,
            epoch: epoch,
            eventSink: eventSink
        )
#if DEBUG
        if response.status == .started {
            RuntimeLifecycleTestHooks.shared.noteGenerationAdmitted(
                generationID: request.generationID,
                epoch: epoch
            )
        }
#endif
        if response.status != .started,
           activeGenerationReservation?.generationID == request.generationID,
           activeGenerationReservation?.epoch == epoch {
            activeGenerationReservation = nil
            activeGenerationConnection = nil
        }
        stateLock.unlock()
        reply(response)
    }

    /// Cancels the active generation if it was started by a connection that has
    /// just dropped, freeing the single generation slot for future clients.
    func handleConnectionTermination(_ connection: NSXPCConnection?) {
#if DEBUG
        RuntimeLifecycleTestHooks.shared.noteTerminationHandlerEntered(connection)
#endif
        stateLock.lock()
        let reservation = activeGenerationReservation
        let owner = activeGenerationConnection
        stateLock.unlock()
        // Only cancel on a POSITIVE ownership match. A generation that cannot be
        // positively attributed to the dropped connection is left alone — cancelling
        // on a "can't tell" (nil owner/connection) could kill a newer, live
        // generation owned by a different client when a stale handler runs late.
        guard let reservation,
              reservation.isConnectionOwned,
              let owner,
              let connection,
              owner === connection else { return }
#if DEBUG
        let hooks = RuntimeLifecycleTestHooks.shared
        switch hooks.captureStaleTerminationIfArmed(
            generationID: reservation.generationID,
            epoch: reservation.epoch
        ) {
        case .primary:
            let coordinator = generationCoordinator
            Task {
                await hooks.waitForStaleSuccessorAdmission(
                    generationID: reservation.generationID,
                    oldEpoch: reservation.epoch
                )
                hooks.noteStaleCancellationAttempted(generationID: reservation.generationID)
                coordinator.cancelGeneration(
                    reservation.generationID,
                    epoch: reservation.epoch
                ) { response in
                    hooks.noteStaleCancellationResponse(response)
                }
            }
            return
        case .duplicate:
            // Interruption and invalidation can both fire. Once one handler owns
            // the deterministic stale-epoch probe, duplicates must not cancel the
            // old generation out from under it.
            return
        case .notArmed:
            break
        }

        let isReservationRace = hooks.isReservationRace(
            generationID: reservation.generationID,
            epoch: reservation.epoch
        )
        if isReservationRace {
            hooks.noteReservationCancellationAttempted(generationID: reservation.generationID)
        }
        generationCoordinator.cancelGeneration(
            reservation.generationID,
            epoch: reservation.epoch
        ) { response in
            if isReservationRace {
                hooks.noteReservationCancellationResponse(response)
            }
        }
#else
        generationCoordinator.cancelGeneration(
            reservation.generationID,
            epoch: reservation.epoch
        ) { _ in }
#endif
    }

    func cancelGeneration(
        _ generationID: GenerationID,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        cancelGeneration(generationID, requestingConnection: nil, reply: reply)
    }

    private func cancelGeneration(
        _ generationID: GenerationID,
        requestingConnection: NSXPCConnection?,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        stateLock.lock()
        guard let reservation = activeGenerationReservation,
              reservation.generationID == generationID else {
            stateLock.unlock()
            reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
            return
        }

        if reservation.isConnectionOwned {
            guard let requestingConnection,
                  let owner = activeGenerationConnection,
                  owner === requestingConnection else {
                stateLock.unlock()
                reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
                return
            }
        } else if requestingConnection != nil {
            stateLock.unlock()
            reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
            return
        }
        stateLock.unlock()

        generationCoordinator.cancelGeneration(
            generationID,
            epoch: reservation.epoch,
            reply: reply
        )
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
                // The controller drops the MLX container before deleting its
                // private snapshot. Even if deletion reports an error, the
                // service must not claim that a usable model remains loaded.
                clearLoadedModel()
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
        let activeGenerationID = activeGenerationReservation?.generationID
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
                    expectedIdentity: request.modelDirectoryIdentity,
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
            managedRootPath: request.managedRootPath,
            modelDirectoryIdentity: request.modelDirectoryIdentity,
            contentBinding: request.contentBinding
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
        guard activeGenerationReservation == nil else { return false }
        pendingModelMutationCount += 1
        return true
    }

    private func finishModelMutation() {
        stateLock.lock()
        precondition(pendingModelMutationCount > 0, "Unbalanced runtime model mutation reservation")
        pendingModelMutationCount -= 1
        stateLock.unlock()
    }

    private func finishGeneration(
        _ generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) {
        stateLock.lock()
        if activeGenerationReservation?.generationID == generationID,
           activeGenerationReservation?.epoch == epoch {
            activeGenerationReservation = nil
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
            guard let connection = NSXPCConnection.current() else {
                reply(
                    Self.encoded(
                        GenerateStartResponse(
                            status: .invalidRequest,
                            generationID: request.generationID,
                            error: RuntimeErrorMapper.invalidRequest(
                                "The generation request has no authenticated XPC owner."
                            )
                        )
                    )
                )
                return
            }
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

    func countTokens(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try RuntimeXPCCodec.decode(CountTokensRequest.self, from: requestData)
            countTokens(request) { response in
                reply(Self.encoded(response))
            }
        } catch {
            reply(Self.encoded(CountTokensResponse(
                modelID: ModelID(),
                counts: [],
                error: RuntimeErrorMapper.invalidRequest(
                    "The token-count request could not be decoded."
                )
            )))
        }
    }

    func cancelGeneration(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let generationID = try RuntimeXPCCodec.decode(GenerationID.self, from: generationIDData)
            guard let connection = NSXPCConnection.current() else {
                reply(
                    Self.encoded(
                        CancelGenerationResponse(
                            status: .notFound,
                            generationID: generationID
                        )
                    )
                )
                return
            }
            cancelGeneration(
                generationID,
                requestingConnection: connection
            ) { response in
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

#if DEBUG
    func runtimeLifecycleDebugStatus(withReply reply: @escaping (Data) -> Void) {
        reply(Self.encoded(RuntimeLifecycleTestHooks.shared.snapshot()))
    }

    func triggerReservationTerminationProbe(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let generationID = try? RuntimeXPCCodec.decode(
            GenerationID.self,
            from: generationIDData
        ),
        let caller = NSXPCConnection.current(),
        let capturedOwner = RuntimeLifecycleTestHooks.shared.reservationOwner(
            for: generationID
        ),
        capturedOwner !== caller else {
            reply(Self.encoded(false))
            return
        }

        // Invoke the production termination path with the exact authenticated
        // owner captured by beginGeneration. XPC defers a real invalidation
        // callback until its outstanding generate invocation returns, so this
        // DEBUG control is the only deterministic way to enter the former gap.
        handleConnectionTermination(capturedOwner)
        reply(Self.encoded(true))
    }
#endif

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

#if DEBUG
/// Separate from production stateLock so the hosted app can prove that a
/// connection handler reached a deliberately paused lifecycle boundary. Every
/// phase is acknowledged by generation ID; no race probe depends on a sleep.
final class RuntimeLifecycleTestHooks: @unchecked Sendable {
    static let shared = RuntimeLifecycleTestHooks()
    static let reservationRacePrompt = "SUPRA-XPC-TEST-RESERVATION-RACE"
    static let staleTerminationPrompt = "SUPRA-XPC-TEST-STALE-TERMINATION"

    enum StaleTerminationCaptureDisposition {
        case notArmed
        case primary
        case duplicate
    }

    private typealias Waiter = CheckedContinuation<Void, Never>

    private struct StaleSuccessorWaiter {
        let generationID: GenerationID
        let oldEpoch: RuntimeGenerationEpoch
        let continuation: Waiter
    }

    private let condition = NSCondition()

    private var reservationGenerationID: GenerationID?
    private var reservationEpoch: RuntimeGenerationEpoch?
    private var reservationOwnerIdentity: ObjectIdentifier?
    private var reservationOwnerConnection: NSXPCConnection?
    private var reservationPausedGenerationID: GenerationID?
    private var reservationTerminationHandlerEnteredGenerationID: GenerationID?
    private var reservationAdmissionReleasedGenerationID: GenerationID?
    private var reservationCancellationAttemptedGenerationID: GenerationID?
    private var reservationCancellationStatus: CancelGenerationStatus?

    private var staleGenerationID: GenerationID?
    private var staleEpoch: RuntimeGenerationEpoch?
    private var stalePrimaryHandlerSelected = false
    private var staleTerminationCapturedGenerationID: GenerationID?
    private var staleSuccessorAdmittedGenerationID: GenerationID?
    private var staleSuccessorEpoch: RuntimeGenerationEpoch?
    private var staleCancellationAttemptedGenerationID: GenerationID?
    private var staleCancellationStatus: CancelGenerationStatus?
    private var staleCaptureWaiters: [GenerationID: [Waiter]] = [:]
    private var staleSuccessorWaiters: [StaleSuccessorWaiter] = []

    func pauseReservationBeforeAdmission(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch,
        ownerConnection: NSXPCConnection
    ) {
        condition.lock()
        reservationGenerationID = generationID
        reservationEpoch = epoch
        reservationOwnerIdentity = ObjectIdentifier(ownerConnection)
        reservationOwnerConnection = ownerConnection
        reservationPausedGenerationID = generationID
        reservationTerminationHandlerEnteredGenerationID = nil
        reservationAdmissionReleasedGenerationID = nil
        reservationCancellationAttemptedGenerationID = nil
        reservationCancellationStatus = nil
        condition.broadcast()

        let deadline = Date().addingTimeInterval(5)
        while reservationTerminationHandlerEnteredGenerationID != generationID,
              condition.wait(until: deadline) {}
        if reservationTerminationHandlerEnteredGenerationID == generationID {
            reservationAdmissionReleasedGenerationID = generationID
            condition.broadcast()
        }
        condition.unlock()
    }

    func noteTerminationHandlerEntered(_ connection: NSXPCConnection?) {
        guard let connection else { return }
        condition.lock()
        if reservationOwnerIdentity == ObjectIdentifier(connection),
           let reservationGenerationID {
            reservationTerminationHandlerEnteredGenerationID = reservationGenerationID
            condition.broadcast()
        }
        condition.unlock()
    }

    func isReservationRace(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return reservationGenerationID == generationID && reservationEpoch == epoch
    }

    func reservationOwner(for generationID: GenerationID) -> NSXPCConnection? {
        condition.lock()
        defer { condition.unlock() }
        guard reservationGenerationID == generationID else { return nil }
        return reservationOwnerConnection
    }

    func noteReservationCancellationAttempted(generationID: GenerationID) {
        condition.lock()
        if reservationGenerationID == generationID {
            reservationCancellationAttemptedGenerationID = generationID
        }
        condition.unlock()
    }

    func noteReservationCancellationResponse(_ response: CancelGenerationResponse) {
        condition.lock()
        if reservationGenerationID == response.generationID,
           reservationCancellationStatus == nil {
            reservationCancellationStatus = response.status
            reservationOwnerConnection = nil
        }
        condition.unlock()
    }

    func armStaleTermination(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) {
        condition.lock()
        staleGenerationID = generationID
        staleEpoch = epoch
        stalePrimaryHandlerSelected = false
        staleTerminationCapturedGenerationID = nil
        staleSuccessorAdmittedGenerationID = nil
        staleSuccessorEpoch = nil
        staleCancellationAttemptedGenerationID = nil
        staleCancellationStatus = nil
        condition.unlock()
    }

    func waitForStaleTerminationCapture(generationID: GenerationID) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if staleTerminationCapturedGenerationID == generationID {
                condition.unlock()
                continuation.resume()
            } else {
                staleCaptureWaiters[generationID, default: []].append(continuation)
                condition.unlock()
            }
        }
    }

    func captureStaleTerminationIfArmed(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) -> StaleTerminationCaptureDisposition {
        condition.lock()
        guard staleGenerationID == generationID, staleEpoch == epoch else {
            condition.unlock()
            return .notArmed
        }
        guard !stalePrimaryHandlerSelected else {
            condition.unlock()
            return .duplicate
        }
        stalePrimaryHandlerSelected = true
        staleTerminationCapturedGenerationID = generationID
        let waiters = staleCaptureWaiters.removeValue(forKey: generationID) ?? []
        condition.unlock()
        waiters.forEach { $0.resume() }
        return .primary
    }

    func waitForStaleSuccessorAdmission(
        generationID: GenerationID,
        oldEpoch: RuntimeGenerationEpoch
    ) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if staleSuccessorAdmittedGenerationID == generationID,
               let staleSuccessorEpoch,
               staleSuccessorEpoch != oldEpoch {
                condition.unlock()
                continuation.resume()
            } else {
                staleSuccessorWaiters.append(
                    StaleSuccessorWaiter(
                        generationID: generationID,
                        oldEpoch: oldEpoch,
                        continuation: continuation
                    )
                )
                condition.unlock()
            }
        }
    }

    func noteGenerationAdmitted(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) {
        condition.lock()
        guard staleGenerationID == generationID,
              let staleEpoch,
              staleEpoch != epoch else {
            condition.unlock()
            return
        }
        staleSuccessorAdmittedGenerationID = generationID
        staleSuccessorEpoch = epoch
        let ready = staleSuccessorWaiters.filter {
            $0.generationID == generationID && $0.oldEpoch != epoch
        }
        staleSuccessorWaiters.removeAll {
            $0.generationID == generationID && $0.oldEpoch != epoch
        }
        condition.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    func noteStaleCancellationAttempted(generationID: GenerationID) {
        condition.lock()
        if staleGenerationID == generationID {
            staleCancellationAttemptedGenerationID = generationID
        }
        condition.unlock()
    }

    func noteStaleCancellationResponse(_ response: CancelGenerationResponse) {
        condition.lock()
        if staleGenerationID == response.generationID {
            staleCancellationStatus = response.status
        }
        condition.unlock()
    }

    func snapshot() -> RuntimeLifecycleDebugStatus {
        condition.lock()
        defer { condition.unlock() }
        return RuntimeLifecycleDebugStatus(
            reservationPausedGenerationID: reservationPausedGenerationID,
            reservationTerminationHandlerEnteredGenerationID: reservationTerminationHandlerEnteredGenerationID,
            reservationAdmissionReleasedGenerationID: reservationAdmissionReleasedGenerationID,
            reservationCancellationAttemptedGenerationID: reservationCancellationAttemptedGenerationID,
            reservationCancellationStatus: reservationCancellationStatus,
            staleTerminationCapturedGenerationID: staleTerminationCapturedGenerationID,
            staleSuccessorAdmittedGenerationID: staleSuccessorAdmittedGenerationID,
            staleCancellationAttemptedGenerationID: staleCancellationAttemptedGenerationID,
            staleCancellationStatus: staleCancellationStatus
        )
    }
}
#endif

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
