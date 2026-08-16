import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-RUNTIME-SWITCH-01 RED: chat and embedding loads always build a replacement
/// while the old container remains resident. There is no preflight plan choosing
/// unload-first under low headroom while preserving transactional replacement
/// when old and new full weights safely fit together.
final class ArchitectureUXTRuntimeSwitch01Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testLowHeadroomUnloadsOldBeforeNewAndNeverPlansDoubleWeightPeak() throws {
        let request = switchRequest()
        let lowHeadroomCeiling = 920
        let planner = RuntimeModelSwitchPlanner(
            envelope: ArchitectureUXTXpcBudget05Tests.memoryEnvelope(
                unifiedMemoryCeilingBytes: lowHeadroomCeiling
            )
        )
        let plan = try planner.plan(request)

        XCTAssertEqual(plan.wireID, "T_RUNTIME_SWITCH_01_WIRE_731")
        XCTAssertEqual(plan.currentModelArtifactID, "model-wire-713")
        XCTAssertEqual(plan.currentModelRevision, "rev-7")
        XCTAssertEqual(plan.strategy, .unloadCurrentThenLoadReplacement)
        XCTAssertTrue(plan.unloadsCurrentBeforeReplacementLoad)
        XCTAssertFalse(plan.keepsCurrentOnReplacementFailure)
        XCTAssertFalse(plan.overlapsFullModelWeights)
        XCTAssertEqual(plan.plannedPeakBytes, lowHeadroomCeiling)
        XCTAssertEqual(plan.transactionalOverlapPeakBytes, 1_168)
        XCTAssertGreaterThan(plan.transactionalOverlapPeakBytes, plan.ceilingBytes)
        XCTAssertFalse(
            String(describing: plan).contains(forbiddenDefault)
        )
    }

    func testSafeHeadroomPreservesTransactionalSwapAndOldModelOnFailure() throws {
        let request = switchRequest()
        let safeHeadroomCeiling = 1_168
        let planner = RuntimeModelSwitchPlanner(
            envelope: ArchitectureUXTXpcBudget05Tests.memoryEnvelope(
                unifiedMemoryCeilingBytes: safeHeadroomCeiling
            )
        )
        let plan = try planner.plan(request)

        XCTAssertEqual(plan.wireID, "T_RUNTIME_SWITCH_01_WIRE_731")
        XCTAssertEqual(plan.currentModelArtifactID, "model-wire-713")
        XCTAssertEqual(plan.currentModelRevision, "rev-7")
        XCTAssertEqual(plan.strategy, .transactionalSwap)
        XCTAssertFalse(plan.unloadsCurrentBeforeReplacementLoad)
        XCTAssertTrue(plan.keepsCurrentOnReplacementFailure)
        XCTAssertTrue(plan.overlapsFullModelWeights)
        XCTAssertEqual(plan.plannedPeakBytes, safeHeadroomCeiling)
        XCTAssertLessThanOrEqual(plan.plannedPeakBytes, plan.ceilingBytes)
        XCTAssertEqual(plan.replacementModelID, ArchitectureUXRuntimeBudgetWire.replacementModelID)
        XCTAssertEqual(
            plan.replacementModelFingerprintSHA256,
            ArchitectureUXRuntimeBudgetWire.replacementFingerprint
        )
        XCTAssertFalse(
            String(describing: plan).contains(forbiddenDefault)
        )
    }

    func testHostExecutesUnloadFirstBranchBeforeReplacementLoad() throws {
        let source = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )
        let unloadBranch = try XCTUnwrap(
            source.range(of: "case .unloadCurrentThenLoadReplacement:")
        )
        let unload = try XCTUnwrap(
            source.range(of: "try await modelController.unload()", range: unloadBranch.lowerBound..<source.endIndex)
        )
        let load = try XCTUnwrap(
            source.range(of: "try await modelController.loadModel(", range: unload.lowerBound..<source.endIndex)
        )

        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: unload.lowerBound),
            source.distance(from: source.startIndex, to: load.lowerBound)
        )
        XCTAssertTrue(source.contains("case .transactionalSwap:"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "modelSwitchPlanner.plan(").count - 1,
            2,
            "chat and embedding replacement must use the same headroom plan"
        )
        XCTAssertTrue(source.contains("await embeddingController.unload()"))
        XCTAssertFalse(source.contains(forbiddenDefault))
    }

    private func switchRequest() -> RuntimeModelSwitchRequest {
        RuntimeModelSwitchRequest(
            wireID: "T_RUNTIME_SWITCH_01_WIRE_731",
            current: ArchitectureUXTXpcBudget05Tests.modelProfile(
                profileID: "T_RUNTIME_SWITCH_01_WIRE_731",
                modelArtifactID: "model-wire-713",
                modelRevision: "rev-7",
                weightBytes: 211
            ),
            replacement: ArchitectureUXTXpcBudget05Tests.modelProfile(
                profileID: "T_RUNTIME_SWITCH_01_REPLACEMENT_WIRE_739",
                modelID: ArchitectureUXRuntimeBudgetWire.replacementModelID,
                modelArtifactID: "model-wire-739",
                modelRevision: "rev-9",
                fingerprint: ArchitectureUXRuntimeBudgetWire.replacementFingerprint,
                weightBytes: 223
            )
        )
    }
}
