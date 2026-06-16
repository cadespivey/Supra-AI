import Foundation
import SupraCore
import SupraRuntimeInterface

final class GenerationEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let retainedGenerationLimit = 20
    private var eventsByGenerationID: [GenerationID: [GenerationEvent]] = [:]
    private var generationOrder: [GenerationID] = []

    func append(
        generationID: GenerationID,
        type: GenerationEventType,
        tokenText: String? = nil,
        message: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) -> GenerationEvent {
        lock.lock()
        defer { lock.unlock() }

        if eventsByGenerationID[generationID] == nil {
            generationOrder.append(generationID)
            pruneIfNeeded()
        }

        let nextSequenceNumber = (eventsByGenerationID[generationID]?.last?.sequenceNumber ?? 0) + 1
        let event = GenerationEvent(
            generationID: generationID,
            sequenceNumber: nextSequenceNumber,
            timestamp: Date(),
            type: type,
            tokenText: tokenText,
            message: message,
            metrics: metrics,
            error: error
        )
        eventsByGenerationID[generationID, default: []].append(event)
        return event
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) -> [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }

        return eventsByGenerationID[generationID, default: []]
            .filter { $0.sequenceNumber > sequenceNumber }
    }

    private func pruneIfNeeded() {
        while generationOrder.count > retainedGenerationLimit {
            let generationID = generationOrder.removeFirst()
            eventsByGenerationID[generationID] = nil
        }
    }
}

