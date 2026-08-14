import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-02 RED: decoded token/embedding batches and generation history
/// currently have no batch, per-string, or aggregate UTF-8 admission boundary.
final class ArchitectureUXTXpcBudget02Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testBatchCountAdmitsNAndRejectsNPlusOne() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxBatchCount = 3
        policy.maxStringUTF8Bytes = 79
        policy.maxAggregateStringUTF8Bytes = 191
        let validator = RuntimeRequestBudgetValidator(policy: policy)

        let accepted = CountTokensRequest(
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            texts: [
                ArchitectureUXRuntimeBudgetWire.xpcBudget02,
                "BATCH-WIRE-741-B",
                "BATCH-WIRE-741-C",
            ]
        )
        XCTAssertNoThrow(try validator.validate(accepted))
        XCTAssertEqual(accepted.texts.count, policy.maxBatchCount)
        XCTAssertTrue(accepted.texts[0].contains("T_XPC_BUDGET_02_WIRE_731"))
        XCTAssertTrue(accepted.texts[0].contains("model-wire-713"))
        XCTAssertTrue(accepted.texts[0].contains("rev-7"))
        XCTAssertFalse(accepted.texts.joined().contains(forbiddenDefault))

        let rejected = CountTokensRequest(
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            texts: accepted.texts + ["BATCH-WIRE-741-N-PLUS-ONE"]
        )
        assertArchitectureUXBudgetViolation(
            .batchCount,
            limit: policy.maxBatchCount,
            actual: policy.maxBatchCount + 1
        ) {
            try validator.validate(rejected)
        }
    }

    func testPerStringUTF8AdmitsNAndRejectsNPlusOne() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxBatchCount = 3
        policy.maxStringUTF8Bytes = 23
        policy.maxAggregateStringUTF8Bytes = 61
        let validator = RuntimeRequestBudgetValidator(policy: policy)
        let acceptedText = ArchitectureUXRuntimeBudgetWire.exactASCII(
            prefix: "UTF8-WIRE-743",
            utf8Bytes: policy.maxStringUTF8Bytes,
            fill: "U"
        )
        let rejectedText = acceptedText + "X"

        XCTAssertNoThrow(
            try validator.validate(
                EmbedTextRequest(
                    embeddingModelID: ArchitectureUXRuntimeBudgetWire.embeddingModelID,
                    texts: [acceptedText],
                    normalize: false
                )
            )
        )
        XCTAssertEqual(acceptedText.utf8.count, policy.maxStringUTF8Bytes)
        XCTAssertFalse(acceptedText.contains(forbiddenDefault))

        assertArchitectureUXBudgetViolation(
            .stringUTF8Bytes,
            limit: policy.maxStringUTF8Bytes,
            actual: policy.maxStringUTF8Bytes + 1
        ) {
            try validator.validate(
                EmbedTextRequest(
                    embeddingModelID: ArchitectureUXRuntimeBudgetWire.embeddingModelID,
                    texts: [rejectedText],
                    normalize: false
                )
            )
        }
    }

    func testAggregateUTF8AdmitsNAndRejectsManyShortItemsAtNPlusOne() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxBatchCount = 4
        policy.maxStringUTF8Bytes = 19
        policy.maxAggregateStringUTF8Bytes = 37
        let validator = RuntimeRequestBudgetValidator(policy: policy)
        let first = ArchitectureUXRuntimeBudgetWire.exactASCII(
            prefix: "AGG-WIRE-A",
            utf8Bytes: 18,
            fill: "A"
        )
        let acceptedSecond = ArchitectureUXRuntimeBudgetWire.exactASCII(
            prefix: "AGG-WIRE-B",
            utf8Bytes: 19,
            fill: "B"
        )
        let rejectedThird = "Z"

        XCTAssertNoThrow(
            try validator.validate(
                CountTokensRequest(
                    modelID: ArchitectureUXRuntimeBudgetWire.modelID,
                    texts: [first, acceptedSecond]
                )
            )
        )
        XCTAssertEqual(first.utf8.count + acceptedSecond.utf8.count, policy.maxAggregateStringUTF8Bytes)
        XCTAssertFalse((first + acceptedSecond).contains(forbiddenDefault))

        assertArchitectureUXBudgetViolation(
            .aggregateStringUTF8Bytes,
            limit: policy.maxAggregateStringUTF8Bytes,
            actual: policy.maxAggregateStringUTF8Bytes + 1
        ) {
            try validator.validate(
                CountTokensRequest(
                    modelID: ArchitectureUXRuntimeBudgetWire.modelID,
                    texts: [first, acceptedSecond, rejectedThird]
                )
            )
        }
    }

    func testGenerationHistoryTurnAndTotalUTF8UseIndependentNBoundaries() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxGenerationHistoryTurnCount = 2
        policy.maxGenerationHistoryTurnUTF8Bytes = 29
        policy.maxGenerationHistoryUTF8Bytes = 47
        let validator = RuntimeRequestBudgetValidator(policy: policy)
        let first = ArchitectureUXRuntimeBudgetWire.exactASCII(
            prefix: "HISTORY-WIRE-A",
            utf8Bytes: 23,
            fill: "H"
        )
        let second = ArchitectureUXRuntimeBudgetWire.exactASCII(
            prefix: "HISTORY-WIRE-B",
            utf8Bytes: 24,
            fill: "I"
        )
        let accepted = request(history: [
            .init(role: .user, content: first),
            .init(role: .assistant, content: second),
        ])

        XCTAssertNoThrow(try validator.validate(accepted))
        XCTAssertEqual(accepted.history.count, policy.maxGenerationHistoryTurnCount)
        XCTAssertEqual(
            accepted.history.reduce(0) { $0 + $1.content.utf8.count },
            policy.maxGenerationHistoryUTF8Bytes
        )
        XCTAssertFalse(accepted.history.map(\.content).joined().contains(forbiddenDefault))

        let tooManyTurns = request(history: accepted.history + [
            .init(role: .user, content: "N-PLUS-ONE-TURN-751"),
        ])
        assertArchitectureUXBudgetViolation(
            .generationHistoryTurnCount,
            limit: policy.maxGenerationHistoryTurnCount,
            actual: policy.maxGenerationHistoryTurnCount + 1
        ) {
            try validator.validate(tooManyTurns)
        }

        let tooLongTurn = request(history: [
            .init(
                role: .user,
                content: ArchitectureUXRuntimeBudgetWire.exactASCII(
                    prefix: "HISTORY-LONG-WIRE",
                    utf8Bytes: policy.maxGenerationHistoryTurnUTF8Bytes + 1,
                    fill: "L"
                )
            ),
        ])
        assertArchitectureUXBudgetViolation(
            .generationHistoryTurnUTF8Bytes,
            limit: policy.maxGenerationHistoryTurnUTF8Bytes,
            actual: policy.maxGenerationHistoryTurnUTF8Bytes + 1
        ) {
            try validator.validate(tooLongTurn)
        }

        let aggregateOverflow = request(history: accepted.history + [])
        var aggregatePolicy = policy
        aggregatePolicy.maxGenerationHistoryUTF8Bytes = 46
        let aggregateValidator = RuntimeRequestBudgetValidator(policy: aggregatePolicy)
        assertArchitectureUXBudgetViolation(
            .generationHistoryUTF8Bytes,
            limit: aggregatePolicy.maxGenerationHistoryUTF8Bytes,
            actual: 47
        ) {
            try aggregateValidator.validate(aggregateOverflow)
        }
    }

    func testHostRunsSemanticValidationForEveryDecodedDataPlaneRequest() throws {
        let host = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )
        let validationCallCount = host.components(
            separatedBy: "requestBudgetValidator.validate(request)"
        ).count - 1

        XCTAssertGreaterThanOrEqual(
            validationCallCount,
            3,
            "generate, countTokens, and embedTexts must each validate the decoded request before work"
        )
        XCTAssertFalse(host.contains(forbiddenDefault))
    }

    private func request(history: [GenerateRequest.Turn]) -> GenerateRequest {
        GenerateRequest(
            generationID: ArchitectureUXRuntimeBudgetWire.generationID,
            modelID: ArchitectureUXRuntimeBudgetWire.modelID,
            expectedModelSHA256: ArchitectureUXRuntimeBudgetWire.modelFingerprint,
            prompt: "GENERATION-PROMPT-WIRE-757",
            systemPrompt: "GENERATION-SYSTEM-WIRE-761",
            history: history,
            options: GenerationOptions(maxContextTokens: 1_031, maxOutputTokens: 37)
        )
    }
}
