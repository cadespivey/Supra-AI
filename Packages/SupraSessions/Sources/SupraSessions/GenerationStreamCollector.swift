import Foundation
import SupraRuntimeClient
import SupraRuntimeInterface

/// Error surfaced when a runtime generation stream fails or ends without a
/// successful completion.
///
/// The runtime emits `.generationFailed` as a normal stream event and then
/// finishes the stream *without throwing* (see `RuntimeClient.generate`), so a
/// consumer that only reads `.token` would otherwise treat a failed generation
/// as an empty success. `collectGeneratedText` converts that into a thrown error.
enum GenerationStreamError: Error, LocalizedError {
    case failed(String)
    case interrupted

    var errorDescription: String? {
        switch self {
        case let .failed(reason): reason
        case .interrupted: "Generation ended unexpectedly."
        }
    }
}

extension RuntimeClientProtocol {
    /// Runs a generation to completion and returns the accumulated token text,
    /// throwing `GenerationStreamError` if the runtime reports a failure/cancel or
    /// the stream ends without a `.generationCompleted` event. Use this for the
    /// one-shot "generate and parse the whole answer" flows (Q&A, chronology,
    /// structured output, research planning) so a failed run never silently looks
    /// like an empty-but-successful answer.
    func collectGeneratedText(_ request: GenerateRequest) async throws -> String {
        var output = ""
        var failureReason: String?
        var completed = false
        for try await event in try generate(request) {
            switch event.type {
            case .token:
                if let token = event.tokenText { output += token }
            case .generationCompleted:
                completed = true
            case .generationFailed:
                failureReason = event.error?.message ?? "Generation failed."
            case .generationCancelled:
                failureReason = failureReason ?? "Generation was cancelled."
            case .generationStarted, .metrics, .queued, .modelLoading, .modelLoaded:
                break
            }
        }
        if let failureReason { throw GenerationStreamError.failed(failureReason) }
        guard completed else { throw GenerationStreamError.interrupted }
        return output
    }
}
