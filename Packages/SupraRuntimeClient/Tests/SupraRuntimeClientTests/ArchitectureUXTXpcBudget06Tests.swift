import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-06 RED: token-count and embedding responses are decoded into
/// unbounded collections. The client checks only token-count request parity and
/// does not cap vector count, dimension, scalars, or Float32 bytes.
final class ArchitectureUXTXpcBudget06Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testTokenCountResponseCountAdmitsNAndRejectsNPlusOne() throws {
        var policy = responsePolicy()
        policy.maxTokenCountResponseCount = 3
        let validator = RuntimeResponseBudgetValidator(policy: policy)
        let canaryComponents = ArchitectureUXRuntimeBudgetWire.xpcBudget06
            .split(separator: "|", omittingEmptySubsequences: false)
        let accepted = CountTokensResponse(
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            counts: canaryComponents.map { $0.utf8.count }
        )

        XCTAssertNoThrow(
            try validator.validate(accepted, expectedRequestItemCount: 3)
        )
        XCTAssertEqual(accepted.counts.count, policy.maxTokenCountResponseCount)
        XCTAssertEqual(String(canaryComponents[0]), "T_XPC_BUDGET_06_WIRE_731")
        XCTAssertEqual(String(canaryComponents[1]), "model-wire-713")
        XCTAssertEqual(String(canaryComponents[2]), "rev-7")

