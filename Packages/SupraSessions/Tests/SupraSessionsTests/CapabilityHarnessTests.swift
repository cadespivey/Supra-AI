import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

/// Phase 1 P1-T0: the capability harness runs TypedGroundedGenerator over frozen grounded
/// fixtures and tallies the reliability metrics (success/first-attempt/fallback rates, avg
/// attempts, refusal accuracy) that produce the typed-primary go/no-go. The aggregation is
/// pure and tested here; a real-model run is invoked from the app with a loaded model.
final class CapabilityHarnessTests: XCTestCase {

    private final class ResponseQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String]
        init(_ r: [String]) { queue = r }
        func next() -> String { lock.withLock { queue.isEmpty ? "" : queue.removeFirst() } }
    }

    private func fixture(_ name: String, expectsRefusal: Bool = false) -> CapabilityFixture {
        CapabilityFixture(
            name: name, question: "Q?",
            spans: [GroundedSpanInput(label: "S1", sourceID: "m/c-a", text: "The fee was $900.", lowConfidence: false)],
            expectsRefusal: expectsRefusal
        )
    }

    private func generated(attempts: Int, refused: Bool) -> TypedGroundedGenerator.Outcome {
        let draft = refused ? AnswerDraft(refusal: Refusal(.noCoverage))
                            : AnswerDraft(segments: [Segment(text: "The fee was $900.", citations: [SpanID("m/c-a")])])
        let evidence = EvidenceSet(spans: [Span(id: SpanID("m/c-a"), kind: .document, exactText: "The fee was $900.")])
        return .generated(.init(draft: draft, validation: AttributionValidator.validate(draft: draft, evidence: evidence), attempts: attempts))
    }

    func testReportAggregatesRatesAndAttempts() {
        let results: [(CapabilityFixture, TypedGroundedGenerator.Outcome)] = [
            (fixture("a"), generated(attempts: 1, refused: false)),
            (fixture("b"), generated(attempts: 2, refused: false)),
            (fixture("c"), .fallback(.unparseable, attempts: 3)),
            (fixture("d", expectsRefusal: true), generated(attempts: 1, refused: true)),
        ]
        let report = CapabilityHarness.report(from: results)
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.generated, 3)
        XCTAssertEqual(report.fellBack, 1)
        XCTAssertEqual(report.firstAttempt, 2)                 // a and d
        XCTAssertEqual(report.successRate, 0.75, accuracy: 0.0001)
        XCTAssertEqual(report.fallbackRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(report.avgAttempts, (1.0 + 2.0 + 1.0) / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.refusalExpected, 1)
        XCTAssertEqual(report.refusalCorrect, 1)
        XCTAssertEqual(report.refusalAccuracy, 1.0, accuracy: 0.0001)
    }

    func testRefusalMissIsNotCountedCorrect() {
        // A fixture that should refuse but produced a substantive answer is a miss.
        let results: [(CapabilityFixture, TypedGroundedGenerator.Outcome)] = [
            (fixture("x", expectsRefusal: true), generated(attempts: 1, refused: false)),
        ]
        let report = CapabilityHarness.report(from: results)
        XCTAssertEqual(report.refusalExpected, 1)
        XCTAssertEqual(report.refusalCorrect, 0)
        XCTAssertEqual(report.refusalAccuracy, 0.0, accuracy: 0.0001)
    }

    func testRunDrivesGeneratorAndTalliesSuccess() async {
        // Smoke: a stub that always returns a valid draft → the run reports full success.
        let valid = #"{"segments": [{"text": "The fee was $900.", "citations": ["S1"]}]}"#
        let queue = ResponseQueue([valid, valid])
        let stub = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: queue.next()), .event(request, 1, .generationCompleted)])
        })
        let report = await CapabilityHarness.run(
            fixtures: [fixture("a"), fixture("b")],
            modelID: ModelID(), options: GenerationOptions(), systemPrompt: nil,
            runtimeClient: stub, maxRepairs: 2
        )
        XCTAssertEqual(report.total, 2)
        XCTAssertEqual(report.generated, 2)
        XCTAssertEqual(report.successRate, 1.0, accuracy: 0.0001)
    }

    func testStandardFixturesAreNonEmptyAndIncludeARefusalCase() {
        let fixtures = CapabilityHarness.standardFixtures()
        XCTAssertFalse(fixtures.isEmpty)
        XCTAssertTrue(fixtures.contains { $0.expectsRefusal }, "must include a not-answerable case")
        XCTAssertTrue(fixtures.contains { !$0.expectsRefusal }, "must include answerable cases")
    }
}
