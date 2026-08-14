import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

/// T-RUNTIME-BIND-01
///
/// Expected RED: model resolution/load/token counting/generation are separate
/// calls on a shared raw client. There is no invocation permit carrying exact
/// `model-wire-713` / `rev-7` through terminal flush, so another task can swap
/// the runtime model between preparation and execution.
final class ArchitectureUXTRuntimeBind01Tests: XCTestCase {
    func testExactBindingPermitSpansTokenCountGenerationAndTerminalFlush() async throws {
        let base = ArchitectureUXImmediateRuntimeClient()
        let coordinator = architectureUXRuntimeCoordinator(base: base)
        let trace = ArchitectureUXRuntimeLaneProbe()
        let terminalFlushGate = ArchitectureUXAsyncGate()
        let generationFinished = ArchitectureUXAsyncSignal()

        let firstRequest = ArchitectureUXRuntimeWire.request(
            "binding-first-1103",
            operation: .generation,
            priority: .userInitiatedBatch,
            duplicateKey: "T_RUNTIME_BIND_01_WIRE_731"
        )
        let first = Task {
            try await coordinator.execute(firstRequest) { permit in
                let scopedRuntime: any RuntimeClientProtocol = permit
                XCTAssertEqual(firstRequest.duplicateKey, "T_RUNTIME_BIND_01_WIRE_731")
                XCTAssertFalse(
                    (firstRequest.duplicateKey ?? "")
                        .contains(ArchitectureUXRuntimeWire.forbiddenDefault)
                )
                XCTAssertEqual(permit.modelBinding, ArchitectureUXRuntimeWire.binding)
                XCTAssertEqual(permit.modelBinding?.repositoryID, "model-wire-713")
                XCTAssertEqual(permit.modelBinding?.revision, "rev-7")
                XCTAssertFalse(
                    String(describing: permit.modelBinding)
                        .contains(ArchitectureUXRuntimeWire.forbiddenDefault)
                )
                await permit.markRunning()
                await trace.record("resolve-load:model-wire-713/rev-7")

                let count = try await scopedRuntime.countTokens(CountTokensRequest(
                    modelID: ArchitectureUXRuntimeWire.modelID,
                    texts: ["binding-count-wire-1109"]
                ))
                XCTAssertEqual(count.counts, [713])
                await trace.record("count:model-wire-713/rev-7")

                var output = ""
                for try await event in try scopedRuntime.generate(
                    ArchitectureUXRuntimeWire.generationRequest(
                        prompt: "T_RUNTIME_BIND_01_WIRE_731"
                    )
                ) where event.type == .token {
                    output += event.tokenText ?? ""
                }
                XCTAssertEqual(output, "T_RUNTIME_BIND_739")
                XCTAssertEqual(
                    base.generateRequests.map(\.prompt),
                    ["T_RUNTIME_BIND_01_WIRE_731"]
                )
                await trace.record("generate:model-wire-713/rev-7")
                await generationFinished.signal()

                // Publication code performs its exact terminal flush while this
                // same permit remains live. A second model role stays queued.
                await terminalFlushGate.wait()
                await trace.record("terminal-flush:model-wire-713/rev-7")
                return output
            }
        }
        await generationFinished.wait()

        let secondRequest = ArchitectureUXRuntimeWire.request(
            "binding-other-role-1123",
            operation: .modelLoad,
            priority: .foregroundInteractive,
            binding: ArchitectureUXRuntimeWire.otherBinding
        )
        let second = Task {
            try await coordinator.execute(secondRequest) { permit in
                await trace.record(
                    "other-load:\(permit.modelBinding?.repositoryID ?? "missing")/"
                        + "\(permit.modelBinding?.revision ?? "missing")"
                )
                return "other-role-complete-1123"
            }
        }
        try await waitForArchitectureUXRuntime("other model role stays queued through flush") {
            await coordinator.snapshot(taskID: secondRequest.taskID)?.lifecycle == .queued
        }
        let beforeFlush = await trace.snapshot().trace
        XCTAssertEqual(beforeFlush, [
            "resolve-load:model-wire-713/rev-7",
            "count:model-wire-713/rev-7",
            "generate:model-wire-713/rev-7",
        ])
        XCTAssertFalse(beforeFlush.contains { $0.contains("other-load") })

        await terminalFlushGate.open()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, "T_RUNTIME_BIND_739")
        XCTAssertEqual(secondResult, "other-role-complete-1123")
        let completedTrace = await trace.snapshot().trace
        XCTAssertEqual(completedTrace, [
            "resolve-load:model-wire-713/rev-7",
            "count:model-wire-713/rev-7",
            "generate:model-wire-713/rev-7",
            "terminal-flush:model-wire-713/rev-7",
            "other-load:other-model-wire-811/rev-8",
        ])
        XCTAssertEqual(base.countModelIDs, [ArchitectureUXRuntimeWire.modelID])
        XCTAssertEqual(
            base.generateRequests.map(\.expectedModelSHA256),
            [ArchitectureUXRuntimeWire.fingerprintSHA256]
        )
    }

    func testPermitRejectsMidInvocationModelOrFingerprintSubstitution() async throws {
        let base = ArchitectureUXImmediateRuntimeClient()
        let coordinator = architectureUXRuntimeCoordinator(base: base)
        let request = ArchitectureUXRuntimeWire.request(
            "binding-substitution-1201",
            priority: .foregroundInteractive
        )

        _ = try await coordinator.execute(request) { permit in
            do {
                _ = try await permit.countTokens(CountTokensRequest(
                    modelID: ArchitectureUXRuntimeWire.otherModelID,
                    texts: ["wrong-model-wire-1207"]
                ))
                XCTFail("the permit must reject a different model UUID")
            } catch {
                if let typed = error as? ModelExecutionError {
                    if case .modelBindingMismatch = typed {
                        // Exact typed substitution rejection observed.
                    } else {
                        XCTFail("expected typed model-binding mismatch, got \(typed)")
                    }
                } else {
                    XCTFail("expected typed model-binding mismatch, got \(error)")
                }
            }

            XCTAssertThrowsError(try permit.generate(
                ArchitectureUXRuntimeWire.generationRequest(
                    fingerprintSHA256: ArchitectureUXRuntimeWire.otherFingerprintSHA256,
                    prompt: "wrong-fingerprint-wire-1213"
                )
            )) { error in
                if let typed = error as? ModelExecutionError {
                    if case .modelBindingMismatch = typed {
                        // Exact typed substitution rejection observed.
                    } else {
                        XCTFail("expected typed fingerprint mismatch, got \(typed)")
                    }
                } else {
                    XCTFail("expected typed fingerprint mismatch, got \(error)")
                }
            }
            return "substitution-rejected-1217"
        }

        XCTAssertTrue(base.countModelIDs.isEmpty, "wrong model must not reach XPC")
        XCTAssertTrue(base.generateRequests.isEmpty, "wrong fingerprint must not reach XPC")
    }
}
