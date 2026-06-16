import Foundation
import SupraCore
import SupraRuntimeInterface

final class RuntimeGenerationCoordinator: @unchecked Sendable {
    private struct ActiveGeneration {
        let request: GenerateRequest
        let eventSink: any GenerationEventSinkProtocol
        var metricsCollector = RuntimeMetricsCollector()
        var scheduledWorkItems: [DispatchWorkItem] = []
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.supra.runtime.generation", qos: .userInitiated)
    private let eventBuffer: GenerationEventBuffer
    private var activeGeneration: ActiveGeneration?

    init(eventBuffer: GenerationEventBuffer) {
        self.eventBuffer = eventBuffer
    }

    func startGeneration(
        _ request: GenerateRequest,
        eventSink: any GenerationEventSinkProtocol,
        reply: @escaping (GenerateStartResponse) -> Void
    ) {
        lock.lock()
        guard activeGeneration == nil else {
            lock.unlock()
            reply(
                GenerateStartResponse(
                    status: .busy,
                    generationID: request.generationID,
                    error: RuntimeErrorMapper.generationBusy()
                )
            )
            return
        }

        activeGeneration = ActiveGeneration(request: request, eventSink: eventSink)
        lock.unlock()

        reply(GenerateStartResponse(status: .started, generationID: request.generationID))
        deliver(type: .generationStarted, generationID: request.generationID, eventSink: eventSink)
        schedulePlaceholderGeneration(for: request)
    }

    func cancelGeneration(_ generationID: GenerationID) -> CancelGenerationResponse {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return CancelGenerationResponse(status: .notFound, generationID: generationID)
        }

        activeGeneration.scheduledWorkItems.forEach { $0.cancel() }
        let metrics = activeGeneration.metricsCollector.cancellationMetrics()
        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(
            type: .generationCancelled,
            generationID: generationID,
            message: "Generation cancelled.",
            metrics: metrics,
            eventSink: eventSink
        )
        return CancelGenerationResponse(status: .cancelled, generationID: generationID, metrics: metrics)
    }

    func activeGenerationID() -> GenerationID? {
        lock.lock()
        defer { lock.unlock() }

        return activeGeneration?.request.generationID
    }

    private func schedulePlaceholderGeneration(for request: GenerateRequest) {
        let tokens = placeholderTokens(for: request)

        for (index, token) in tokens.enumerated() {
            let delay = DispatchTimeInterval.milliseconds(35 * (index + 1))
            let workItem = DispatchWorkItem { [weak self] in
                self?.emitToken(token, generationID: request.generationID)
            }
            guard appendWorkItem(workItem, generationID: request.generationID) else {
                workItem.cancel()
                continue
            }
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        let completionDelay = DispatchTimeInterval.milliseconds(35 * (tokens.count + 1))
        let completionWorkItem = DispatchWorkItem { [weak self] in
            self?.completeGeneration(generationID: request.generationID)
        }
        guard appendWorkItem(completionWorkItem, generationID: request.generationID) else {
            completionWorkItem.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + completionDelay, execute: completionWorkItem)
    }

    private func appendWorkItem(_ workItem: DispatchWorkItem, generationID: GenerationID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard var activeGeneration, activeGeneration.request.generationID == generationID else {
            return false
        }

        activeGeneration.scheduledWorkItems.append(workItem)
        self.activeGeneration = activeGeneration
        return true
    }

    private func emitToken(_ token: String, generationID: GenerationID) {
        lock.lock()
        guard var activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        activeGeneration.metricsCollector.recordToken()
        let eventSink = activeGeneration.eventSink
        self.activeGeneration = activeGeneration
        lock.unlock()

        deliver(type: .token, generationID: generationID, tokenText: token, eventSink: eventSink)
    }

    private func completeGeneration(generationID: GenerationID) {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        let metrics = activeGeneration.metricsCollector.completionMetrics()
        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(type: .metrics, generationID: generationID, metrics: metrics, eventSink: eventSink)
        deliver(type: .generationCompleted, generationID: generationID, metrics: metrics, eventSink: eventSink)
    }

    private func deliver(
        type: GenerationEventType,
        generationID: GenerationID,
        tokenText: String? = nil,
        message: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil,
        eventSink: any GenerationEventSinkProtocol
    ) {
        let event = eventBuffer.append(
            generationID: generationID,
            type: type,
            tokenText: tokenText,
            message: message,
            metrics: metrics,
            error: error
        )
        eventSink.receive(event) {}
    }

    private func placeholderTokens(for request: GenerateRequest) -> [String] {
        let response: String
        if request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            response = "Supra AI runtime is working."
        } else {
            response = "Supra AI runtime is working. This placeholder response is streaming through the XPC service."
        }

        var tokens = response.split(separator: " ").map { String($0) + " " }
        if let last = tokens.indices.last {
            tokens[last] = tokens[last].trimmingCharacters(in: .whitespaces)
        }
        return tokens
    }
}

