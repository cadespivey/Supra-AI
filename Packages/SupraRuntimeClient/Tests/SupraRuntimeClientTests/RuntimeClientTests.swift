import Foundation
import SupraCore
@testable import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest

final class RuntimeClientTests: XCTestCase {
    func testLoadModelAndStatusRoundTripThroughInjectedXPCService() async throws {
        let service = FakeRuntimeXPCService()
        let client = RuntimeClient(remoteService: service)
        let modelID = ModelID()

        let response = try await client.loadModel(
            LoadModelRequest(
                modelID: modelID,
                modelPath: "/tmp/model",
                displayName: "Local Model"
            )
        )
        let status = try await client.runtimeStatus()

        XCTAssertEqual(response.status, .loaded)
        XCTAssertEqual(response.modelID, modelID)
        XCTAssertEqual(status.state, .modelLoaded)
        XCTAssertEqual(status.loadedModelID, modelID)
    }

    func testGenerationStreamAndRecentEventsRoundTripThroughInjectedXPCService() async throws {
        let service = FakeRuntimeXPCService()
        let client = RuntimeClient(remoteService: service)
        let modelID = ModelID()
        let generationID = GenerationID()

        _ = try await client.loadModel(
            LoadModelRequest(modelID: modelID, modelPath: "/tmp/model", displayName: "Local Model")
        )

        var receivedEvents: [GenerationEvent] = []
        let stream = try client.generate(
            GenerateRequest(
                generationID: generationID,
                modelID: modelID,
                prompt: "Hello",
                systemPrompt: nil,
                options: GenerationOptions(maxOutputTokens: 8)
            )
        )

        for try await event in stream {
            receivedEvents.append(event)
        }

        XCTAssertEqual(receivedEvents.map(\.type), [.generationStarted, .token, .generationCompleted])
        XCTAssertEqual(receivedEvents.map(\.sequenceNumber), [1, 2, 3])
        XCTAssertEqual(receivedEvents[1].tokenText, "Hello")

        let recentEvents = try await client.recentEvents(for: generationID, after: 1)
        XCTAssertEqual(recentEvents.map(\.type), [.token, .generationCompleted])
    }

    func testBusyGenerationRejectsStream() async throws {
        let service = FakeRuntimeXPCService(generateStartStatus: .busy)
        let client = RuntimeClient(remoteService: service)
        let stream = try client.generate(
            GenerateRequest(
                generationID: GenerationID(),
                modelID: ModelID(),
                prompt: "Hello",
                systemPrompt: nil,
                options: GenerationOptions()
            )
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected busy generation to throw.")
        } catch let error as RuntimeClientError {
            guard case .generationRejected = error else {
                XCTFail("Expected generationRejected error.")
                return
            }
        }
    }
}

private final class FakeRuntimeXPCService: NSObject, SupraRuntimeXPCServiceProtocol {
    private let generateStartStatus: GenerateStartStatus
    private var loadedModelID: ModelID?
    private var eventsByGenerationID: [GenerationID: [GenerationEvent]] = [:]

    init(generateStartStatus: GenerateStartStatus = .started) {
        self.generateStartStatus = generateStartStatus
    }

    func loadChatModel(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try RuntimeXPCCodec.decode(LoadModelRequest.self, from: requestData)
            loadedModelID = request.modelID
            reply(
                encoded(
                    LoadModelResponse(
                        status: .loaded,
                        modelID: request.modelID,
                        metrics: RuntimeMetrics(loadTimeMs: 1)
                    )
                )
            )
        } catch {
            reply(encoded(LoadModelResponse(status: .failed)))
        }
    }

    func generate(
        _ requestData: Data,
        eventSink: SupraGenerationEventXPCSinkProtocol,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let request = try RuntimeXPCCodec.decode(GenerateRequest.self, from: requestData)
            reply(encoded(GenerateStartResponse(status: generateStartStatus, generationID: request.generationID)))

            guard generateStartStatus == .started else {
                return
            }

            let events = [
                GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 1,
                    timestamp: Date(),
                    type: .generationStarted
                ),
                GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 2,
                    timestamp: Date(),
                    type: .token,
                    tokenText: "Hello"
                ),
                GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 3,
                    timestamp: Date(),
                    type: .generationCompleted,
                    metrics: RuntimeMetrics(generatedTokenCount: 1)
                )
            ]
            eventsByGenerationID[request.generationID] = events

            for event in events {
                eventSink.receive(encoded(event)) {}
            }
        } catch {
            reply(
                encoded(
                    GenerateStartResponse(
                        status: .invalidRequest,
                        generationID: GenerationID(),
                        error: RuntimeError(category: "invalidRequest", message: error.localizedDescription)
                    )
                )
            )
        }
    }

    func cancelGeneration(_ generationIDData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let generationID = try RuntimeXPCCodec.decode(GenerationID.self, from: generationIDData)
            reply(encoded(CancelGenerationResponse(status: .cancelled, generationID: generationID)))
        } catch {
            reply(encoded(CancelGenerationResponse(status: .failed, generationID: GenerationID())))
        }
    }

    func recentEvents(
        for generationIDData: Data,
        after sequenceNumber: Int,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let generationID = try RuntimeXPCCodec.decode(GenerationID.self, from: generationIDData)
            let events = eventsByGenerationID[generationID, default: []]
                .filter { $0.sequenceNumber > sequenceNumber }
            reply(encoded(events))
        } catch {
            reply(encoded([GenerationEvent]()))
        }
    }

    func unloadModel(withReply reply: @escaping (Data) -> Void) {
        loadedModelID = nil
        reply(encoded(UnloadModelResponse(status: .unloaded)))
    }

    func reloadCurrentModel(withReply reply: @escaping (Data) -> Void) {
        reply(encoded(LoadModelResponse(status: .loaded, modelID: loadedModelID)))
    }

    func runtimeStatus(withReply reply: @escaping (Data) -> Void) {
        reply(
            encoded(
                RuntimeStatus(
                    state: loadedModelID == nil ? .modelUnloaded : .modelLoaded,
                    loadedModelID: loadedModelID,
                    activeGenerationID: nil,
                    message: nil,
                    metrics: nil
                )
            )
        )
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? RuntimeXPCCodec.encode(value)) ?? Data()
    }
}

