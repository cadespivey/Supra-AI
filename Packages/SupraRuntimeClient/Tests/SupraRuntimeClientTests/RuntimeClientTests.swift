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

    func testEmbeddingLoadEmbedAndStatusRoundTrip() async throws {
        let service = FakeRuntimeXPCService()
        let client = RuntimeClient(remoteService: service)
        let embeddingModelID = DocumentEmbeddingModelID()

        let load = try await client.loadEmbeddingModel(
            LoadEmbeddingModelRequest(
                embeddingModelID: embeddingModelID,
                modelPath: "/tmp/embedder",
                displayName: "Local Embedder"
            )
        )
        XCTAssertEqual(load.state, .loaded)
        XCTAssertEqual(load.embeddingModelID, embeddingModelID)
        XCTAssertEqual(load.dimension, 8)

        let embed = try await client.embedTexts(
            EmbedTextRequest(embeddingModelID: embeddingModelID, texts: ["alpha", "beta"])
        )
        XCTAssertEqual(embed.state, .loaded)
        XCTAssertEqual(embed.vectors.count, 2)
        XCTAssertEqual(embed.vectors.first?.count, 8)

        let status = try await client.embeddingStatus()
        XCTAssertEqual(status.state, .loaded)
        XCTAssertEqual(status.embeddingModelID, embeddingModelID)
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
                contextWorkload: .ordinaryConversation,
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
                contextWorkload: .ordinaryConversation,
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

    func testCountTokensRejectsMalformedResponseCardinality() async throws {
        // T-TOK-01 expected RED: the client has no countTokens RPC or reply validation.
        let client = RuntimeClient(remoteService: FakeRuntimeXPCService(malformedTokenCounts: true))
        do {
            _ = try await client.countTokens(
                CountTokensRequest(modelID: ModelID(), texts: ["one", "two"])
            )
            XCTFail("Expected malformed token-count cardinality to be rejected.")
        } catch let error as RuntimeClientError {
            guard case .invalidTokenCountResponse = error else {
                return XCTFail("Expected invalidTokenCountResponse, got \(error).")
            }
        }
    }

    func testResidencySnapshotEvictionAndResetRoundTripThroughInjectedXPCService() async throws {
        let service = FakeRuntimeXPCService()
        let client = RuntimeClient(remoteService: service)

        let before = try await client.runtimeResidencySnapshot()
        XCTAssertEqual(before.epoch, 7)
        XCTAssertEqual(before.residents.map(\.modelID), ["embedding-wire-719", "model-wire-713"])

        let eviction = try await client.evictRuntimeArtifact(
            RuntimeServiceArtifactEvictionRequest(
                modelID: "embedding-wire-719",
                revision: "embed-rev-7",
                kind: .embedding
            )
        )
        XCTAssertEqual(eviction.evictedModelID, "embedding-wire-719")

        let reset = try await client.resetRuntime(
            RuntimeServiceResetRequest(
                requestID: "T_RUNTIME_RESET_01_WIRE_731",
                expectedEpoch: 7
            )
        )
        XCTAssertEqual(reset.requestID, "T_RUNTIME_RESET_01_WIRE_731")
        XCTAssertEqual(reset.previousEpoch, 7)
        XCTAssertEqual(reset.newEpoch, 8)
        XCTAssertEqual(reset.unloadedChatModelIDs, ["model-wire-713"])
        XCTAssertEqual(reset.clearedReplayGenerationCount, 3)
        XCTAssertEqual(reset.clearedBufferedEventCount, 7)
        XCTAssertFalse(String(describing: reset).contains("DEFAULT-000"))
    }
}

private final class FakeRuntimeXPCService: NSObject, SupraRuntimeXPCServiceProtocol {
    private let generateStartStatus: GenerateStartStatus
    private let malformedTokenCounts: Bool
    private var loadedModelID: ModelID?
    private var eventsByGenerationID: [GenerationID: [GenerationEvent]] = [:]
    private var residencyEpoch: UInt64 = 7
    private var residencyArtifacts: [RuntimeServiceResidentArtifact] = [
        RuntimeServiceResidentArtifact(
            modelID: "embedding-wire-719",
            revision: "embed-rev-7",
            kind: .embedding,
            estimatedBytes: 200,
            isActive: false,
            lastUseSequence: 6
        ),
        RuntimeServiceResidentArtifact(
            modelID: "model-wire-713",
            revision: "rev-7",
            kind: .chat,
            estimatedBytes: 250,
            isActive: false,
            lastUseSequence: 7
        ),
    ]

