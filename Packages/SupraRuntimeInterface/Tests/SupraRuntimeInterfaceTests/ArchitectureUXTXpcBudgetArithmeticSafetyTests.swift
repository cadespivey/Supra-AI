import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-05 arithmetic-safety refinement RED: public model-resource
/// profiles and memory envelopes currently accept negative fields, and their
/// computed products/sums can trap before the throwing planners can fail closed.
/// The missing typed planning errors below are the expected compile RED reason.
final class ArchitectureUXTXpcBudgetArithmeticSafetyTests: XCTestCase {
    private let canary = "T_XPC_BUDGET_05_WIRE_731|record-713|rev-7"
    private let forbiddenDefault = "DEFAULT-000"

    func testEveryNegativePublicResourceFieldFailsClosedBeforePlanning() {
        let profileFields: [(RuntimeResourceField, WritableKeyPath<ProfileNumbers, Int>)] = [
            (.weightBytes, \ProfileNumbers.weightBytes),
            (.layerCount, \ProfileNumbers.layerCount),
            (.keyValueHeadCount, \ProfileNumbers.keyValueHeadCount),
            (.headDimension, \ProfileNumbers.headDimension),
            (.scalarBytes, \ProfileNumbers.scalarBytes),
            (.supportedContextTokens, \ProfileNumbers.supportedContextTokens),
            (.nonWeightOverheadBytes, \ProfileNumbers.nonWeightOverheadBytes),
            (.activationBytesPerToken, \ProfileNumbers.activationBytesPerToken),
        ]

        for (field, keyPath) in profileFields {
            var numbers = ProfileNumbers.safe
            numbers[keyPath: keyPath] = -1
            let rejected: RuntimeResourceAdmissionDecision? = assertRejected(
                .negativeValue(field: field, actual: -1)
            ) {
                try RuntimeResourceAdmissionPlanner(envelope: envelope()).evaluate(
                    profile: profile(numbers),
                    contextTokens: 0
                )
            }
            XCTAssertNil(rejected, "Negative \(field) must emit no admission decision")
        }

        let envelopeFields: [(RuntimeResourceField, WritableKeyPath<EnvelopeNumbers, Int>)] = [
            (.unifiedMemoryCeilingBytes, \EnvelopeNumbers.unifiedMemoryCeilingBytes),
            (.appResidentBytes, \EnvelopeNumbers.appResidentBytes),
            (
                .runtimeResidentBytesExcludingModels,
                \EnvelopeNumbers.runtimeResidentBytesExcludingModels
            ),
            (.embeddingResidentBytes, \EnvelopeNumbers.embeddingResidentBytes),
            (.rerankerResidentBytes, \EnvelopeNumbers.rerankerResidentBytes),
            (.safetyMarginBytes, \EnvelopeNumbers.safetyMarginBytes),
            (.currentPressureReserveBytes, \EnvelopeNumbers.currentPressureReserveBytes),
        ]

        for (field, keyPath) in envelopeFields {
            var numbers = EnvelopeNumbers.safe
            numbers[keyPath: keyPath] = -1
            let rejected: RuntimeResourceAdmissionDecision? = assertRejected(
                .negativeValue(field: field, actual: -1)
            ) {
                try RuntimeResourceAdmissionPlanner(envelope: envelope(numbers)).evaluate(
                    profile: profile(),
                    contextTokens: 0
                )
            }
            XCTAssertNil(rejected, "Negative \(field) must emit no admission decision")
        }

        let rejectedContext: RuntimeResourceAdmissionDecision? = assertRejected(
            .negativeValue(field: .contextTokens, actual: -1)
        ) {
            try RuntimeResourceAdmissionPlanner(envelope: envelope()).evaluate(
                profile: profile(),
                contextTokens: -1
            )
        }
        XCTAssertNil(rejectedContext, "Negative context must not be silently clamped")
    }

    func testKVMultiplicationAdmitsIntMaxBoundaryAndRejectsNPlusOneWithoutTrap() throws {
        var boundary = ProfileNumbers.safe
        boundary.layerCount = 1
        boundary.keyValueHeadCount = 1
        boundary.headDimension = Int.max / 2
        boundary.scalarBytes = 1
        boundary.supportedContextTokens = 1

        let planner = RuntimeResourceAdmissionPlanner(envelope: envelope())
        let admitted = try planner.evaluate(profile: profile(boundary), contextTokens: 1)
        assertCanary(admitted)
        XCTAssertEqual(admitted.estimatedPeakBytes, Int.max - 1)

        boundary.headDimension += 1
        let rejected: RuntimeResourceAdmissionDecision? = assertRejected(
            .arithmeticOverflow(operation: .kvCacheBytesPerToken)
        ) {
            try planner.evaluate(profile: profile(boundary), contextTokens: 1)
        }
        XCTAssertNil(rejected, "KV N+1 must emit no admission decision or arithmetic trap")
    }

