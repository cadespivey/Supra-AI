import Foundation
import SupraRuntimeInterface

/// Client-side adapter around the shared bounded stream state. It retains token
/// segments rather than repeatedly copying a growing output string, and verifies
/// the one-shot terminal join against the shared receipt before publication.
struct RuntimeClientStreamAssembler: Sendable {
    private var buffer: RuntimeGenerationStreamBuffer
    private var tokenSegments: [String] = []

    init(buffer: RuntimeGenerationStreamBuffer) {
        self.buffer = buffer
    }

    mutating func ingest(_ event: GenerationEvent) throws {
        if let token = event.tokenText, !token.isEmpty {
            tokenSegments.append(token)
        }
        try buffer.ingest(event)
    }

    mutating func terminalFlush(
        for type: GenerationEventType
    ) throws -> RuntimeStreamFlushReceipt {
        let reason: RuntimeStreamFlushReason = switch type {
        case .generationCompleted:
            .completion
        case .generationCancelled:
            .cancellation
        default:
            .terminal(type)
        }
        let receipt = try buffer.flush(reason)
        let exactOutput = tokenSegments.joined()
        guard receipt.finalOutputUTF8 == Data(exactOutput.utf8) else {
            throw RuntimeClientError.decodingFailed(
                "The bounded runtime stream terminal output was not byte-exact."
            )
        }
        return receipt
    }
}
