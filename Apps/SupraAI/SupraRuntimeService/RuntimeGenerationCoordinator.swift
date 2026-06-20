import Foundation
import SupraCore
import SupraRuntimeInterface

final class RuntimeGenerationCoordinator: @unchecked Sendable {
    private struct ActiveGeneration {
        let request: GenerateRequest
        let eventSink: any GenerationEventSinkProtocol
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let eventBuffer: GenerationEventBuffer
    private let modelController: any ChatModelController
    private var activeGeneration: ActiveGeneration?

    init(eventBuffer: GenerationEventBuffer, modelController: any ChatModelController) {
        self.eventBuffer = eventBuffer
        self.modelController = modelController
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
        startModelGenerationTask(for: request)
    }

    func cancelGeneration(_ generationID: GenerationID) -> CancelGenerationResponse {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return CancelGenerationResponse(status: .notFound, generationID: generationID)
        }

        let task = activeGeneration.task
        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        task?.cancel()
        Task { [modelController] in
            await modelController.cancel()
        }

        // Cancellation is acknowledged immediately — the cancelled event is delivered
        // here, before the model task unwinds — so request→ack latency is ~0.
        let metrics = RuntimeMetrics(cancellationLatencyMs: 0)
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

    private func startModelGenerationTask(for request: GenerateRequest) {
        let task = Task { [weak self, modelController] in
            guard let coordinator = self else {
                return
            }

            do {
                let metrics = try await modelController.generate(
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    history: request.history,
                    options: request.options
                ) { token in
                    coordinator.emitToken(token, generationID: request.generationID)
                }
                coordinator.completeGeneration(generationID: request.generationID, metrics: metrics)
            } catch is CancellationError {
                coordinator.completeCancelledGeneration(generationID: request.generationID)
            } catch {
                coordinator.failGeneration(generationID: request.generationID, error: error)
            }
        }

        lock.lock()
        guard var activeGeneration, activeGeneration.request.generationID == request.generationID else {
            lock.unlock()
            task.cancel()
            return
        }

        activeGeneration.task = task
        self.activeGeneration = activeGeneration
        lock.unlock()
    }

    private func emitToken(_ token: String, generationID: GenerationID) {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        lock.unlock()

        deliver(type: .token, generationID: generationID, tokenText: token, eventSink: eventSink)
    }

    private func completeGeneration(generationID: GenerationID, metrics: RuntimeMetrics) {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(type: .metrics, generationID: generationID, metrics: metrics, eventSink: eventSink)
        deliver(type: .generationCompleted, generationID: generationID, metrics: metrics, eventSink: eventSink)
    }

    private func completeCancelledGeneration(generationID: GenerationID) {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        // Cancellation is acknowledged immediately — the cancelled event is delivered
        // here, before the model task unwinds — so request→ack latency is ~0.
        let metrics = RuntimeMetrics(cancellationLatencyMs: 0)
        deliver(
            type: .generationCancelled,
            generationID: generationID,
            message: "Generation cancelled.",
            metrics: metrics,
            eventSink: eventSink
        )
    }

    private func failGeneration(generationID: GenerationID, error: Error) {
        lock.lock()
        guard let activeGeneration, activeGeneration.request.generationID == generationID else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(
            type: .generationFailed,
            generationID: generationID,
            message: "Generation failed.",
            error: RuntimeErrorMapper.generationFailed(error),
            eventSink: eventSink
        )
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
}
