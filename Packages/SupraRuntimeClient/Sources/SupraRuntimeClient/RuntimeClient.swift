import Foundation
import SupraCore
import SupraRuntimeInterface

public enum RuntimeClientError: Error, LocalizedError, Sendable {
    case remoteProxyUnavailable
    case remoteInvocationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case generationRejected(GenerateStartResponse)
    case invalidTokenCountResponse

    public var errorDescription: String? {
        switch self {
        case .remoteProxyUnavailable:
            "The Supra runtime service proxy is unavailable."
        case let .remoteInvocationFailed(message):
            "The Supra runtime service request failed: \(message)"
        case let .encodingFailed(message):
            "The runtime request could not be encoded: \(message)"
        case let .decodingFailed(message):
            "The runtime response could not be decoded: \(message)"
        case let .generationRejected(response):
            response.error?.message ?? "The runtime rejected the generation request with status \(response.status.rawValue)."
        case .invalidTokenCountResponse:
            "The runtime returned token counts that do not match the request."
        }
    }
}

public final class RuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let serviceName: String
    private let injectedRemoteService: SupraRuntimeXPCServiceProtocol?
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    // In-flight generate() streams, keyed so the connection's interruption/
    // invalidation handlers can fail them if the service dies mid-generation.
    private let streamsLock = NSLock()
    private var activeStreamFailures: [UUID: @Sendable (Error) -> Void] = [:]

    public convenience init() {
        self.init(serviceName: RuntimeXPCServiceNames.defaultServiceName)
    }

    public init(serviceName: String) {
        self.serviceName = serviceName
        self.injectedRemoteService = nil
    }

    public init(remoteService: SupraRuntimeXPCServiceProtocol) {
        self.serviceName = RuntimeXPCServiceNames.defaultServiceName
        self.injectedRemoteService = remoteService
    }

    deinit {
        connection?.invalidate()
    }

    public func connect() async throws {
        _ = try remoteService()
    }

    public func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        let requestData = try encode(request)
        return try await sendRequest(LoadModelResponse.self) { service, reply in
            service.loadChatModel(requestData, withReply: reply)
        }
    }

    public func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let requestData = try encode(request)

        return AsyncThrowingStream { continuation in
            let streamState = RuntimeGenerationStreamState()
            let streamID = UUID()

            // Finishes the stream with an error. Safe to call more than once
            // (the continuation ignores subsequent finishes) and from any
            // thread — the connection handlers, the proxy error handler, and
            // the event sink may all race here.
            let fail: @Sendable (Error) -> Void = { error in
                streamState.invalidate()
                continuation.finish(throwing: error)
            }

            streamState.eventSink = RuntimeClientEventSink { result in
                switch result {
                case let .success(event):
                    continuation.yield(event)

                    if event.type == .generationCompleted || event.type == .generationCancelled || event.type == .generationFailed {
                        continuation.finish()
                    }

                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self, streamState] termination in
                self?.unregisterStreamFailure(streamID)
                streamState.invalidate()

                if case .cancelled = termination {
                    Task {
                        _ = try? await self?.cancelGeneration(request.generationID)
                    }
                }
            }

            guard let eventSink = streamState.eventSink else {
                continuation.finish(throwing: RuntimeClientError.remoteProxyUnavailable)
                return
            }

            // Without this, a service that dies mid-generation emits no further
            // events and the consumer's `for try await` hangs forever. The
            // connection's interruption/invalidation handler calls this to
            // surface the drop as a thrown error instead.
            registerStreamFailure(streamID, fail)

            let service: SupraRuntimeXPCServiceProtocol
            do {
                service = try remoteService { error in
                    fail(RuntimeClientError.remoteInvocationFailed(error.localizedDescription))
                }
            } catch {
                unregisterStreamFailure(streamID)
                continuation.finish(throwing: error)
                return
            }

            service.generate(requestData, eventSink: eventSink) { responseData in
                do {
                    let response = try RuntimeXPCCodec.decode(GenerateStartResponse.self, from: responseData)
                    if response.status != .started {
                        continuation.finish(throwing: RuntimeClientError.generationRejected(response))
                    }
                } catch {
                    continuation.finish(throwing: RuntimeClientError.decodingFailed(error.localizedDescription))
                }
            }
        }
    }

    public func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        let requestData = try encode(request)
        let response = try await sendRequest(CountTokensResponse.self) { service, reply in
            service.countTokens(requestData, withReply: reply)
        }
        if let error = response.error {
            throw RuntimeClientError.remoteInvocationFailed(error.message)
        }
        guard response.modelID == request.modelID,
              response.counts.count == request.texts.count,
              response.counts.allSatisfy({ $0 >= 0 }) else {
            throw RuntimeClientError.invalidTokenCountResponse
        }
        return response
    }

    public func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        let generationIDData = try encode(generationID)
        return try await sendRequest(CancelGenerationResponse.self) { service, reply in
            service.cancelGeneration(generationIDData, withReply: reply)
        }
    }

    public func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] {
        let generationIDData = try encode(generationID)
        return try await sendRequest([GenerationEvent].self) { service, reply in
            service.recentEvents(for: generationIDData, after: sequenceNumber, withReply: reply)
        }
    }

    public func unloadModel() async throws -> UnloadModelResponse {
        try await sendRequest(UnloadModelResponse.self) { service, reply in
            service.unloadModel(withReply: reply)
        }
    }

    public func reloadCurrentModel() async throws -> LoadModelResponse {
        try await sendRequest(LoadModelResponse.self) { service, reply in
            service.reloadCurrentModel(withReply: reply)
        }
    }

    public func runtimeStatus() async throws -> RuntimeStatus {
        try await sendRequest(RuntimeStatus.self) { service, reply in
            service.runtimeStatus(withReply: reply)
        }
    }

