import Foundation
import SupraCore
import SupraRuntimeInterface

public enum RuntimeClientError: Error, LocalizedError, Sendable {
    case remoteProxyUnavailable
    case remoteInvocationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case generationRejected(GenerateStartResponse)

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
        }
    }
}

public final class RuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let serviceName: String
    private let injectedRemoteService: SupraRuntimeXPCServiceProtocol?
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?

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
        let service = try remoteService()

        return AsyncThrowingStream { continuation in
            let streamState = RuntimeGenerationStreamState()
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
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func invalidateConnection() -> NSXPCConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let existingConnection = connection
        connection = nil
        return existingConnection
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
