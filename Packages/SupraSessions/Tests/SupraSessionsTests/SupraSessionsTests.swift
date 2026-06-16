import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class SupraSessionsTests: XCTestCase {

    // MARK: - GlobalChatController

    func testSendPersistsConversationAndStreamsTokens() async throws {
        let store = try makeStore()
        let modelID = ModelID()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Hel"),
                .event(request, 3, .token, token: "lo"),
                .event(request, 4, .metrics, metrics: RuntimeMetrics(generatedTokenCount: 2)),
                .event(request, 5, .generationCompleted, metrics: RuntimeMetrics(generatedTokenCount: 2))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: modelID, systemPrompt: nil, options: GenerationOptions())

        XCTAssertFalse(controller.isGenerating)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages[0].role, .user)
        XCTAssertEqual(controller.messages[0].content, "Hi")
        XCTAssertEqual(controller.messages[1].role, .assistant)
        XCTAssertEqual(controller.messages[1].content, "Hello")
        XCTAssertEqual(controller.messages[1].status, .completed)

        // Persisted across a fresh controller instance.
        let reopened = GlobalChatController(store: store, runtimeClient: stub)
        reopened.loadChats()
        XCTAssertEqual(reopened.messages.map(\.content), ["Hi", "Hello"])
        XCTAssertEqual(reopened.messages.last?.status, .completed)
    }

    func testCancelledEventPreservesPartialOutput() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Partial"),
                .event(request, 3, .generationCancelled, metrics: RuntimeMetrics(cancellationLatencyMs: 0))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Write a long thing", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.content, "Partial")
        XCTAssertEqual(controller.messages.last?.status, .cancelled)
    }

    func testFailedEventMarksAssistantFailed() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "X"),
                .event(request, 3, .generationFailed, error: RuntimeError(category: "generationFailed", message: "boom"))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertEqual(controller.errorMessage, "boom")
    }

    func testStreamWithoutTerminalEventMarksInterrupted() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Partial")
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.status, .interrupted)
        XCTAssertEqual(controller.messages.last?.content, "Partial")
    }

    func testRejectedStreamMarksAssistantFailed() async throws {
        let store = try makeStore()
        let rejection = GenerateStartResponse(
            status: .modelNotLoaded,
            generationID: GenerationID(),
            error: RuntimeError(category: "modelNotLoaded", message: "No model is loaded.")
        )
        let stub = StubRuntimeClient { _ in .reject(RuntimeClientError.generationRejected(rejection)) }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testSendCreatesChatWhenNoneSelected() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .generationCompleted)])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        XCTAssertTrue(controller.chats.isEmpty)

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.chats.count, 1)
        XCTAssertNotNil(controller.selectedChatID)
    }

    // MARK: - MattersController

    func testMattersControllerCreatesMatterWithScopedChats() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = MattersController(store: store, runtimeClient: stub)
        controller.loadMatters()
        XCTAssertTrue(controller.matters.isEmpty)

        let matter = try controller.createMatter(name: "Acme v. Roe")
        XCTAssertEqual(controller.matters.count, 1)
        XCTAssertEqual(controller.selectedMatterID, matter.id)

        let chat = try XCTUnwrap(controller.chatController)
        _ = try chat.createChat(title: "Issue 1")

        // The chat is scoped to the matter, not the global list.
        XCTAssertEqual(chat.chats.count, 1)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).count, 1)
    }

    // MARK: - ModelLibrary

    func testAddAndActivateLoadsModel() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient(loadResult: LoadModelResponse(status: .loaded, modelID: ModelID(), metrics: RuntimeMetrics(loadTimeMs: 5)))
        let library = ModelLibrary(store: store, runtimeClient: stub)

        let summary = try library.addModel(displayName: "Local 32B", path: "/tmp/model", bookmarkData: nil)
        XCTAssertEqual(library.models.count, 1)

        await library.activateAndLoad(modelID: summary.id)

        XCTAssertEqual(library.loadState, .loaded(modelID: summary.id))
        XCTAssertEqual(library.activeModel?.id, summary.id)
        XCTAssertNotNil(library.loadedModelID)
    }

    func testActivateSurfacesLoadFailure() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient(loadResult: LoadModelResponse(
            status: .failed,
            error: RuntimeError(category: "modelLoadFailed", message: "missing weights")
        ))
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let summary = try library.addModel(displayName: "Broken", path: "/tmp/broken", bookmarkData: nil)

        await library.activateAndLoad(modelID: summary.id)

        XCTAssertEqual(library.loadState, .failed(message: "missing weights"))
    }

    func testActivateFailsWhenBookmarkCannotBeAccessed() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient() // would return .loaded if it were ever reached
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let summary = try library.addModel(
            displayName: "Bookmarked",
            path: "/tmp/model",
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        await library.activateAndLoad(modelID: summary.id)

        guard case let .failed(message) = library.loadState else {
            return XCTFail("Expected a failed load state when the bookmark cannot be accessed.")
        }
        XCTAssertTrue(message.contains("Could not access"))
    }

    // MARK: - Helpers

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

// MARK: - Stub runtime client

enum GenerationOutcome {
    case events([GenerationEvent])
    case reject(Error)
}

final class StubRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let loadResult: LoadModelResponse
    private let outcome: @Sendable (GenerateRequest) -> GenerationOutcome
    private let lock = NSLock()
    private var _cancelledGenerationIDs: [GenerationID] = []

    var cancelledGenerationIDs: [GenerationID] {
        lock.withLock { _cancelledGenerationIDs }
    }

    init(
        loadResult: LoadModelResponse = LoadModelResponse(status: .loaded, modelID: ModelID()),
        outcome: @escaping @Sendable (GenerateRequest) -> GenerationOutcome = { _ in .events([]) }
    ) {
        self.loadResult = loadResult
        self.outcome = outcome
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        loadResult
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let outcome = outcome(request)
        return AsyncThrowingStream { continuation in
            switch outcome {
            case let .events(events):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            case let .reject(error):
                continuation.finish(throwing: error)
            }
        }
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        lock.withLock { _cancelledGenerationIDs.append(generationID) }
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        loadResult
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(state: .modelLoaded, loadedModelID: loadResult.modelID, activeGenerationID: nil, message: nil, metrics: nil)
    }

    func restartRuntimeService() async throws {}
}

extension GenerationEvent {
    static func event(
        _ request: GenerateRequest,
        _ sequenceNumber: Int,
        _ type: GenerationEventType,
        token: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) -> GenerationEvent {
        GenerationEvent(
            generationID: request.generationID,
            sequenceNumber: sequenceNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceNumber)),
            type: type,
            tokenText: token,
            message: nil,
            metrics: metrics,
            error: error
        )
    }
}
