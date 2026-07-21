import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

/// Phase 1 P1-T2: the parse-and-repair generation loop. It builds the AnswerDraft prompt,
/// asks the model, parses tolerantly, validates against the exact AttributionValidator, and
/// re-asks on a parse OR validation failure — falling back cleanly when the model can't hold
/// the schema. Tested with a queued stub runtime; no real model needed.
final class TypedGroundedGeneratorTests: XCTestCase {

    /// A stub whose successive generate calls return the next queued output verbatim.
    private final class ResponseQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String]
        init(_ responses: [String]) { queue = responses }
        func next() -> String { lock.withLock { queue.isEmpty ? "" : queue.removeFirst() } }
    }

    private func runtime(_ responses: [String]) -> StubRuntimeClient {
        let queue = ResponseQueue(responses)
        return StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: queue.next()), .event(request, 1, .generationCompleted)])
        })
    }

    private let spans = [GroundedSpanInput(label: "S1", sourceID: "matter/chunk-a", text: "The fee was $900.", lowConfidence: false)]
    private let validJSON = #"{"segments": [{"text": "The fee was $900.", "citations": ["S1"]}]}"#

    private func generate(_ responses: [String], maxRepairs: Int = 2) async -> TypedGroundedGenerator.Outcome {
        await TypedGroundedGenerator.generate(
            question: "What was the fee?", spans: spans, modelID: ModelID(),
            options: GenerationOptions(), systemPrompt: nil,
            runtimeClient: runtime(responses), maxRepairs: maxRepairs
        )
    }

    func testValidFirstAttemptGeneratesDraft() async {
        let outcome = await generate([validJSON])
        guard case let .generated(result) = outcome else { return XCTFail("expected generated, got \(outcome)") }
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.validation.status, .validated)
        XCTAssertEqual(result.draft.segments.first?.citations, [SpanID("matter/chunk-a")])
    }

    func testRepairsOnParseErrorThenSucceeds() async {
        let outcome = await generate(["not json at all", validJSON])
        guard case let .generated(result) = outcome else { return XCTFail("expected generated, got \(outcome)") }
        XCTAssertEqual(result.attempts, 2, "a malformed reply is re-asked once and then succeeds")
    }

    func testRepairsOnValidationViolationThenSucceeds() async {
        // First reply is valid JSON but cites S9 (not in the packet) → validation violation → repair.
        let citesGhost = #"{"segments": [{"text": "X.", "citations": ["S9"]}]}"#
        let outcome = await generate([citesGhost, validJSON])
        guard case let .generated(result) = outcome else { return XCTFail("expected generated, got \(outcome)") }
        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.validation.status, .validated)
    }

    func testExhaustedRepairsFallsBack() async {
        let outcome = await generate(["garbage", "still garbage", "more garbage"], maxRepairs: 2)
        guard case let .fallback(reason, attempts) = outcome else { return XCTFail("expected fallback, got \(outcome)") }
        XCTAssertEqual(attempts, 3, "one initial attempt + maxRepairs")
        XCTAssertEqual(reason, .unparseable)
    }

    func testTypedRefusalIsAcceptedNotRepaired() async {
        let refusal = #"{"insufficient_evidence": true, "reason": "no_coverage"}"#
        let outcome = await generate([refusal, validJSON])
        guard case let .generated(result) = outcome else { return XCTFail("expected generated, got \(outcome)") }
        XCTAssertEqual(result.attempts, 1, "a clean refusal is not re-asked")
        XCTAssertEqual(result.validation.status, .refused)
        XCTAssertTrue(result.draft.insufficientEvidence)
    }
}