#if DEBUG
    public func runtimeLifecycleDebugStatus() async throws -> RuntimeLifecycleDebugStatus {
        try await sendRequest(RuntimeLifecycleDebugStatus.self) { service, reply in
            service.runtimeLifecycleDebugStatus(withReply: reply)
        }
    }

    public func triggerReservationTerminationProbe(_ generationID: GenerationID) async throws -> Bool {
        let generationIDData = try encode(generationID)
        return try await sendRequest(Bool.self) { service, reply in
            service.triggerReservationTerminationProbe(generationIDData, withReply: reply)
        }
    }
#endif

    public func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse {
        let requestData = try encode(request)
        return try await sendRequest(LoadEmbeddingModelResponse.self) { service, reply in
            service.loadEmbeddingModel(requestData, withReply: reply)
        }
    }

    public func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        let requestData = try encode(request)
        return try await sendRequest(EmbedTextResponse.self) { service, reply in
            service.embedTexts(requestData, withReply: reply)
        }
    }

    public func embeddingStatus() async throws -> EmbeddingModelStatus {
        try await sendRequest(EmbeddingModelStatus.self) { service, reply in
            service.embeddingStatus(withReply: reply)
        }
    }

    public func restartRuntimeService() async throws {
        invalidateConnection()?.invalidate()
        try await connect()
    }

    private func sendRequest<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        send: @escaping (SupraRuntimeXPCServiceProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let reply = RuntimeClientReply<Response>(continuation: continuation)

            do {
                let service = try remoteService { error in
                    reply.complete(.failure(RuntimeClientError.remoteInvocationFailed(error.localizedDescription)))
                }

                send(service) { responseData in
                    do {
                        reply.complete(.success(try RuntimeXPCCodec.decode(responseType, from: responseData)))
                    } catch {
                        reply.complete(.failure(RuntimeClientError.decodingFailed(error.localizedDescription)))
                    }
                }
            } catch {
                reply.complete(.failure(error))
            }
        }
    }

    private func remoteService(errorHandler: ((Error) -> Void)? = nil) throws -> SupraRuntimeXPCServiceProtocol {
        if let injectedRemoteService {
            return injectedRemoteService
        }

        let connection = runtimeConnection()
        let proxy = if let errorHandler {
            connection.remoteObjectProxyWithErrorHandler(errorHandler)
        } else {
            connection.remoteObjectProxy
        }

        guard let service = proxy as? SupraRuntimeXPCServiceProtocol else {
            throw RuntimeClientError.remoteProxyUnavailable
        }

        return service
    }

    private func runtimeConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let connection {
            return connection
        }

        let newConnection = NSXPCConnection(serviceName: serviceName)
        newConnection.remoteObjectInterface = RuntimeXPCInterfaces.serviceInterface()
        // Public Foundation API validates the embedded service before the first
        // message. The service applies the reciprocal app-client requirement.
        newConnection.setCodeSigningRequirement(RuntimeXPCSigningRequirements.runtimeService)
        // The service crashing/restarting interrupts the connection; the client
        // tearing it down or the service failing to launch invalidates it.
        // Either way, in-flight generations are lost and must be failed so the
        // consumer doesn't hang. Captured weakly to avoid a connection/handler
        // retain cycle.
        newConnection.interruptionHandler = { [weak self] in
            self?.failActiveStreams(
                RuntimeClientError.remoteInvocationFailed("The runtime service connection was interrupted.")
            )
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self else { return }
            self.connectionLock.lock()
            if self.connection === newConnection {
                self.connection = nil
            }
            self.connectionLock.unlock()
            self.failActiveStreams(RuntimeClientError.remoteProxyUnavailable)
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func registerStreamFailure(_ id: UUID, _ handler: @escaping @Sendable (Error) -> Void) {
        streamsLock.lock()
        activeStreamFailures[id] = handler
        streamsLock.unlock()
    }

    private func unregisterStreamFailure(_ id: UUID) {
        streamsLock.lock()
        activeStreamFailures[id] = nil
        streamsLock.unlock()
    }

    private func failActiveStreams(_ error: Error) {
        streamsLock.lock()
        let handlers = activeStreamFailures
        activeStreamFailures.removeAll()
        streamsLock.unlock()
        for handler in handlers.values {
            handler(error)
        }
    }

    private func invalidateConnection() -> NSXPCConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let existingConnection = connection
        connection = nil
        return existingConnection
    }

    /// Explicitly closes this client's hosted XPC session. Production callers use
    /// restartRuntimeService(); the lifecycle integration gate uses this to prove
    /// that a dropped client cancels an in-flight generation exactly once.
    public func disconnect() {
        invalidateConnection()?.invalidate()
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try RuntimeXPCCodec.encode(value)
        } catch {
            throw RuntimeClientError.encodingFailed(error.localizedDescription)
        }
    }
}

private final class RuntimeClientReply<Response: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?

    init(continuation: CheckedContinuation<Response, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Response, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }

        switch result {
        case let .success(response):
            continuation.resume(returning: response)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private final class RuntimeGenerationStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    var eventSink: RuntimeClientEventSink?

    func invalidate() {
        lock.lock()
        isActive = false
        eventSink = nil
        lock.unlock()
    }
}

private final class RuntimeClientEventSink: NSObject, SupraGenerationEventXPCSinkProtocol {
    private let receiveEvent: (Result<GenerationEvent, Error>) -> Void

    init(receiveEvent: @escaping (Result<GenerationEvent, Error>) -> Void) {
        self.receiveEvent = receiveEvent
    }

    func receive(_ eventData: Data, withReply reply: @escaping () -> Void) {
        do {
            let event = try RuntimeXPCCodec.decode(GenerationEvent.self, from: eventData)
            receiveEvent(.success(event))
        } catch {
            receiveEvent(.failure(RuntimeClientError.decodingFailed(error.localizedDescription)))
        }

        reply()
    }
}
