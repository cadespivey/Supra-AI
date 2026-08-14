import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-RUNTIME-KV-01 RED: context admission is based on the requested rotating-KV
/// window alone. There is no exact prompt count joined to a weight/KV/activation/
/// overhead/current-pressure estimate, and overflow still enters generation after
/// silently dropping history or marking exact grounded evidence as overflowed.
final class ArchitectureUXTRuntimeKv01Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testContextNAdmitsAndGroundedNPlusOneRequiresExactSourceRepack() throws {
        let profile = ArchitectureUXTXpcBudget05Tests.modelProfile(
            profileID: "T_RUNTIME_KV_01_WIRE_731",
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7"
        )
        let resourcePlanner = RuntimeResourceAdmissionPlanner(
            envelope: ArchitectureUXTXpcBudget05Tests.memoryEnvelope(
                unifiedMemoryCeilingBytes: 1_162
            )
        )
        let planner = RuntimeContextAdmissionPlanner(resourcePlanner: resourcePlanner)
        let admittedRequest = contextRequest(
            requestedContextTokens: 2,
            actualPromptTokens: 2,
            workload: .groundedExactEvidence,
            allowsExactSourceRepacking: true
        )

        let admitted = try planner.evaluate(admittedRequest, profile: profile)
        XCTAssertEqual(admitted.disposition, .admit)
        XCTAssertEqual(admitted.requestedContextTokens, 2)
        XCTAssertEqual(admitted.actualPromptTokens, 2)
        XCTAssertEqual(admitted.maximumAdmittedContextTokens, 2)
        XCTAssertEqual(admitted.estimatedPeakBytes, 1_162)
        assertCanonicalBinding(admitted)

