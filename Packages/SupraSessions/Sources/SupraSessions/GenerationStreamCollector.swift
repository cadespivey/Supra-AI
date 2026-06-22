import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// Error surfaced when a runtime generation stream fails or ends without a
/// successful completion.
///
/// The runtime emits `.generationFailed` as a normal stream event and then
/// finishes the stream *without throwing* (see `RuntimeClient.generate`), so a
/// consumer that only reads `.token` would otherwise treat a failed generation
/// as an empty success. `collectGeneratedText` converts that into a thrown error.
enum GenerationStreamError: Error, LocalizedError, Equatable {
    case failed(String)
    case interrupted
    case cancelled
    case truncatedReasoning
    case contextOverflowed

    var errorDescription: String? {
        switch self {
        case let .failed(reason): reason
        case .interrupted: "Generation ended unexpectedly."
        case .cancelled: "Generation was cancelled."
        case .truncatedReasoning:
            "The model ran out of its output budget before finishing its reasoning, so no answer was produced. Increase the output token budget or retry."
        case .contextOverflowed:
            "The sources plus the question are larger than the model's context window, so the answer could not be grounded reliably. Narrow the scope, select fewer/smaller documents, or use a model with a larger context window."
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
        var wasCancelled = false
        var completed = false
        var truncated = false
        var reasoningActive = false
        var contextOverflowed = false
        for try await event in try generate(request) {
            switch event.type {
            case .token:
                if let token = event.tokenText { output += token }
            case .generationCompleted:
                completed = true
                truncated = event.metrics?.truncated ?? false
                reasoningActive = event.metrics?.reasoningActive ?? false
                contextOverflowed = event.metrics?.contextOverflowed ?? false
            case .generationFailed:
                failureReason = event.error?.message ?? "Generation failed."
            case .generationCancelled:
                wasCancelled = true
            case .generationStarted, .metrics, .queued, .modelLoading, .modelLoaded:
                break
            }
        }
        // Cancellation is a user action, not a failure — surface it distinctly so
        // callers can record it as cancelled rather than failed.
        if wasCancelled { throw GenerationStreamError.cancelled }
        if let failureReason { throw GenerationStreamError.failed(failureReason) }
        guard completed else { throw GenerationStreamError.interrupted }
        // The grounding contract + top sources were evicted from the front of the
        // prompt mid-generation (system + question alone overflow the window), so any
        // "answer" is confidently ungrounded — refuse it for these one-shot grounded
        // flows rather than return it as if it were source-grounded.
        if contextOverflowed { throw GenerationStreamError.contextOverflowed }
        // If a run with reasoning ACTUALLY active (the loaded model emits think
        // blocks AND the preset enabled them) hit the output-token cap before
        // closing its reasoning, the text is a truncated chain-of-thought, not an
        // answer — refuse it. A plain model (reasoningActive == false) never emits
        // `</think>`, so its truncated-but-valid output is returned unchanged.
        if truncated, reasoningActive, !output.contains("</think>") {
            throw GenerationStreamError.truncatedReasoning
        }
        return output
    }
}
