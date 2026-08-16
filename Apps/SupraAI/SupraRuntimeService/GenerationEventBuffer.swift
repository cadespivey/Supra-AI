import Foundation
import SupraCore
import SupraRuntimeInterface

final class GenerationEventBuffer: @unchecked Sendable {
    struct ResidencyCounts: Equatable, Sendable {
        let generationCount: Int
        let eventCount: Int
    }
    private let lock = NSLock()
    private let retainedGenerationLimit = 20
    private let budgetPolicy: RuntimeBudgetPolicy
    private let streamPolicy: RuntimeStreamBufferPolicy
    private var eventsByGenerationID: [GenerationID: [GenerationEvent]] = [:]
    private var outputBudgetTrackers: [GenerationID: RuntimeGenerationOutputBudgetTracker] = [:]
    private var retainedReplayEncodedBytes: [GenerationID: Int] = [:]
    private var lastSequenceNumbers: [GenerationID: Int] = [:]
    private var generationOrder: [GenerationID] = []

    init(
        budgetPolicy: RuntimeBudgetPolicy = .production,
        streamPolicy: RuntimeStreamBufferPolicy = .production
    ) {
        self.budgetPolicy = budgetPolicy
        self.streamPolicy = streamPolicy
    }

    func append(
        generationID: GenerationID,
        type: GenerationEventType,
        tokenText: String? = nil,
        message: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) throws -> GenerationEvent {
        lock.lock()
        defer { lock.unlock() }

        if type == .generationStarted {
            // Public generation IDs are caller supplied and may be reused after
            // termination. A new started event establishes a fresh accounting
            // epoch instead of inheriting a prior run's poison/counts/replay.
            generationOrder.removeAll { $0 == generationID }
            eventsByGenerationID[generationID] = []
            generationOrder.append(generationID)
            outputBudgetTrackers[generationID] = RuntimeGenerationOutputBudgetTracker(
                policy: budgetPolicy
            )
            retainedReplayEncodedBytes[generationID] = 0
            lastSequenceNumbers[generationID] = 0
            pruneIfNeeded()
        } else if eventsByGenerationID[generationID] == nil {
            generationOrder.append(generationID)
            eventsByGenerationID[generationID] = []
            outputBudgetTrackers[generationID] = RuntimeGenerationOutputBudgetTracker(
                policy: budgetPolicy
            )
            retainedReplayEncodedBytes[generationID] = 0
            lastSequenceNumbers[generationID] = 0
            pruneIfNeeded()
        }

        let nextSequenceNumber = (lastSequenceNumbers[generationID] ?? 0) + 1
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

        var outputBudgetTracker = outputBudgetTrackers[generationID]
            ?? RuntimeGenerationOutputBudgetTracker(policy: budgetPolicy)
        do {
            try outputBudgetTracker.record(event)
        } catch {
            // Persist the poisoned tracker so a later terminal event cannot make
            // an already-partial replay look successfully complete.
            outputBudgetTrackers[generationID] = outputBudgetTracker
            throw error
        }
        outputBudgetTrackers[generationID] = outputBudgetTracker

        let encodedBytes = try RuntimeXPCCodec.encode(event).count
        eventsByGenerationID[generationID, default: []].append(event)
        retainedReplayEncodedBytes[generationID, default: 0] += encodedBytes
        lastSequenceNumbers[generationID] = nextSequenceNumber
        compactReplayIfNeeded(for: generationID)
        return event
    }

    /// Produces a live-only failure marker after replay accounting has poisoned
    /// the generation. It is deliberately not appended to replay: reconnects
    /// must never mistake partial retained output for a normally terminated run.
    func makeUnretainedBudgetFailureEvent(
        generationID: GenerationID,
        error: RuntimeError
    ) -> GenerationEvent {
        lock.lock()
        defer { lock.unlock() }

        let sequenceNumber = (lastSequenceNumbers[generationID] ?? 0) + 1
        lastSequenceNumbers[generationID] = sequenceNumber
        return GenerationEvent(
            generationID: generationID,
            sequenceNumber: sequenceNumber,
            timestamp: Date(),
            type: .generationFailed,
            message: "Generation stopped after exceeding a bounded runtime output limit.",
            error: error
        )
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) -> [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }

        return eventsByGenerationID[generationID, default: []]
            .filter { $0.sequenceNumber > sequenceNumber }
    }

    func residencyCounts() -> ResidencyCounts {
        lock.lock()
        defer { lock.unlock() }
        return ResidencyCounts(
            generationCount: eventsByGenerationID.count,
            eventCount: eventsByGenerationID.values.reduce(0) { $0 + $1.count }
        )
    }

    @discardableResult
    func resetForRuntimeEpoch() -> ResidencyCounts {
        lock.lock()
        defer { lock.unlock() }
        let counts = ResidencyCounts(
            generationCount: eventsByGenerationID.count,
            eventCount: eventsByGenerationID.values.reduce(0) { $0 + $1.count }
        )
        eventsByGenerationID.removeAll(keepingCapacity: false)
        outputBudgetTrackers.removeAll(keepingCapacity: false)
        retainedReplayEncodedBytes.removeAll(keepingCapacity: false)
        lastSequenceNumbers.removeAll(keepingCapacity: false)
        generationOrder.removeAll(keepingCapacity: false)
        return counts
    }

    private func pruneIfNeeded() {
        while generationOrder.count > retainedGenerationLimit {
            let generationID = generationOrder.removeFirst()
            eventsByGenerationID[generationID] = nil
            outputBudgetTrackers[generationID] = nil
            retainedReplayEncodedBytes[generationID] = nil
            lastSequenceNumbers[generationID] = nil
        }
    }

    private func compactReplayIfNeeded(for generationID: GenerationID) {
        while let events = eventsByGenerationID[generationID],
              events.count > streamPolicy.maxReplayEventCount
                || retainedReplayEncodedBytes[generationID, default: 0]
                    > streamPolicy.maxReplayEncodedBytes {
            guard events.count > 1 else { return }
            let removed = events[0]
            let removedBytes = (try? RuntimeXPCCodec.encode(removed).count) ?? 0
            eventsByGenerationID[generationID]?.removeFirst()
            retainedReplayEncodedBytes[generationID, default: 0] = max(
                0,
                retainedReplayEncodedBytes[generationID, default: 0] - removedBytes
            )
        }
    }
}