    func testFixedResidentSumAdmitsIntMaxBoundaryAndRejectsNPlusOneWithoutTrap() throws {
        var boundary = EnvelopeNumbers.safe
        boundary.appResidentBytes = Int.max

        let admitted = try RuntimeResourceAdmissionPlanner(
            envelope: envelope(boundary)
        ).evaluate(profile: profile(), contextTokens: 0)
        assertCanary(admitted)
        XCTAssertEqual(admitted.estimatedPeakBytes, Int.max)

        boundary.runtimeResidentBytesExcludingModels = 1
        let rejected: RuntimeResourceAdmissionDecision? = assertRejected(
            .arithmeticOverflow(operation: .fixedResidentBytes)
        ) {
            try RuntimeResourceAdmissionPlanner(envelope: envelope(boundary)).evaluate(
                profile: profile(),
                contextTokens: 0
            )
        }
        XCTAssertNil(rejected, "Fixed-resident N+1 must emit no decision or arithmetic trap")
    }

    func testEstimateTotalAdmitsIntMaxBoundaryAndRejectsNPlusOneWithoutTrap() throws {
        var resident = EnvelopeNumbers.safe
        resident.appResidentBytes = Int.max - 1
        var boundary = ProfileNumbers.safe
        boundary.weightBytes = 1

        let planner = RuntimeResourceAdmissionPlanner(envelope: envelope(resident))
        let admitted = try planner.evaluate(profile: profile(boundary), contextTokens: 0)
        assertCanary(admitted)
        XCTAssertEqual(admitted.estimatedPeakBytes, Int.max)

        boundary.weightBytes += 1
        let rejected: RuntimeResourceAdmissionDecision? = assertRejected(
            .arithmeticOverflow(operation: .totalPeakBytes)
        ) {
            try planner.evaluate(profile: profile(boundary), contextTokens: 0)
        }
        XCTAssertNil(rejected, "Estimate-total N+1 must emit no decision or arithmetic trap")
    }

    func testModelSwitchPeaksAdmitIntMaxBoundaryAndRejectNPlusOneWithoutTrap() throws {
        var current = ProfileNumbers.safe
        current.weightBytes = Int.max - 1
        var replacement = ProfileNumbers.safe
        replacement.weightBytes = 1
        let zeroResident = envelope()

        let overlapPlanner = RuntimeModelSwitchPlanner(envelope: zeroResident)
        let overlapBoundary = try overlapPlanner.plan(
            switchRequest(current: current, replacement: replacement)
        )
        assertCanary(overlapBoundary)
        XCTAssertEqual(overlapBoundary.transactionalOverlapPeakBytes, Int.max)

        replacement.weightBytes += 1
        let rejectedOverlap: RuntimeModelSwitchPlan? = assertRejected(
            .arithmeticOverflow(operation: .modelSwitchTransactionalOverlapPeakBytes)
        ) {
            try overlapPlanner.plan(switchRequest(current: current, replacement: replacement))
        }
        XCTAssertNil(rejectedOverlap, "Switch-overlap N+1 must emit no plan or arithmetic trap")

        var oneResident = EnvelopeNumbers.safe
        oneResident.appResidentBytes = 1
        replacement.weightBytes = 0
        let unloadBoundary = try RuntimeModelSwitchPlanner(
            envelope: envelope(oneResident)
        ).plan(switchRequest(current: current, replacement: replacement))
        assertCanary(unloadBoundary)
        XCTAssertEqual(unloadBoundary.plannedPeakBytes, Int.max)

        oneResident.appResidentBytes += 1
        let rejectedUnload: RuntimeModelSwitchPlan? = assertRejected(
            .arithmeticOverflow(operation: .modelSwitchUnloadPeakBytes)
        ) {
            try RuntimeModelSwitchPlanner(envelope: envelope(oneResident)).plan(
                switchRequest(current: current, replacement: replacement)
            )
        }
        XCTAssertNil(rejectedUnload, "Switch-unload N+1 must emit no plan or arithmetic trap")
    }