        let rejected = CountTokensResponse(
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            counts: accepted.counts + [19]
        )
        assertArchitectureUXBudgetViolation(
            .tokenCountResponseCount,
            limit: policy.maxTokenCountResponseCount,
            actual: policy.maxTokenCountResponseCount + 1
        ) {
            try validator.validate(rejected, expectedRequestItemCount: 4)
        }
        XCTAssertFalse(
            ArchitectureUXRuntimeBudgetWire.xpcBudget06.contains(forbiddenDefault)
        )
    }

    func testEmbeddingVectorCountAndDimensionUseExactNBoundaries() throws {
        let policy = responsePolicy()
        let validator = RuntimeResponseBudgetValidator(policy: policy)
        let accepted = embeddingResponse(
            vectors: Array(repeating: Array(repeating: 0.25, count: 5), count: 3),
            dimension: 5
        )

        XCTAssertNoThrow(try validator.validate(accepted, expectedVectorCount: 3))
        XCTAssertEqual(accepted.vectors.count, policy.maxEmbeddingVectorCount)
        XCTAssertEqual(accepted.dimension, policy.maxEmbeddingDimension)

        let tooManyVectors = embeddingResponse(
            vectors: Array(repeating: [Float](repeating: 0.5, count: 1), count: 4),
            dimension: 1
        )
        assertArchitectureUXBudgetViolation(
            .embeddingVectorCount,
            limit: 3,
            actual: 4
        ) {
            try validator.validate(tooManyVectors, expectedVectorCount: 4)
        }

        let tooWide = embeddingResponse(
            vectors: [[Float](repeating: 0.75, count: 6)],
            dimension: 6
        )
        assertArchitectureUXBudgetViolation(
            .embeddingDimension,
            limit: 5,
            actual: 6
        ) {
            try validator.validate(tooWide, expectedVectorCount: 1)
        }
    }

    func testEmbeddingScalarCountAndFloat32BytesUseExactNBoundaries() throws {
        let accepted = embeddingResponse(
            vectors: Array(repeating: [Float](repeating: 0.875, count: 5), count: 3),
            dimension: 5
        )
        var acceptedPolicy = responsePolicy()
        acceptedPolicy.maxEmbeddingScalarCount = 15
        acceptedPolicy.maxEmbeddingScalarBytes = 60
        let acceptedValidator = RuntimeResponseBudgetValidator(policy: acceptedPolicy)

        XCTAssertNoThrow(
            try acceptedValidator.validate(accepted, expectedVectorCount: 3)
        )
        XCTAssertEqual(accepted.vectors.reduce(0) { $0 + $1.count }, 15)
        XCTAssertEqual(accepted.vectors.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.size, 60)

        var scalarPolicy = responsePolicy()
        scalarPolicy.maxEmbeddingVectorCount = 4
        scalarPolicy.maxEmbeddingDimension = 4
        scalarPolicy.maxEmbeddingScalarCount = 15
        scalarPolicy.maxEmbeddingScalarBytes = 101
        let scalarValidator = RuntimeResponseBudgetValidator(policy: scalarPolicy)
        let tooManyScalars = embeddingResponse(
            vectors: Array(repeating: [Float](repeating: 0.625, count: 4), count: 4),
            dimension: 4
        )
        assertArchitectureUXBudgetViolation(
            .embeddingScalarCount,
            limit: 15,
            actual: 16
        ) {
            try scalarValidator.validate(tooManyScalars, expectedVectorCount: 4)
        }

        var bytePolicy = acceptedPolicy
        bytePolicy.maxEmbeddingScalarBytes = 59
        let byteValidator = RuntimeResponseBudgetValidator(policy: bytePolicy)
        assertArchitectureUXBudgetViolation(
            .embeddingScalarBytes,
            limit: 59,
            actual: 60
        ) {
            try byteValidator.validate(accepted, expectedVectorCount: 3)
        }
        XCTAssertFalse(
            "EMBEDDING-RESPONSE-WIRE-797".contains(forbiddenDefault)
        )
    }

    func testClientValidatesTokenAndEmbeddingResponsesBeforeReturningCollections() throws {
        let client = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift"
        )
        let validationCallCount = client.components(
            separatedBy: "responseBudgetValidator.validate("
        ).count - 1

        XCTAssertGreaterThanOrEqual(validationCallCount, 2)
        XCTAssertFalse(client.contains(forbiddenDefault))
    }

    func testEmbeddingLoadDimensionRejectsNPlusOneBeforeHostProfileArithmetic() throws {
        // Expected RED: RuntimeRequestBudgetValidator has no embedding-load
        // semantic validator, and the host multiplies expectedDimension before
        // any bounded check.
        var policy = responsePolicy()
        policy.maxEmbeddingDimension = 7
        let validator = RuntimeRequestBudgetValidator(policy: policy)
        let modelID = ArchitectureUXRuntimeBudgetWire.embeddingModelID

        XCTAssertNoThrow(try validator.validate(LoadEmbeddingModelRequest(
            embeddingModelID: modelID,
            modelPath: "/synthetic/T_XPC_BUDGET_06_WIRE_731",
            displayName: "Embedding model-wire-713",
            revision: "rev-7",
            expectedDimension: 7
        )))
        assertArchitectureUXBudgetViolation(
            .embeddingDimension,
            limit: 7,
            actual: 8
        ) {
            try validator.validate(LoadEmbeddingModelRequest(
                embeddingModelID: modelID,
                modelPath: "/synthetic/T_XPC_BUDGET_06_WIRE_731_N_PLUS_1",
                displayName: "Embedding model-wire-713 N+1",
                revision: "rev-7",
                expectedDimension: 8
            ))
        }
        assertArchitectureUXBudgetViolation(
            .embeddingDimension,
            limit: 7,
            actual: Int.max
        ) {
            try validator.validate(LoadEmbeddingModelRequest(
                embeddingModelID: modelID,
                modelPath: "/synthetic/T_XPC_BUDGET_06_WIRE_731_INT_MAX",
                displayName: "Embedding model-wire-713 Int.max",
                revision: "rev-7",
                expectedDimension: Int.max
            ))
        }

        let host = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )
        let loadMethod = try XCTUnwrap(host.range(of: "func loadEmbeddingModel(\n        _ request:"))
        let profile = try XCTUnwrap(
            host.range(of: "Self.embeddingResourceProfile(for: request)", range: loadMethod.lowerBound..<host.endIndex)
        )
        let validation = try XCTUnwrap(
            host.range(of: "requestBudgetValidator.validate(request)", range: loadMethod.lowerBound..<profile.lowerBound)
        )
        XCTAssertLessThan(
            host.distance(from: host.startIndex, to: validation.lowerBound),
            host.distance(from: host.startIndex, to: profile.lowerBound)
        )
        XCTAssertFalse(host.contains(forbiddenDefault))
    }

    private func responsePolicy() -> RuntimeBudgetPolicy {
        var policy = RuntimeBudgetPolicy.production
        policy.maxTokenCountResponseCount = 3
        policy.maxEmbeddingVectorCount = 3
        policy.maxEmbeddingDimension = 5
        policy.maxEmbeddingScalarCount = 15
        policy.maxEmbeddingScalarBytes = 60
        return policy
    }

    private func embeddingResponse(
        vectors: [[Float]],
        dimension: Int
    ) -> EmbedTextResponse {
        EmbedTextResponse(
            state: .loaded,
            vectors: vectors,
            dimension: dimension,
            normalized: false
        )
    }
}
