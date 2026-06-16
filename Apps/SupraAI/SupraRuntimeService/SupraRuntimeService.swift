import Foundation
import SupraCore
import SupraRuntimeInterface

final class SupraRuntimeService: NSObject, SupraRuntimeServiceProtocol {
    private let stateLock = NSLock()
    private let eventBuffer = GenerationEventBuffer()
    private lazy var generationCoordinator = RuntimeGenerationCoordinator(eventBuffer: eventBuffer)

    private var loadedModelID: ModelID?
    private var currentModelRequest: LoadModelRequest?

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

        stateLock.lock()
        loadedModelID = request.modelID
        currentModelRequest = request
        stateLock.unlock()

        reply(
            LoadModelResponse(
                status: .loaded,
                modelID: request.modelID,
                metrics: RuntimeMetrics(loadTimeMs: 0)
            )
        )
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

        reply(
            RuntimeStatus(
                state: state,
                loadedModelID: loadedModelID,
                activeGenerationID: activeGenerationID,
                message: "Runtime service available.",
                metrics: nil
            )
        )
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
