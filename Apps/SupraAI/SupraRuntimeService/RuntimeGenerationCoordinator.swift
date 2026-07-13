import Foundation
import SupraCore
import SupraRuntimeInterface

final class RuntimeGenerationCoordinator: @unchecked Sendable {
    private enum Phase {
        case running
        case cancelling
    }

    private struct ActiveGeneration {
        let request: GenerateRequest
        let eventSink: any GenerationEventSinkProtocol
        var task: Task<Void, Never>?
        var phase: Phase = .running
    }

    private let lock = NSLock()
    private let eventBuffer: GenerationEventBuffer
    private let modelController: any ChatModelController
    private let onTerminal: @Sendable (GenerationID) -> Void
    private var activeGeneration: ActiveGeneration?

    init(
        eventBuffer: GenerationEventBuffer,
        modelController: any ChatModelController,
        onTerminal: @escaping @Sendable (GenerationID) -> Void
    ) {
        self.eventBuffer = eventBuffer
        self.modelController = modelController
        self.onTerminal = onTerminal
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

        deliver(type: .generationStarted, generationID: request.generationID, eventSink: eventSink)
        startModelGenerationTask(for: request)
        // Publish acceptance only after the task is installed. A client can issue
        // cancel as soon as this reply arrives; replying first left a window where
        // cancellation could clear the slot before the old task even existed.
        reply(GenerateStartResponse(status: .started, generationID: request.generationID))
    }

    func cancelGeneration(
        _ generationID: GenerationID,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        lock.lock()
        guard var activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .running else {
            lock.unlock()
            reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
            return
        }

        activeGeneration.phase = .cancelling
        let task = activeGeneration.task
        self.activeGeneration = activeGeneration
        lock.unlock()

        task?.cancel()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let reply = GenerationCancellationReply(reply)
        Task { [weak self, modelController, task, reply] in
            // The model actor owns a shared cancellation flag. Do not expose the
            // generation slot until that actor has observed cancellation and the
            // old task has fully unwound, or a delayed cancel can hit its successor.
            await modelController.cancel()
            await task?.value
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
            let latencyMs = Int((elapsedNanoseconds + 999_999) / 1_000_000)
            guard let response = self?.finishCancellation(
                generationID: generationID,
                latencyMs: latencyMs
            ) else {
                reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
                return
            }
            reply(response)
        }
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
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .running else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        lock.unlock()

        deliver(type: .token, generationID: generationID, tokenText: token, eventSink: eventSink)
    }

    private func completeGeneration(generationID: GenerationID, metrics: RuntimeMetrics) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .running else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(type: .metrics, generationID: generationID, metrics: metrics, eventSink: eventSink)
        deliver(type: .generationCompleted, generationID: generationID, metrics: metrics, eventSink: eventSink)
        onTerminal(generationID)
    }

    private func completeCancelledGeneration(generationID: GenerationID) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .running else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        let metrics = RuntimeMetrics()
        deliver(
            type: .generationCancelled,
            generationID: generationID,
            message: "Generation cancelled.",
            metrics: metrics,
            eventSink: eventSink
        )
        onTerminal(generationID)
    }

    private func failGeneration(generationID: GenerationID, error: Error) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .running else {
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
        onTerminal(generationID)
    }

    private func finishCancellation(
        generationID: GenerationID,
        latencyMs: Int
    ) -> CancelGenerationResponse? {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.phase == .cancelling else {
            lock.unlock()
            return nil
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        let metrics = RuntimeMetrics(cancellationLatencyMs: latencyMs)
        deliver(
            type: .generationCancelled,
            generationID: generationID,
            message: "Generation cancelled.",
            metrics: metrics,
            eventSink: eventSink
        )
        onTerminal(generationID)
        return CancelGenerationResponse(status: .cancelled, generationID: generationID, metrics: metrics)
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

private struct GenerationCancellationReply: @unchecked Sendable {
    private let reply: (CancelGenerationResponse) -> Void

    init(_ reply: @escaping (CancelGenerationResponse) -> Void) {
        self.reply = reply
    }

    func callAsFunction(_ response: CancelGenerationResponse) {
        reply(response)
    }
}