    init(
        generateStartStatus: GenerateStartStatus = .started,
        malformedTokenCounts: Bool = false
    ) {
        self.generateStartStatus = generateStartStatus
        self.malformedTokenCounts = malformedTokenCounts
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

    func countTokens(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        guard let request = try? RuntimeXPCCodec.decode(CountTokensRequest.self, from: requestData) else {
            return reply(encoded(CountTokensResponse(modelID: ModelID(), counts: [])))
        }
        let counts = malformedTokenCounts
            ? Array(repeating: 1, count: max(0, request.texts.count - 1))
            : request.texts.map { $0.utf8.count }
        reply(encoded(CountTokensResponse(modelID: request.modelID, counts: counts)))
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
                    metrics: nil,
                    embeddingModelID: loadedEmbeddingModelID
                )
            )
        )
    }

    func runtimeResidencySnapshot(withReply reply: @escaping (Data) -> Void) {
        reply(encoded(RuntimeServiceResidencySnapshot(
            epoch: residencyEpoch,
            unifiedMemoryCeilingBytes: 1_200,
            fixedResidentBytes: 400,
            replayGenerationCount: 3,
            bufferedEventCount: 7,
            residents: residencyArtifacts,
            activeTaskCount: residencyArtifacts.filter(\.isActive).count
        )))
    }

    func evictRuntimeArtifact(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let request = try? RuntimeXPCCodec.decode(
            RuntimeServiceArtifactEvictionRequest.self,
            from: requestData
        ), let index = residencyArtifacts.firstIndex(where: {
            $0.modelID == request.modelID
                && $0.revision == request.revision
                && $0.kind == request.kind
                && !$0.isActive
        }) else {
            reply(encoded(RuntimeServiceArtifactEvictionResponse(
                evictedModelID: nil,
                error: RuntimeError(category: "residency", message: "Artifact is not evictable.")
            )))
            return
        }
        let artifact = residencyArtifacts.remove(at: index)
        reply(encoded(RuntimeServiceArtifactEvictionResponse(
            evictedModelID: artifact.modelID,
            error: nil
        )))
    }

    func resetRuntime(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let request = try? RuntimeXPCCodec.decode(
            RuntimeServiceResetRequest.self,
            from: requestData
        ), request.expectedEpoch == residencyEpoch else {
            reply(encoded(RuntimeServiceResetResponse(
                receipt: nil,
                error: RuntimeError(category: "residency", message: "Epoch mismatch.")
            )))
            return
        }
        let chatIDs = residencyArtifacts.filter { $0.kind == .chat }.map(\.modelID).sorted()
        let embeddingIDs = residencyArtifacts.filter { $0.kind == .embedding }.map(\.modelID).sorted()
        residencyArtifacts = []
        residencyEpoch += 1
        reply(encoded(RuntimeServiceResetResponse(
            receipt: RuntimeServiceResetReceipt(
                requestID: request.requestID,
                previousEpoch: request.expectedEpoch,
                newEpoch: residencyEpoch,
                unloadedChatModelIDs: chatIDs,
                unloadedEmbeddingModelIDs: embeddingIDs,
                clearedReplayGenerationCount: 3,
                clearedBufferedEventCount: 7
            ),
            error: nil
        )))
    }

#if DEBUG
    func runtimeLifecycleDebugStatus(withReply reply: @escaping (Data) -> Void) {
        reply(encoded(RuntimeLifecycleDebugStatus()))
    }

    func triggerReservationTerminationProbe(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        reply(encoded(true))
    }
#endif

    private var loadedEmbeddingModelID: DocumentEmbeddingModelID?
    private let embeddingDimension = 8

    func loadEmbeddingModel(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        guard let request = try? RuntimeXPCCodec.decode(LoadEmbeddingModelRequest.self, from: requestData) else {
            reply(encoded(LoadEmbeddingModelResponse(state: .failed)))
            return
        }
        loadedEmbeddingModelID = request.embeddingModelID
        reply(encoded(LoadEmbeddingModelResponse(
            state: .loaded,
            embeddingModelID: request.embeddingModelID,
            dimension: embeddingDimension,
            loadTimeMs: 1
        )))
    }

    func embedTexts(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        guard let request = try? RuntimeXPCCodec.decode(EmbedTextRequest.self, from: requestData) else {
            reply(encoded(EmbedTextResponse(state: .failed)))
            return
        }
        // Deterministic unit vectors so cosine math is exercised without a model.
        let vectors = request.texts.map { text -> [Float] in
            var vector = [Float](repeating: 0, count: embeddingDimension)
            vector[abs(text.hashValue) % embeddingDimension] = 1
            return vector
        }
        reply(encoded(EmbedTextResponse(
            state: .loaded,
            vectors: vectors,
            dimension: embeddingDimension,
            normalized: request.normalize
        )))
    }

    func embeddingStatus(withReply reply: @escaping (Data) -> Void) {
        reply(encoded(EmbeddingModelStatus(
            state: loadedEmbeddingModelID == nil ? .unloaded : .loaded,
            embeddingModelID: loadedEmbeddingModelID,
            dimension: loadedEmbeddingModelID == nil ? nil : embeddingDimension
        )))
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? RuntimeXPCCodec.encode(value)) ?? Data()
    }
}
