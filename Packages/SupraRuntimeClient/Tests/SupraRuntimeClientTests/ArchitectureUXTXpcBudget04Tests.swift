import Foundation
import SupraCore
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-04 RED: generation events are appended to replay and delivered
/// without individual, aggregate-event, or aggregate-output byte accounting.
/// An overflow can therefore be followed by a normal terminal event that makes
/// a partial output look complete.
final class ArchitectureUXTXpcBudget04Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testOutputUTF8BytesAdmitNThenPoisonNPlusOneAndTerminalPublication() throws {
        var policy = outputPolicy()
        let acceptedToken = ArchitectureUXRuntimeBudgetWire.xpcBudget04
        policy.maxGenerationOutputUTF8Bytes = acceptedToken.utf8.count
        var tracker = RuntimeGenerationOutputBudgetTracker(policy: policy)

        XCTAssertNoThrow(
            try tracker.record(
                architectureUXEvent(sequence: 1, type: .token, token: acceptedToken)
            )
        )
        XCTAssertEqual(tracker.acceptedTokenUTF8Bytes, acceptedToken.utf8.count)
        XCTAssertTrue(acceptedToken.contains("T_XPC_BUDGET_04_WIRE_731"))
        XCTAssertTrue(acceptedToken.contains("model-wire-713"))
        XCTAssertTrue(acceptedToken.contains("rev-7"))
        XCTAssertTrue(tracker.canPublishTerminal)

        assertArchitectureUXBudgetViolation(
            .generationOutputUTF8Bytes,
            limit: acceptedToken.utf8.count,
            actual: acceptedToken.utf8.count + 1
        ) {
            try tracker.record(
                architectureUXEvent(sequence: 2, type: .token, token: "X")
            )
        }
        XCTAssertTrue(tracker.isOverflowed)
        XCTAssertFalse(tracker.canPublishTerminal)
        XCTAssertFalse(tracker.didAcceptTerminalEvent)

        assertArchitectureUXBudgetViolation(
            .generationOutputUTF8Bytes,
            limit: acceptedToken.utf8.count,
            actual: acceptedToken.utf8.count + 1
        ) {
            try tracker.record(
                architectureUXEvent(sequence: 3, type: .generationCompleted)
            )
        }
        XCTAssertFalse(tracker.didAcceptTerminalEvent)
        XCTAssertFalse(acceptedToken.contains(forbiddenDefault))
    }

    func testEventCountAdmitsNThenRejectsNPlusOneWithoutTerminalState() throws {
        var policy = outputPolicy()
        policy.maxGenerationEventCount = 3
        var tracker = RuntimeGenerationOutputBudgetTracker(policy: policy)

        try tracker.record(architectureUXEvent(sequence: 1, type: .generationStarted))
        try tracker.record(architectureUXEvent(sequence: 2, type: .token, token: "A"))
        try tracker.record(architectureUXEvent(sequence: 3, type: .metrics))
        XCTAssertEqual(tracker.acceptedEventCount, 3)

        assertArchitectureUXBudgetViolation(
            .generationEventCount,
            limit: 3,
            actual: 4
        ) {
            try tracker.record(
                architectureUXEvent(sequence: 4, type: .generationCompleted)
            )
        }
        XCTAssertFalse(tracker.canPublishTerminal)
        XCTAssertFalse(tracker.didAcceptTerminalEvent)
    }

    func testIndividualEncodedEventBytesAdmitNAndRejectSameEventAtNPlusOneCeiling() throws {
        let event = architectureUXEvent(
            sequence: 7,
            type: .token,
            token: "ENCODED-EVENT-WIRE-773"
        )
        let encodedByteCount = try RuntimeXPCCodec.encode(event).count
        var acceptedPolicy = outputPolicy()
        acceptedPolicy.maxEncodedEventBytes = encodedByteCount
        var acceptedTracker = RuntimeGenerationOutputBudgetTracker(policy: acceptedPolicy)
        XCTAssertNoThrow(try acceptedTracker.record(event))

        var rejectedPolicy = acceptedPolicy
        rejectedPolicy.maxEncodedEventBytes = encodedByteCount - 1
        var rejectedTracker = RuntimeGenerationOutputBudgetTracker(policy: rejectedPolicy)
        assertArchitectureUXBudgetViolation(
            .encodedEventBytes,
            limit: encodedByteCount - 1,
            actual: encodedByteCount
        ) {
            try rejectedTracker.record(event)
        }
        XCTAssertFalse(event.tokenText?.contains(forbiddenDefault) ?? true)
    }

    func testHostAccountsBeforeReplayAppendAndCancelsOnBudgetViolation() throws {
        let buffer = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/GenerationEventBuffer.swift"
        )
        let coordinator = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/RuntimeGenerationCoordinator.swift"
        )
        let accounting = try XCTUnwrap(
            buffer.range(of: "try outputBudgetTracker.record(event)")
        )
        let append = try XCTUnwrap(
            buffer.range(of: "eventsByGenerationID[generationID, default: []].append(event)")
        )

        XCTAssertLessThan(
            buffer.distance(from: buffer.startIndex, to: accounting.lowerBound),
            buffer.distance(from: buffer.startIndex, to: append.lowerBound)
        )
        XCTAssertTrue(coordinator.contains("cancelForBudgetViolation"))
        XCTAssertFalse(buffer.contains(forbiddenDefault))
        XCTAssertFalse(coordinator.contains(forbiddenDefault))
    }

    private func outputPolicy() -> RuntimeBudgetPolicy {
        var policy = RuntimeBudgetPolicy.production
        policy.maxGenerationEventCount = 19
        policy.maxGenerationOutputUTF8Bytes = 79
        policy.maxEncodedEventBytes = 1_009
        return policy
    }
}

func architectureUXEvent(
    sequence: Int,
    type: GenerationEventType,
    token: String? = nil,
    message: String? = nil,
    timestamp: Date? = nil
) -> GenerationEvent {
    GenerationEvent(
        generationID: ArchitectureUXRuntimeBudgetWire.generationID,
        sequenceNumber: sequence,
        timestamp: timestamp ?? Date(timeIntervalSince1970: 1_947_731_000 + Double(sequence)),
        type: type,
        tokenText: token,
        message: message,
        metrics: type == .metrics || type == .generationCompleted
            ? RuntimeMetrics(generatedTokenCount: sequence, truncated: false)
            : nil
    )
}