    private func assertRejected<T>(
        _ expected: RuntimeResourcePlanningError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) -> T? {
        do {
            let value = try operation()
            XCTFail("Expected typed resource-planning rejection.", file: file, line: line)
            return value
        } catch let error as RuntimeResourcePlanningError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertFalse(
                String(describing: error).contains(forbiddenDefault),
                file: file,
                line: line
            )
            return nil
        } catch {
            XCTFail(
                "Expected RuntimeResourcePlanningError, got \(error).",
                file: file,
                line: line
            )
            return nil
        }
    }

    private func assertCanary(
        _ decision: RuntimeResourceAdmissionDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let output = [decision.profileID, decision.modelArtifactID, decision.modelRevision]
            .joined(separator: "|")
        XCTAssertEqual(output, canary, file: file, line: line)
        XCTAssertFalse(output.contains(forbiddenDefault), file: file, line: line)
    }

    private func assertCanary(
        _ plan: RuntimeModelSwitchPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let output = [plan.wireID, plan.currentModelArtifactID, plan.currentModelRevision]
            .joined(separator: "|")
        XCTAssertEqual(output, canary, file: file, line: line)
        XCTAssertFalse(output.contains(forbiddenDefault), file: file, line: line)
    }

    private func profile(_ numbers: ProfileNumbers = .safe) -> ModelResourceProfile {
        ModelResourceProfile(
            profileID: "T_XPC_BUDGET_05_WIRE_731",
            modelID: ModelID(UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000005")!),
            modelArtifactID: "record-713",
            modelRevision: "rev-7",
            contentFingerprintSHA256: String(repeating: "c", count: 63) + "7",
            weightBytes: numbers.weightBytes,
            layerCount: numbers.layerCount,
            keyValueHeadCount: numbers.keyValueHeadCount,
            headDimension: numbers.headDimension,
            scalarBytes: numbers.scalarBytes,
            supportedContextTokens: numbers.supportedContextTokens,
            nonWeightOverheadBytes: numbers.nonWeightOverheadBytes,
            activationBytesPerToken: numbers.activationBytesPerToken
        )
    }

    private func envelope(_ numbers: EnvelopeNumbers = .safe) -> RuntimeMemoryEnvelope {
        RuntimeMemoryEnvelope(
            unifiedMemoryCeilingBytes: numbers.unifiedMemoryCeilingBytes,
            appResidentBytes: numbers.appResidentBytes,
            runtimeResidentBytesExcludingModels: numbers.runtimeResidentBytesExcludingModels,
            embeddingResidentBytes: numbers.embeddingResidentBytes,
            rerankerResidentBytes: numbers.rerankerResidentBytes,
            safetyMarginBytes: numbers.safetyMarginBytes,
            currentPressureReserveBytes: numbers.currentPressureReserveBytes
        )
    }

    private func switchRequest(
        current: ProfileNumbers,
        replacement: ProfileNumbers
    ) -> RuntimeModelSwitchRequest {
        RuntimeModelSwitchRequest(
            wireID: "T_XPC_BUDGET_05_WIRE_731",
            current: profile(current),
            replacement: ModelResourceProfile(
                profileID: "T_XPC_BUDGET_05_REPLACEMENT_WIRE_739",
                modelID: ModelID(UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000006")!),
                modelArtifactID: "record-739",
                modelRevision: "rev-9",
                contentFingerprintSHA256: String(repeating: "d", count: 63) + "9",
                weightBytes: replacement.weightBytes,
                layerCount: replacement.layerCount,
                keyValueHeadCount: replacement.keyValueHeadCount,
                headDimension: replacement.headDimension,
                scalarBytes: replacement.scalarBytes,
                supportedContextTokens: replacement.supportedContextTokens,
                nonWeightOverheadBytes: replacement.nonWeightOverheadBytes,
                activationBytesPerToken: replacement.activationBytesPerToken
            )
        )
    }
}

private struct ProfileNumbers {
    var weightBytes: Int
    var layerCount: Int
    var keyValueHeadCount: Int
    var headDimension: Int
    var scalarBytes: Int
    var supportedContextTokens: Int
    var nonWeightOverheadBytes: Int
    var activationBytesPerToken: Int

    static let safe = ProfileNumbers(
        weightBytes: 0,
        layerCount: 1,
        keyValueHeadCount: 1,
        headDimension: 1,
        scalarBytes: 1,
        supportedContextTokens: 1,
        nonWeightOverheadBytes: 0,
        activationBytesPerToken: 0
    )
}

private struct EnvelopeNumbers {
    var unifiedMemoryCeilingBytes: Int
    var appResidentBytes: Int
    var runtimeResidentBytesExcludingModels: Int
    var embeddingResidentBytes: Int
    var rerankerResidentBytes: Int
    var safetyMarginBytes: Int
    var currentPressureReserveBytes: Int

    static let safe = EnvelopeNumbers(
        unifiedMemoryCeilingBytes: Int.max,
        appResidentBytes: 0,
        runtimeResidentBytesExcludingModels: 0,
        embeddingResidentBytes: 0,
        rerankerResidentBytes: 0,
        safetyMarginBytes: 0,
        currentPressureReserveBytes: 0
    )
}
