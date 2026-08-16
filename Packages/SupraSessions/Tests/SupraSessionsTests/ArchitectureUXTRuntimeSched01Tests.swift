import Foundation
@testable import SupraSessions
import XCTest

/// T-RUNTIME-SCHED-01
///
/// Expected RED: `ModelExecutionCoordinator` and its finite, priority-aware
/// admission queue do not exist. `RuntimeSafetyClient` admits concurrent data-
/// plane calls and therefore cannot provide deterministic priority/FIFO/aging,
/// N/N+1 backpressure, or one physical GPU lane.
final class ArchitectureUXTRuntimeSched01Tests: XCTestCase {
    func testPriorityFIFOAndAgingShareExactlyOnePhysicalGPULane() async throws {
        let clock = ArchitectureUXManualRuntimeClock()
        let coordinator = architectureUXRuntimeCoordinator(clock: clock)
        let lane = ArchitectureUXRuntimeLaneProbe()
        let blockerGate = ArchitectureUXAsyncGate()

        let blockerRequest = ArchitectureUXRuntimeWire.request(
            "blocker-701",
            operation: .embeddingBatch,
            priority: .backgroundMaintenance
        )
        let blocker = Task {
            try await coordinator.execute(blockerRequest) { _ in
                await lane.enter("blocker-701")
                await blockerGate.wait()
                await lane.leave()
                return "blocker-701"
            }
        }
        try await waitForArchitectureUXRuntime("initial GPU lane owner") {
            await lane.snapshot().trace == ["blocker-701"]
        }

        // This speculative request waits four aging intervals. It reaches the
        // foreground class and, by FIFO, precedes later foreground requests.
        let agedRequest = ArchitectureUXRuntimeWire.request(
            "T_RUNTIME_SCHED_01_WIRE_731",
            priority: .speculative
        )
        let aged = Task {
            try await coordinator.execute(agedRequest) { _ in
                await lane.enter("T_RUNTIME_SCHED_01_WIRE_731")
                await lane.leave()
                return "T_RUNTIME_SCHED_01_WIRE_731"
            }
        }
        try await assertQueued(agedRequest.taskID, coordinator: coordinator)
        clock.advance(by: 40)

        let foregroundOne = ArchitectureUXRuntimeWire.request(
            "foreground-1-709",
            priority: .foregroundInteractive
        )
        let foregroundOneTask = Task {
            try await coordinator.execute(foregroundOne) { _ in
                await lane.enter("foreground-1-709")
                await lane.leave()
                return "foreground-1-709"
            }
        }
        try await assertQueued(foregroundOne.taskID, coordinator: coordinator)

        let foregroundTwo = ArchitectureUXRuntimeWire.request(
            "foreground-2-711",
            priority: .foregroundInteractive
        )
        let foregroundTwoTask = Task {
            try await coordinator.execute(foregroundTwo) { _ in
                await lane.enter("foreground-2-711")
                await lane.leave()
                return "foreground-2-711"
            }
        }
        try await assertQueued(foregroundTwo.taskID, coordinator: coordinator)

        let userBatchOne = ArchitectureUXRuntimeWire.request(
            "user-batch-1-713",
            priority: .userInitiatedBatch
        )
        let userBatchOneTask = Task {
            try await coordinator.execute(userBatchOne) { _ in
                await lane.enter("user-batch-1-713")
                await lane.leave()
                return "user-batch-1-713"
            }
        }
        try await assertQueued(userBatchOne.taskID, coordinator: coordinator)

        let userBatchTwo = ArchitectureUXRuntimeWire.request(
            "user-batch-2-719",
            priority: .userInitiatedBatch
        )
        let userBatchTwoTask = Task {
            try await coordinator.execute(userBatchTwo) { _ in
                await lane.enter("user-batch-2-719")
                await lane.leave()
                return "user-batch-2-719"
            }
        }
        try await assertQueued(userBatchTwo.taskID, coordinator: coordinator)

        let backgroundOne = ArchitectureUXRuntimeWire.request(
            "background-1-727",
            priority: .backgroundMaintenance
        )
        let backgroundOneTask = Task {
            try await coordinator.execute(backgroundOne) { _ in
                await lane.enter("background-1-727")
                await lane.leave()
                return "background-1-727"
            }
        }
        try await assertQueued(backgroundOne.taskID, coordinator: coordinator)

        let backgroundTwo = ArchitectureUXRuntimeWire.request(
            "background-2-733",
            priority: .backgroundMaintenance
        )
        let backgroundTwoTask = Task {
            try await coordinator.execute(backgroundTwo) { _ in
                await lane.enter("background-2-733")
                await lane.leave()
                return "background-2-733"
            }
        }
        try await assertQueued(backgroundTwo.taskID, coordinator: coordinator)

        let fullQueueCount = await coordinator.queuedTaskCount
        XCTAssertEqual(
            fullQueueCount,
            ArchitectureUXRuntimeWire.queueCapacity,
            "N=7 queued requests must be admitted behind the active lane owner"
        )

        await blockerGate.open()
        _ = try await blocker.value
        _ = try await aged.value
        _ = try await foregroundOneTask.value
        _ = try await foregroundTwoTask.value
        _ = try await userBatchOneTask.value
        _ = try await userBatchTwoTask.value
        _ = try await backgroundOneTask.value
        _ = try await backgroundTwoTask.value

        let snapshot = await lane.snapshot()
        XCTAssertEqual(snapshot.maximum, 1, "there is one physical GPU admission lane")
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.trace, [
            "blocker-701",
            "T_RUNTIME_SCHED_01_WIRE_731",
            "foreground-1-709",
            "foreground-2-711",
            "user-batch-1-713",
            "user-batch-2-719",
            "background-1-727",
            "background-2-733",
        ])
        XCTAssertTrue(snapshot.trace.contains("T_RUNTIME_SCHED_01_WIRE_731"))
        XCTAssertFalse(snapshot.trace.contains(ArchitectureUXRuntimeWire.forbiddenDefault))
    }

    func testFiniteQueueAcceptsN7AndRejectsNPlusOne8WithoutRawBusy() async throws {
        let coordinator = architectureUXRuntimeCoordinator()
        let blockerGate = ArchitectureUXAsyncGate()
        let blockerStarted = ArchitectureUXAsyncSignal()
        let blockerRequest = ArchitectureUXRuntimeWire.request(
            "capacity-blocker-739",
            operation: .modelLoad,
            priority: .foregroundInteractive
        )
        let blocker = Task {
            try await coordinator.execute(blockerRequest) { _ in
                await blockerStarted.signal()
                await blockerGate.wait()
                return "capacity-blocker-739"
            }
        }
        await blockerStarted.wait()

        var accepted: [Task<String, Error>] = []
        for ordinal in 1...ArchitectureUXRuntimeWire.queueCapacity {
            let request = ArchitectureUXRuntimeWire.request(
                "capacity-\(ordinal)-743",
                priority: .backgroundMaintenance
            )
            let task = Task {
                try await coordinator.execute(request) { _ in request.taskID.rawValue }
            }
            accepted.append(task)
            try await assertQueued(request.taskID, coordinator: coordinator)
        }

        let overflow = ArchitectureUXRuntimeWire.request(
            "capacity-\(ArchitectureUXRuntimeWire.overflowOrdinal)-751",
            priority: .foregroundInteractive
        )
        do {
            _ = try await coordinator.execute(overflow) { _ in overflow.taskID.rawValue }
            XCTFail("N+1=8 must be rejected before it reaches the physical lane")
        } catch {
            XCTAssertEqual(
                error as? ModelExecutionError,
                .queueFull(capacity: ArchitectureUXRuntimeWire.queueCapacity)
            )
            XCTAssertNotEqual(error.localizedDescription.lowercased(), "busy")
        }

        let queuedAfterOverflow = await coordinator.queuedTaskCount
        XCTAssertEqual(queuedAfterOverflow, 7)
        await blockerGate.open()
        _ = try await blocker.value
        for task in accepted { _ = try await task.value }
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
