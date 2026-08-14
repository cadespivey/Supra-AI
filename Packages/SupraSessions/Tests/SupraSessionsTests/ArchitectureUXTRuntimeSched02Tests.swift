import Foundation
import SupraCore
import SupraRuntimeClient
@testable import SupraSessions
import XCTest

/// T-RUNTIME-SCHED-02
///
/// Expected RED: no runtime gateway can yield background embedding at a safe
/// batch boundary, supersede queued prewarm, cancel queued/active work by typed
/// identity, or keep a successor quarantined after uncertain cancellation.
final class ArchitectureUXTRuntimeSched02Tests: XCTestCase {
    func testForegroundWaitsForSafeEmbeddingBoundaryThenTakesSameLane() async throws {
        let coordinator = architectureUXRuntimeCoordinator()
        let lane = ArchitectureUXRuntimeLaneProbe()
        let firstBatchHeld = ArchitectureUXAsyncGate()
        let firstBatchStarted = ArchitectureUXAsyncSignal()

        let backgroundRequest = ArchitectureUXRuntimeWire.request(
            "background-embedding-809",
            operation: .embeddingBatch,
            priority: .backgroundMaintenance
        )
        let background = Task {
            try await coordinator.execute(backgroundRequest) { permit in
                await permit.markRunning()
                await lane.enter("embedding-batch-1-809")
                await firstBatchStarted.signal()
                await firstBatchHeld.wait()
                await lane.leave()

                try await permit.yieldAtSafeBoundary()

                await lane.enter("embedding-batch-2-811")
                await lane.leave()
                return "background-complete-811"
            }
        }
        await firstBatchStarted.wait()

        let foregroundRequest = ArchitectureUXRuntimeWire.request(
            "T_RUNTIME_SCHED_02_WIRE_731",
            operation: .generation,
            priority: .foregroundInteractive
        )
        let foreground = Task {
            try await coordinator.execute(foregroundRequest) { permit in
                await permit.markRunning()
                await lane.enter("T_RUNTIME_SCHED_02_WIRE_731")
                await lane.leave()
                return "T_RUNTIME_SCHED_02_WIRE_731"
            }
        }
        try await waitForArchitectureUXRuntime("foreground queues behind active embedding batch") {
            await coordinator.snapshot(taskID: foregroundRequest.taskID)?.lifecycle == .queued
        }

        let heldSnapshot = await lane.snapshot()
        XCTAssertEqual(heldSnapshot.trace, ["embedding-batch-1-809"])
        XCTAssertEqual(heldSnapshot.maximum, 1)

        await firstBatchHeld.open()
        let foregroundResult = try await foreground.value
        let backgroundResult = try await background.value
        XCTAssertEqual(foregroundResult, "T_RUNTIME_SCHED_02_WIRE_731")
        XCTAssertEqual(backgroundResult, "background-complete-811")

        let completed = await lane.snapshot()
        XCTAssertEqual(completed.maximum, 1)
        XCTAssertEqual(completed.active, 0)
        XCTAssertEqual(completed.trace, [
            "embedding-batch-1-809",
            "T_RUNTIME_SCHED_02_WIRE_731",
            "embedding-batch-2-811",
        ])
        XCTAssertTrue(completed.trace.contains("T_RUNTIME_SCHED_02_WIRE_731"))
        XCTAssertFalse(completed.trace.contains(ArchitectureUXRuntimeWire.forbiddenDefault))
    }

