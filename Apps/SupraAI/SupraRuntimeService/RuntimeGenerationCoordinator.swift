import Foundation
import SupraCore
import SupraRuntimeInterface

/// Service-private admission identity. Public generation IDs are caller supplied
/// and reusable, so every coordinator guard also requires this opaque epoch.
struct RuntimeGenerationEpoch: Equatable, Sendable {
    private let rawValue = UUID()
}

final class RuntimeGenerationCoordinator: @unchecked Sendable {
    private enum Phase {
        case running
        case cancelling
    }

    private struct ActiveGeneration {
        let request: GenerateRequest
        let epoch: RuntimeGenerationEpoch
        let eventSink: any GenerationEventSinkProtocol
        let task: Task<Void, Never>
        let startGate: RuntimeGenerationStartGate
        var phase: Phase = .running
    }

    private let lock = NSLock()
    private let eventBuffer: GenerationEventBuffer
    private let modelController: any ChatModelController
    private let onTerminal: @Sendable (GenerationID, RuntimeGenerationEpoch) -> Void
    private var activeGeneration: ActiveGeneration?

    init(
        eventBuffer: GenerationEventBuffer,
        modelController: any ChatModelController,
        onTerminal: @escaping @Sendable (GenerationID, RuntimeGenerationEpoch) -> Void
    ) {
        self.eventBuffer = eventBuffer
        self.modelController = modelController
        self.onTerminal = onTerminal
    }

    func startGeneration(
        _ request: GenerateRequest,
        epoch: RuntimeGenerationEpoch,
        eventSink: any GenerationEventSinkProtocol
    ) -> GenerateStartResponse {
        lock.lock()
        guard activeGeneration == nil else {
            lock.unlock()
            return GenerateStartResponse(
                status: .busy,
                generationID: request.generationID,
                error: RuntimeErrorMapper.generationBusy()
            )
        }

        let startGate = RuntimeGenerationStartGate()
        let task = makeModelGenerationTask(for: request, epoch: epoch, startGate: startGate)
        activeGeneration = ActiveGeneration(
            request: request,
            epoch: epoch,
            eventSink: eventSink,
            task: task,
            startGate: startGate
        )
        lock.unlock()

        deliver(type: .generationStarted, generationID: request.generationID, eventSink: eventSink)
#if DEBUG
        // Hosted-XPC regression seam: keep the already-installed task gated after
        // admission becomes externally observable. The matching cancellation,
        // not a timer, opens the stored gate after cancelling the Task.
        if request.prompt == "SUPRA-XPC-TEST-INSTALL-RACE" {
            return GenerateStartResponse(status: .started, generationID: request.generationID)
        }
#endif
        // The task was stored under the same lock as admission. Open it only after
        // generationStarted is published; cancellation can now always find and
        // cancel the installed task, including while this DEBUG seam is active.
        startGate.open()
        return GenerateStartResponse(status: .started, generationID: request.generationID)
    }

    func cancelGeneration(
        _ generationID: GenerationID,
        epoch: RuntimeGenerationEpoch,
        reply: @escaping (CancelGenerationResponse) -> Void
    ) {
        lock.lock()
        guard var activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
              activeGeneration.phase == .running else {
            lock.unlock()
            reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
            return
        }

        activeGeneration.phase = .cancelling
        let task = activeGeneration.task
        let startGate = activeGeneration.startGate
        self.activeGeneration = activeGeneration
        lock.unlock()

        task.cancel()
        // A DEBUG install-race Task may still be suspended on this gate. Opening
        // after task.cancel makes the seam deterministic: it resumes only to hit
        // Task.checkCancellation(), never the model actor. Idempotence also keeps
        // the normal already-open path identical.
        startGate.open()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let reply = GenerationCancellationReply(reply)
        Task { [weak self, modelController, task, reply] in
            // The model actor owns a shared cancellation flag. Do not expose the
            // generation slot until that actor has observed cancellation and the
            // old task has fully unwound, or a delayed cancel can hit its successor.
            await modelController.cancel()
            await task.value
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
            let latencyMs = Int((elapsedNanoseconds + 999_999) / 1_000_000)
            guard let response = self?.finishCancellation(
                generationID: generationID,
                epoch: epoch,
                latencyMs: latencyMs
            ) else {
                reply(CancelGenerationResponse(status: .notFound, generationID: generationID))
                return
            }
            reply(response)
        }
    }

    private func makeModelGenerationTask(
        for request: GenerateRequest,
        epoch: RuntimeGenerationEpoch,
        startGate: RuntimeGenerationStartGate
    ) -> Task<Void, Never> {
        Task { [weak self, modelController] in
            guard let coordinator = self else {
                return
            }

            do {
                await startGate.waitUntilOpen()
                try Task.checkCancellation()
#if DEBUG
                if request.prompt == RuntimeLifecycleTestHooks.staleTerminationPrompt {
                    // Keep the old generation alive until its owner's termination
                    // handler has positively captured this exact private epoch.
                    await RuntimeLifecycleTestHooks.shared.waitForStaleTerminationCapture(
                        generationID: request.generationID
                    )
                    try Task.checkCancellation()
                }
#endif
                let metrics = try await modelController.generate(
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    history: request.history,
                    options: request.options
                ) { token in
                    coordinator.emitToken(
                        token,
                        generationID: request.generationID,
                        epoch: epoch
                    )
                }
                coordinator.completeGeneration(
                    generationID: request.generationID,
                    epoch: epoch,
                    metrics: metrics
                )
            } catch is CancellationError {
                coordinator.completeCancelledGeneration(
                    generationID: request.generationID,
                    epoch: epoch
                )
            } catch {
                coordinator.failGeneration(
                    generationID: request.generationID,
                    epoch: epoch,
                    error: error
                )
            }
        }
    }

    private func emitToken(
        _ token: String,
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
              activeGeneration.phase == .running else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        lock.unlock()

        deliver(type: .token, generationID: generationID, tokenText: token, eventSink: eventSink)
    }

    private func completeGeneration(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch,
        metrics: RuntimeMetrics
    ) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
              activeGeneration.phase == .running else {
            lock.unlock()
            return
        }

        let eventSink = activeGeneration.eventSink
        self.activeGeneration = nil
        lock.unlock()

        deliver(type: .metrics, generationID: generationID, metrics: metrics, eventSink: eventSink)
        deliver(type: .generationCompleted, generationID: generationID, metrics: metrics, eventSink: eventSink)
        onTerminal(generationID, epoch)
    }

    private func completeCancelledGeneration(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch
    ) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
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
        onTerminal(generationID, epoch)
    }

    private func failGeneration(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch,
        error: Error
    ) {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
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
        onTerminal(generationID, epoch)
    }

    private func finishCancellation(
        generationID: GenerationID,
        epoch: RuntimeGenerationEpoch,
        latencyMs: Int
    ) -> CancelGenerationResponse? {
        lock.lock()
        guard let activeGeneration,
              activeGeneration.request.generationID == generationID,
              activeGeneration.epoch == epoch,
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
        onTerminal(generationID, epoch)
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

/// One-shot async gate used to construct and store a Task before it can touch the
/// model actor. Cancellation therefore never observes an admitted nil-task slot.
private final class RuntimeGenerationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilOpen() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
