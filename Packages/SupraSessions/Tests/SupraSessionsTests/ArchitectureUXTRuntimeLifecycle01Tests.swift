import Foundation
import SupraCore
import SupraRuntimeClient
@testable import SupraSessions
import XCTest

/// T-RUNTIME-LIFECYCLE-01
///
/// Expected RED: model-backed controllers own unrelated Boolean state and the
/// shared coordinator lifecycle, duplicate key, relaunch policy, progress,
/// cancel, and typed recovery contract do not exist.
final class ArchitectureUXTRuntimeLifecycle01Tests: XCTestCase {
    func testSharedLifecycleAndDuplicateSuppressionAreCoordinatorOwned() async throws {
        let coordinator = architectureUXRuntimeCoordinator()
        let blockerGate = ArchitectureUXAsyncGate()
        let blockerStarted = ArchitectureUXAsyncSignal()
        let blockerRequest = ArchitectureUXRuntimeWire.request(
            "lifecycle-blocker-1009",
            operation: .embeddingBatch,
            priority: .backgroundMaintenance
        )
        let blocker = Task {
            try await coordinator.execute(blockerRequest) { _ in
                await blockerStarted.signal()
                await blockerGate.wait()
                return "lifecycle-blocker-1009"
            }
        }
        await blockerStarted.wait()

        let preparingStarted = ArchitectureUXAsyncSignal()
        let permitRunning = ArchitectureUXAsyncGate()
        let runningStarted = ArchitectureUXAsyncSignal()
        let terminalGate = ArchitectureUXAsyncGate()
        let duplicateKey = "T_RUNTIME_LIFECYCLE_01_WIRE_731"
        let request = ArchitectureUXRuntimeWire.request(
            "lifecycle-1013",
            priority: .userInitiatedBatch,
            duplicateKey: duplicateKey
        )
        let operation = Task {
            try await coordinator.execute(request) { permit in
                XCTAssertEqual(request.duplicateKey, "T_RUNTIME_LIFECYCLE_01_WIRE_731")
                XCTAssertFalse(
                    (request.duplicateKey ?? "").contains(ArchitectureUXRuntimeWire.forbiddenDefault)
                )
                await preparingStarted.signal()
                await permitRunning.wait()
                await permit.markRunning()
                await runningStarted.signal()
                await terminalGate.wait()
                return "lifecycle-complete-1013"
            }
        }
        try await waitForLifecycle(.queued, taskID: request.taskID, coordinator: coordinator)

        await blockerGate.open()
        _ = try await blocker.value
        await preparingStarted.wait()
        try await waitForLifecycle(.preparing, taskID: request.taskID, coordinator: coordinator)

        let duplicate = ArchitectureUXRuntimeWire.request(
            "lifecycle-duplicate-1019",
            priority: .foregroundInteractive,
            duplicateKey: duplicateKey
        )
        do {
            _ = try await coordinator.execute(duplicate) { _ in
                "unexpected-duplicate-execution-1019"
            }
            XCTFail("a nonterminal duplicate invocation must be suppressed")
        } catch {
            XCTAssertEqual(
                error as? ModelExecutionError,
                .duplicateInvocation(existingTaskID: request.taskID)
            )
        }

        await permitRunning.open()
        await runningStarted.wait()
        try await waitForLifecycle(.running, taskID: request.taskID, coordinator: coordinator)

        await terminalGate.open()
        let lifecycleResult = try await operation.value
        XCTAssertEqual(lifecycleResult, "lifecycle-complete-1013")
        try await waitForLifecycle(.completed, taskID: request.taskID, coordinator: coordinator)

        let failureRequest = ArchitectureUXRuntimeWire.request(
            "lifecycle-failure-1021",
            priority: .foregroundInteractive
        )
        do {
            _ = try await coordinator.execute(failureRequest) { _ -> String in
                throw ArchitectureUXRuntimeTestFailure.syntheticFailure713
            }
            XCTFail("synthetic failure must be visible")
        } catch {
            XCTAssertEqual(
                error as? ArchitectureUXRuntimeTestFailure,
                .syntheticFailure713
            )
        }
        try await waitForLifecycle(.failed, taskID: failureRequest.taskID, coordinator: coordinator)
    }

    func testLifecyclePolicyPinsProgressCancelRecoveryAndRelaunchBehavior() {
        let expected: [ModelExecutionLifecycle: ModelExecutionLifecycleBehavior] = [
            .queued: ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .cancel,
                relaunchDisposition: .retryFromOwnerCheckpoint,
                suppressesDuplicateInvocation: true
            ),
            .preparing: ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .cancel,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            ),
            .running: ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .cancel,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            ),
            .cancelling: ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .none,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            ),
            .completed: ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .none,
                relaunchDisposition: .preserveTerminal,
                suppressesDuplicateInvocation: false
            ),
            .failed: ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .retry,
                relaunchDisposition: .retryFromOwnerCheckpoint,
                suppressesDuplicateInvocation: false
            ),
            .recoveryRequired: ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .recoverRuntime,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            ),
        ]

        XCTAssertEqual(Set(ModelExecutionLifecycle.allCases), Set(expected.keys))
        for state in ModelExecutionLifecycle.allCases {
            XCTAssertEqual(
                ModelExecutionLifecycleContract.behavior(for: state),
                expected[state],
                "shared UI/relaunch behavior drifted for \(state)"
            )
        }
    }

    private func waitForLifecycle(
        _ lifecycle: ModelExecutionLifecycle,
        taskID: ModelExecutionTaskID,
        coordinator: ModelExecutionCoordinator
    ) async throws {
        try await waitForArchitectureUXRuntime("\(taskID.rawValue) reaches \(lifecycle)") {
            await coordinator.snapshot(taskID: taskID)?.lifecycle == lifecycle
        }
    }
}