        let nPlusOneRequest = contextRequest(
            requestedContextTokens: 3,
            actualPromptTokens: 3,
            workload: .groundedExactEvidence,
            allowsExactSourceRepacking: true
        )
        let nPlusOne = try planner.evaluate(nPlusOneRequest, profile: profile)
        XCTAssertEqual(nPlusOne.disposition, .repackExactSources)
        XCTAssertEqual(nPlusOne.requestedContextTokens, 3)
        XCTAssertEqual(nPlusOne.actualPromptTokens, 3)
        XCTAssertEqual(nPlusOne.maximumAdmittedContextTokens, 2)
        XCTAssertEqual(nPlusOne.correctiveAction, .repackExactSources(maximumContextTokens: 2))
        XCTAssertTrue(nPlusOne.preservesExactEvidence)
        XCTAssertFalse(nPlusOne.didSilentlyTruncateExactEvidence)
        XCTAssertNil(nPlusOne.substitutedModelID)
        assertCanonicalBinding(nPlusOne)
    }

    func testGroundedNPlusOneDefersWhenExactSourcesCannotBeRepacked() throws {
        let profile = ArchitectureUXTXpcBudget05Tests.modelProfile(
            profileID: "T_RUNTIME_KV_01_WIRE_731",
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7"
        )
        let planner = RuntimeContextAdmissionPlanner(
            resourcePlanner: RuntimeResourceAdmissionPlanner(
                envelope: ArchitectureUXTXpcBudget05Tests.memoryEnvelope(
                    unifiedMemoryCeilingBytes: 1_162
                )
            )
        )
        let decision = try planner.evaluate(
            contextRequest(
                requestedContextTokens: 3,
                actualPromptTokens: 3,
                workload: .groundedExactEvidence,
                allowsExactSourceRepacking: false
            ),
            profile: profile
        )

        XCTAssertEqual(decision.disposition, .defer)
        XCTAssertEqual(decision.correctiveAction, .reduceExactSourceSetAndRetry)
        XCTAssertTrue(decision.preservesExactEvidence)
        XCTAssertFalse(decision.didSilentlyTruncateExactEvidence)
        XCTAssertNil(decision.substitutedModelID)
        assertCanonicalBinding(decision)
    }

    func testOrdinaryHistoryNPlusOneRequiresVisibleTrimDisclosure() throws {
        let profile = ArchitectureUXTXpcBudget05Tests.modelProfile(
            profileID: "T_RUNTIME_KV_01_WIRE_731",
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7"
        )
        let planner = RuntimeContextAdmissionPlanner(
            resourcePlanner: RuntimeResourceAdmissionPlanner(
                envelope: ArchitectureUXTXpcBudget05Tests.memoryEnvelope(
                    unifiedMemoryCeilingBytes: 1_162
                )
            )
        )
        let decision = try planner.evaluate(
            contextRequest(
                requestedContextTokens: 3,
                actualPromptTokens: 3,
                workload: .ordinaryConversation,
                allowsExactSourceRepacking: false
            ),
            profile: profile
        )

        XCTAssertEqual(decision.disposition, .trimHistoryWithDisclosure)
        XCTAssertTrue(decision.historyTrimDisclosureRequired)
        XCTAssertEqual(decision.maximumAdmittedContextTokens, 2)
        XCTAssertNil(decision.substitutedModelID)
        assertCanonicalBinding(decision)
    }

    func testAdmissionReservesOutputKVAndHonorsTheRequestedPromptCeiling() throws {
        // Expected RED: RuntimeContextAdmissionRequest has no reserved-output
        // field, so admission estimates prompt allowance alone and exposes no
        // prompt ceiling after subtracting the output reservation.
        let profile = ModelResourceProfile(
            profileID: "T_RUNTIME_KV_01_WIRE_731",
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7",
            contentFingerprintSHA256: ArchitectureUXRuntimeBudgetWire.modelFingerprint,
            weightBytes: 0,
            layerCount: 1,
            keyValueHeadCount: 1,
            headDimension: 1,
            scalarBytes: 1,
            supportedContextTokens: 7,
            nonWeightOverheadBytes: 0,
            activationBytesPerToken: 0
        )
        let planner = RuntimeContextAdmissionPlanner(
            resourcePlanner: RuntimeResourceAdmissionPlanner(
                envelope: RuntimeMemoryEnvelope(
                    unifiedMemoryCeilingBytes: 8,
                    appResidentBytes: 0,
                    runtimeResidentBytesExcludingModels: 0,
                    embeddingResidentBytes: 0,
                    rerankerResidentBytes: 0,
                    safetyMarginBytes: 0,
                    currentPressureReserveBytes: 0
                )
            )
        )

        // Hardware could hold four total KV tokens, but this invocation asked
        // for a two-token prompt plus one reserved output token. A three-token
        // prepared prompt must therefore repack instead of being admitted just
        // because it fits the larger hardware envelope.
        let decision = try planner.evaluate(
            RuntimeContextAdmissionRequest(
                wireID: "T_RUNTIME_KV_01_WIRE_731",
                modelID: ArchitectureUXRuntimeBudgetWire.modelID,
                modelArtifactID: "model-wire-713",
                modelRevision: "rev-7",
                expectedModelSHA256: ArchitectureUXRuntimeBudgetWire.modelFingerprint,
                requestedContextTokens: 2,
                actualPromptTokens: 3,
                reservedOutputTokens: 1,
                workload: .groundedExactEvidence,
                allowsExactSourceRepacking: true
            ),
            profile: profile
        )

        XCTAssertEqual(decision.disposition, .repackExactSources)
        XCTAssertEqual(decision.reservedOutputTokens, 1)
        XCTAssertEqual(decision.requestedKVTokens, 3)
        XCTAssertEqual(decision.actualPeakKVTokens, 4)
        XCTAssertEqual(decision.maximumAdmittedContextTokens, 4)
        XCTAssertEqual(decision.maximumAdmittedPromptTokens, 2)
        XCTAssertEqual(
            decision.correctiveAction,
            .repackExactSources(maximumContextTokens: 2)
        )
        XCTAssertTrue(decision.preservesExactEvidence)
        XCTAssertFalse(decision.didSilentlyTruncateExactEvidence)
        assertCanonicalBinding(decision)
    }

    func testHostCountsPreparedPromptAndAdmitsItBeforeMLXGeneration() throws {
        let source = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/MLXModelController.swift"
        )
        let count = try XCTUnwrap(
            source.range(of: "let actualPromptTokenCount = input.text.tokens.size")
        )
        let admission = try XCTUnwrap(
            source.range(of: "contextAdmissionPlanner.evaluate(")
        )
        let generation = try XCTUnwrap(source.range(of: "container.generate("))
        let countOffset = source.distance(from: source.startIndex, to: count.lowerBound)
        let admissionOffset = source.distance(from: source.startIndex, to: admission.lowerBound)
        let generationOffset = source.distance(from: source.startIndex, to: generation.lowerBound)

        XCTAssertLessThan(countOffset, admissionOffset)
        XCTAssertLessThan(admissionOffset, generationOffset)
        XCTAssertTrue(source.contains("reservedOutputTokens: options.maxOutputTokens"))
        XCTAssertTrue(source.contains("admission.maximumAdmittedPromptTokens"))
        XCTAssertTrue(source.contains("didSilentlyTruncateExactEvidence: false"))
        XCTAssertFalse(source.contains(forbiddenDefault))
    }

    private func contextRequest(
        requestedContextTokens: Int,
        actualPromptTokens: Int,
        workload: RuntimeContextWorkload,
        allowsExactSourceRepacking: Bool
    ) -> RuntimeContextAdmissionRequest {
        RuntimeContextAdmissionRequest(
            wireID: "T_RUNTIME_KV_01_WIRE_731",
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7",
            expectedModelSHA256: ArchitectureUXRuntimeBudgetWire.modelFingerprint,
            requestedContextTokens: requestedContextTokens,
            actualPromptTokens: actualPromptTokens,
            workload: workload,
            allowsExactSourceRepacking: allowsExactSourceRepacking
        )
    }

    private func assertCanonicalBinding(
        _ decision: RuntimeContextAdmissionDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(decision.wireID, "T_RUNTIME_KV_01_WIRE_731", file: file, line: line)
        XCTAssertEqual(decision.modelID, ArchitectureUXRuntimeBudgetWire.modelID, file: file, line: line)
        XCTAssertEqual(decision.modelArtifactID, "model-wire-713", file: file, line: line)
        XCTAssertEqual(decision.modelRevision, "rev-7", file: file, line: line)
        XCTAssertEqual(
            decision.expectedModelSHA256,
            ArchitectureUXRuntimeBudgetWire.modelFingerprint,
            file: file,
            line: line
        )
        XCTAssertFalse(
            String(describing: decision).contains(forbiddenDefault),
            file: file,
            line: line
        )
    }
}
