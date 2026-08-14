import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-05 RED: runtime admission has no model resource profile or
/// injectable hardware/memory envelope. A model load therefore reaches MLX
/// without accounting for KV, activations, non-weight overhead, other resident
/// models, process footprints, a margin, or current pressure.
final class ArchitectureUXTXpcBudget05Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testNonDefaultModelProfileAndHardwareCeilingAdmitNRejectNPlusOne() throws {
        let profile = modelProfile()
        let exactCeiling = 1_035
        let admittedPlanner = RuntimeResourceAdmissionPlanner(
            envelope: memoryEnvelope(unifiedMemoryCeilingBytes: exactCeiling)
        )
        let estimate = try admittedPlanner.estimate(
            profile: profile,
            contextTokens: 1
        )

        XCTAssertEqual(estimate.modelWeightBytes, 211)
        XCTAssertEqual(estimate.kvCacheBytes, 120)
        XCTAssertEqual(estimate.activationBytes, 7)
        XCTAssertEqual(estimate.modelNonWeightOverheadBytes, 37)
        XCTAssertEqual(estimate.totalPeakBytes, exactCeiling)

        let admitted = try admittedPlanner.evaluate(profile: profile, contextTokens: 1)
        XCTAssertEqual(admitted.disposition, .admit)
        XCTAssertEqual(admitted.estimatedPeakBytes, exactCeiling)
        XCTAssertEqual(admitted.ceilingBytes, exactCeiling)
        XCTAssertEqual(admitted.modelID, ArchitectureUXRuntimeBudgetWire.modelID)
        XCTAssertEqual(admitted.profileID, "T_XPC_BUDGET_05_WIRE_731")
        XCTAssertEqual(admitted.modelArtifactID, "model-wire-713")
        XCTAssertEqual(admitted.modelRevision, "rev-7")
        XCTAssertEqual(
            admitted.modelFingerprintSHA256,
            ArchitectureUXRuntimeBudgetWire.modelFingerprint
        )

        let rejectedPlanner = RuntimeResourceAdmissionPlanner(
            envelope: memoryEnvelope(unifiedMemoryCeilingBytes: exactCeiling - 1)
        )
        let rejected = try rejectedPlanner.evaluate(profile: profile, contextTokens: 1)
        XCTAssertEqual(rejected.disposition, .defer)
        XCTAssertEqual(rejected.estimatedPeakBytes, exactCeiling)
        XCTAssertEqual(rejected.ceilingBytes, exactCeiling - 1)
        XCTAssertEqual(rejected.correctiveAction, .freeMemoryOrReduceContext)
        XCTAssertFalse(
            String(describing: rejected).contains(forbiddenDefault)
        )
    }

    func testHostOwnsAnInjectableBudgetPolicyAndResourceAdmissionPlanner() throws {
        let host = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )

        XCTAssertTrue(host.contains("budgetPolicy: RuntimeBudgetPolicy = .production"))
        XCTAssertTrue(host.contains("RuntimeResourceAdmissionPlanner"))
        XCTAssertTrue(host.contains("resourceAdmissionPlanner.evaluate("))
        XCTAssertFalse(host.contains(forbiddenDefault))
    }

    static func modelProfile(
        profileID: String = "T_XPC_BUDGET_05_WIRE_731",
        modelID: ModelID = ArchitectureUXRuntimeBudgetWire.modelID,
        modelArtifactID: String = ArchitectureUXRuntimeBudgetWire.modelArtifactID,
        modelRevision: String = ArchitectureUXRuntimeBudgetWire.modelRevision,
        fingerprint: String = ArchitectureUXRuntimeBudgetWire.modelFingerprint,
        weightBytes: Int = 211
    ) -> ModelResourceProfile {
        ModelResourceProfile(
            profileID: profileID,
            modelID: modelID,
            modelArtifactID: modelArtifactID,
            modelRevision: modelRevision,
            contentFingerprintSHA256: fingerprint,
            weightBytes: weightBytes,
            layerCount: 2,
            keyValueHeadCount: 3,
            headDimension: 5,
            scalarBytes: 2,
            supportedContextTokens: 127,
            nonWeightOverheadBytes: 37,
            activationBytesPerToken: 7
        )
    }

    static func memoryEnvelope(unifiedMemoryCeilingBytes: Int) -> RuntimeMemoryEnvelope {
        RuntimeMemoryEnvelope(
            unifiedMemoryCeilingBytes: unifiedMemoryCeilingBytes,
            appResidentBytes: 101,
            runtimeResidentBytesExcludingModels: 103,
            embeddingResidentBytes: 107,
            rerankerResidentBytes: 109,
            safetyMarginBytes: 113,
            currentPressureReserveBytes: 127
        )
    }
}
