import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// The send pipeline must ECHO the user's turn and claim `isGenerating` BEFORE any
/// slow pre-generation work. The old flow awaited the chat-model load in the
/// composer view before `controller.send` ever ran, and `performSend` ran grounded
/// retrieval before appending the user message — so a submitted prompt could sit
/// invisible in the composer for seconds on a cold model load, reading as a bug
/// and inviting a re-send that stacks overlapping generations (user report).
///
/// The corrective contract: `performSend` appends and reloads the user turn FIRST,
/// then resolves the model through an injected `modelResolver`; a failed
/// resolution resolves the echoed turn with a FAILED assistant message carrying
/// the issue text instead of leaving a dangling echo (or, worse, text stranded in
/// the composer).
///
/// Expected RED for this file: `performSend` has no `modelResolver` parameter and
/// `ModelResolution` does not exist, so the file does not compile.
final class ChatSendEchoTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-echo-\(UUID().uuidString).sqlite")
        return try SupraStore(url: url)
    }

    /// T-ECHO-01: the user's turn is in `messages` and `isGenerating` is claimed
    /// before the model resolver runs; the send then completes normally with the
    /// resolved model.
    @MainActor
    func testUserTurnIsVisibleBeforeModelResolution() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answered."),
                .event(request, 2, .generationCompleted),
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        var echoVisibleBeforeResolve = false
        await controller.performSend(
            prompt: "Echo me instantly",
            modelID: nil,
            systemPrompt: nil,
            options: GenerationOptions(),
            modelResolver: { @MainActor in
                let last = controller.messages.last
                echoVisibleBeforeResolve = last?.role == .user
                    && last?.content == "Echo me instantly"
                    && controller.isGenerating
                return .model(ModelID())
            }
        )

        XCTAssertTrue(
            echoVisibleBeforeResolve,
            "the composer echo and the generating claim must precede model resolution"
        )
        XCTAssertEqual(controller.messages.last?.content, "Answered.")
        XCTAssertEqual(controller.messages.last?.status, .completed)
        XCTAssertFalse(controller.isGenerating)
    }

    /// T-ECHO-02: a failed model resolution resolves the echoed turn with a FAILED
    /// assistant message carrying the issue text — the echo is never silently
    /// dropped — and releases the generating flag.
    @MainActor
    func testFailedModelResolutionProducesAFailedAssistantTurn() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            XCTFail("no generation may start when the model failed to resolve")
            return .events([.event(request, 1, .generationCompleted)])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(
            prompt: "Echo me",
            modelID: nil,
            systemPrompt: nil,
            options: GenerationOptions(),
            modelResolver: { @MainActor in
                .unavailable(message: "Assign a chat model in the Models tab.")
            }
        )

        let last = try XCTUnwrap(controller.messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertEqual(last.status, .failed)
        XCTAssertTrue(
            last.content.contains("Assign a chat model"),
            "the failed turn must carry the resolution issue: \(last.content)"
        )
        let userTurn = controller.messages.dropLast().last
        XCTAssertEqual(userTurn?.role, .user)
        XCTAssertEqual(userTurn?.content, "Echo me")
        XCTAssertFalse(controller.isGenerating)
    }
}
