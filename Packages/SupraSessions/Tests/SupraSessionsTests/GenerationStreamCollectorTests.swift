import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest
@testable import SupraSessions

/// Regression tests for `collectGeneratedText`: the runtime yields `.generationFailed`
/// and then finishes the stream *normally*, so a consumer that only reads `.token`
/// used to treat a failed generation as an empty success.
final class GenerationStreamCollectorTests: XCTestCase {
    private func request() -> GenerateRequest {
        GenerateRequest(generationID: GenerationID(), modelID: ModelID(), prompt: "p", systemPrompt: nil, options: GenerationOptions())
    }

    func testReturnsAccumulatedTextOnCompletion() async throws {
        let stub = StubRuntimeClient(outcome: { r in
            .events([
                .event(r, 0, .token, token: "Hello, "),
                .event(r, 1, .token, token: "world"),
                .event(r, 2, .generationCompleted),
            ])
        })
        let text = try await stub.collectGeneratedText(request())
        XCTAssertEqual(text, "Hello, world")
    }

    func testThrowsWithReasonOnGenerationFailed() async {
        let stub = StubRuntimeClient(outcome: { r in
            // Mirrors RuntimeClient: a failure event then a *normal* stream finish.
            .events([
                .event(r, 0, .token, token: "partial"),
                .event(r, 1, .generationFailed, error: RuntimeError(category: "generationFailed", message: "model exploded")),
            ])
        })
        do {
            _ = try await stub.collectGeneratedText(request())
            XCTFail("Expected collectGeneratedText to throw on .generationFailed")
        } catch let error as GenerationStreamError {
            XCTAssertEqual(error.errorDescription, "model exploded")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testThrowsInterruptedWhenStreamEndsWithoutCompletion() async {
        let stub = StubRuntimeClient(outcome: { r in
            .events([.event(r, 0, .token, token: "partial")]) // no terminal completion
        })
        do {
            _ = try await stub.collectGeneratedText(request())
            XCTFail("Expected .interrupted")
        } catch let error as GenerationStreamError {
            XCTAssertEqual(error.errorDescription, "Generation ended unexpectedly.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