    func testObsoletePrewarmIsSupersededAndQueuedCancellationIsExact() async throws {
        let coordinator = architectureUXRuntimeCoordinator()
        let blockerGate = ArchitectureUXAsyncGate()
        let blockerStarted = ArchitectureUXAsyncSignal()
        let executed = ArchitectureUXRuntimeLaneProbe()
        let blockerRequest = ArchitectureUXRuntimeWire.request(
            "prewarm-blocker-823",
            operation: .generation,
            priority: .foregroundInteractive
        )
        let blocker = Task {
            try await coordinator.execute(blockerRequest) { _ in
                await blockerStarted.signal()
                await blockerGate.wait()
                return "prewarm-blocker-823"
            }
        }
        await blockerStarted.wait()

        let oldPrewarm = ArchitectureUXRuntimeWire.request(
            "prewarm-old-827",
            operation: .prewarm(supersessionKey: "drafting-prewarm-wire-827"),
            priority: .speculative
        )
        let oldTask = Task {
            try await coordinator.execute(oldPrewarm) { _ in
                await executed.record("prewarm-old-827")
                return "prewarm-old-827"
            }
        }
        try await assertQueued(oldPrewarm.taskID, coordinator: coordinator)

        let newPrewarm = ArchitectureUXRuntimeWire.request(
            "prewarm-new-829",
            operation: .prewarm(supersessionKey: "drafting-prewarm-wire-827"),
            priority: .speculative
        )
        let newTask = Task {
            try await coordinator.execute(newPrewarm) { _ in
                await executed.record("prewarm-new-829")
                return "prewarm-new-829"
            }
        }
        try await assertQueued(newPrewarm.taskID, coordinator: coordinator)

        do {
            _ = try await oldTask.value
            XCTFail("the obsolete prewarm must finish as superseded without executing")
        } catch {
            XCTAssertEqual(
                error as? ModelExecutionError,
                .superseded(taskID: oldPrewarm.taskID, by: newPrewarm.taskID)
            )
        }

        let queuedCancellation = ArchitectureUXRuntimeWire.request(
            "queued-cancel-839",
            operation: .rerank,
            priority: .userInitiatedBatch
        )
        let queuedTask = Task {
            try await coordinator.execute(queuedCancellation) { _ in
                await executed.record("queued-cancel-839")
                return "queued-cancel-839"
            }
        }
        try await assertQueued(queuedCancellation.taskID, coordinator: coordinator)
        await coordinator.cancel(taskID: queuedCancellation.taskID)
        do {
            _ = try await queuedTask.value
            XCTFail("a queued cancellation cannot enter the GPU lane")
        } catch {
            XCTAssertEqual(
                error as? ModelExecutionError,
                .cancelled(taskID: queuedCancellation.taskID)
            )
        }

        await blockerGate.open()
        _ = try await blocker.value
        let newPrewarmResult = try await newTask.value
        XCTAssertEqual(newPrewarmResult, "prewarm-new-829")
        let trace = await executed.snapshot().trace
        XCTAssertEqual(trace, ["prewarm-new-829"])
        XCTAssertFalse(trace.contains("prewarm-old-827"))
        XCTAssertFalse(trace.contains("queued-cancel-839"))
    }

    func testUncertainActiveCancellationQuarantinesQueuedSuccessor() async throws {
        let base = ArchitectureUXCancellationMismatchRuntimeClient()
        let coordinator = architectureUXRuntimeCoordinator(base: base)
        let successorTrace = ArchitectureUXRuntimeLaneProbe()
        let generationID = GenerationID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000907")!
        )
        let activeRequest = ArchitectureUXRuntimeWire.request(
            "active-cancel-907",
            operation: .generation,
            priority: .foregroundInteractive
        )
        let active = Task {
            try await coordinator.execute(activeRequest) { permit in
                await permit.markRunning()
                let stream = try permit.generate(
                    ArchitectureUXRuntimeWire.generationRequest(
                        generationID: generationID,
                        prompt: "active-cancellation-wire-907"
                    )
                )
                for try await _ in stream {}
                return "unexpected-active-success-907"
            }
        }
        await base.started.wait()

        let successorRequest = ArchitectureUXRuntimeWire.request(
            "successor-911",
            operation: .generation,
            priority: .foregroundInteractive
        )
        let successor = Task {
            try await coordinator.execute(successorRequest) { _ in
                await successorTrace.record("successor-started-911")
                return "successor-started-911"
            }
        }
        try await assertQueued(successorRequest.taskID, coordinator: coordinator)

        await coordinator.cancel(taskID: activeRequest.taskID)
        try await waitForArchitectureUXRuntime("mismatched cancellation enters recovery quarantine") {
            await coordinator.snapshot(taskID: activeRequest.taskID)?.lifecycle == .recoveryRequired
        }

        _ = await active.result
        do {
            _ = try await successor.value
            XCTFail("a successor cannot start after cancellation identity mismatch")
        } catch {
            if let typed = error as? ModelExecutionError {
                if case .recoveryRequired = typed {
                    // Exact typed quarantine observed.
                } else {
                    XCTFail("expected typed recovery quarantine, got \(typed)")
                }
            } else {
                XCTFail("expected typed recovery quarantine, got \(error)")
            }
        }
        XCTAssertEqual(base.prompts, ["active-cancellation-wire-907"])
        let trace = await successorTrace.snapshot().trace
        XCTAssertTrue(trace.isEmpty)
    }

    private func assertQueued(
        _ taskID: ModelExecutionTaskID,
        coordinator: ModelExecutionCoordinator
    ) async throws {
        try await waitForArchitectureUXRuntime("\(taskID.rawValue) enters queue") {
            await coordinator.snapshot(taskID: taskID)?.lifecycle == .queued
        }
    }
}
