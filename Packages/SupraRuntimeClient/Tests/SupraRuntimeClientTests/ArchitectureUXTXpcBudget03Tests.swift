import Foundation
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-03 RED: tokenized input cardinality and the rectangular padded
/// allocation are not validated. One long row can therefore amplify a small
/// semantic batch into an unbounded `batchCount * maxTokenCount` allocation.
final class ArchitectureUXTXpcBudget03Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testCanonicalLedgerModelAndRevisionWireFeedsTokenShapeAccounting() throws {
        let canary = ArchitectureUXRuntimeBudgetWire.xpcBudget03
        let components = canary.split(separator: "|", omittingEmptySubsequences: false)
        let tokenCounts = components.map { $0.utf8.count }
        var policy = tokenPolicy()
        policy.maxTokensPerText = 41
        policy.maxAggregateInputTokens = 71
        policy.maxEmbeddingPaddedElements = 127
        let validator = RuntimeRequestBudgetValidator(policy: policy)

        XCTAssertNoThrow(
            try validator.validateEmbeddingTokenShape(tokenCounts: tokenCounts)
        )
        XCTAssertEqual(String(components[0]), "T_XPC_BUDGET_03_WIRE_731")
        XCTAssertEqual(String(components[1]), "model-wire-713")
        XCTAssertEqual(String(components[2]), "rev-7")
        XCTAssertFalse(canary.contains(forbiddenDefault))
    }

    func testPerTextTokenCountAdmitsNAndRejectsNPlusOne() throws {
        var policy = tokenPolicy()
        policy.maxTokensPerText = 7
        let validator = RuntimeRequestBudgetValidator(policy: policy)

        XCTAssertNoThrow(try validator.validateEmbeddingTokenShape(tokenCounts: [7, 1]))
        assertArchitectureUXBudgetViolation(
            .tokensPerText,
            limit: 7,
            actual: 8
        ) {
            try validator.validateEmbeddingTokenShape(tokenCounts: [8])
        }
        XCTAssertFalse(ArchitectureUXRuntimeBudgetWire.xpcBudget03.contains(forbiddenDefault))
    }

    func testAggregateTokenCountAdmitsNAndRejectsNPlusOne() throws {
        var policy = tokenPolicy()
        policy.maxAggregateInputTokens = 15
        let validator = RuntimeRequestBudgetValidator(policy: policy)

        XCTAssertNoThrow(try validator.validateEmbeddingTokenShape(tokenCounts: [5, 5, 5]))
        assertArchitectureUXBudgetViolation(
            .aggregateInputTokens,
            limit: 15,
            actual: 16
        ) {
            try validator.validateEmbeddingTokenShape(tokenCounts: [6, 5, 5])
        }
    }

    func testPaddedElementsAdmitNAndRejectOneLongRowAmplificationAtNPlusOne() throws {
        var policy = tokenPolicy()
        policy.maxEmbeddingPaddedElements = 21
        let validator = RuntimeRequestBudgetValidator(policy: policy)

        let acceptedCounts = [7, 2, 2]
        XCTAssertEqual(acceptedCounts.count * (acceptedCounts.max() ?? 0), 21)
        XCTAssertNoThrow(
            try validator.validateEmbeddingTokenShape(tokenCounts: acceptedCounts)
        )

        let amplifiedCounts = [7, 2, 2, 2]
        XCTAssertEqual(amplifiedCounts.reduce(0, +), 13)
        XCTAssertEqual(amplifiedCounts.count * (amplifiedCounts.max() ?? 0), 28)
        assertArchitectureUXBudgetViolation(
            .embeddingPaddedElements,
            limit: 21,
            actual: 28
        ) {
            try validator.validateEmbeddingTokenShape(tokenCounts: amplifiedCounts)
        }
    }

    func testHostValidatesTokenShapeBeforeConstructingThePaddedMLXArray() throws {
        let source = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/MLXEmbeddingModelController.swift"
        )
        let validation = try XCTUnwrap(
            source.range(of: "budgetValidator.validateEmbeddingTokenShape")
        )
        let paddedAllocation = try XCTUnwrap(source.range(of: "let padded = stacked"))

        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: validation.lowerBound),
            source.distance(from: source.startIndex, to: paddedAllocation.lowerBound),
            "padded-element N+1 must reject before MLXArray padding allocates"
        )
        XCTAssertFalse(source.contains(forbiddenDefault))
    }

    private func tokenPolicy() -> RuntimeBudgetPolicy {
        var policy = RuntimeBudgetPolicy.production
        policy.maxBatchCount = 7
        policy.maxTokensPerText = 11
        policy.maxAggregateInputTokens = 17
        policy.maxEmbeddingPaddedElements = 31
        return policy
    }
}
