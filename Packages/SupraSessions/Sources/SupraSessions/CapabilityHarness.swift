import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface

/// One grounded case the capability harness measures: a question, its retrieved evidence
/// spans, and whether the honest answer is a refusal (so a model that answers a
/// not-answerable case is scored as a miss).
public struct CapabilityFixture: Equatable, Sendable {
    public let name: String
    public let question: String
    public let spans: [GroundedSpanInput]
    public let expectsRefusal: Bool

    public init(name: String, question: String, spans: [GroundedSpanInput], expectsRefusal: Bool) {
        self.name = name
        self.question = question
        self.spans = spans
        self.expectsRefusal = expectsRefusal
    }
}

/// The tallied reliability of typed grounded generation over a fixture set — the input to the
/// typed-primary go/no-go. Rates are computed, not stored, so the raw counts stay auditable.
public struct CapabilityReport: Equatable, Sendable {
    public let total: Int
    /// Reached a clean validated-or-refused draft within the repair budget.
    public let generated: Int
    /// Of `generated`, those that succeeded on the very first model call.
    public let firstAttempt: Int
    /// Exhausted the repair budget without a clean draft.
    public let fellBack: Int
    /// Fixtures whose honest answer is a refusal.
    public let refusalExpected: Int
    /// Of `refusalExpected`, those the model correctly refused.
    public let refusalCorrect: Int
    /// Sum of attempts across `generated` cases (for the average).
    public let attemptsSum: Int

    public var successRate: Double { rate(generated) }
    public var firstAttemptRate: Double { rate(firstAttempt) }
    public var fallbackRate: Double { rate(fellBack) }
    public var avgAttempts: Double { generated == 0 ? 0 : Double(attemptsSum) / Double(generated) }
    public var refusalAccuracy: Double { refusalExpected == 0 ? 1 : Double(refusalCorrect) / Double(refusalExpected) }

    private func rate(_ n: Int) -> Double { total == 0 ? 0 : Double(n) / Double(total) }
}

/// Runs typed grounded generation over a fixture set and reports how reliably the local model
/// holds the AnswerDraft schema — the empirical input the SPEC's Phase 1 go/no-go needs
/// (P1-T0). The pure `report(from:)` aggregation is unit-tested; `run(...)` is invoked from the
/// app's Diagnostics with a loaded model so the number reflects the real on-device model.
public enum CapabilityHarness {
    /// Aggregates per-fixture outcomes into a report. Pure and deterministic.
    public static func report(
        from results: [(fixture: CapabilityFixture, outcome: TypedGroundedGenerator.Outcome)]
    ) -> CapabilityReport {
        var generated = 0, firstAttempt = 0, fellBack = 0
        var refusalExpected = 0, refusalCorrect = 0, attemptsSum = 0
        for (fixture, outcome) in results {
            if fixture.expectsRefusal { refusalExpected += 1 }
            switch outcome {
            case let .generated(result):
                generated += 1
                attemptsSum += result.attempts
                if result.attempts == 1 { firstAttempt += 1 }
                if fixture.expectsRefusal, result.validation.status == .refused { refusalCorrect += 1 }
            case .fallback:
                fellBack += 1
            }
        }
        return CapabilityReport(
            total: results.count, generated: generated, firstAttempt: firstAttempt,
            fellBack: fellBack, refusalExpected: refusalExpected, refusalCorrect: refusalCorrect,
            attemptsSum: attemptsSum
        )
    }

    /// Runs every fixture through `TypedGroundedGenerator` against the supplied (loaded) model
    /// runtime and returns the aggregate report.
    public static func run(
        fixtures: [CapabilityFixture],
        modelID: ModelID,
        options: GenerationOptions,
        systemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol,
        maxRepairs: Int = 2
    ) async -> CapabilityReport {
        var results: [(CapabilityFixture, TypedGroundedGenerator.Outcome)] = []
        for fixture in fixtures {
            let outcome = await TypedGroundedGenerator.generate(
                question: fixture.question, spans: fixture.spans, modelID: modelID,
                options: options, systemPrompt: systemPrompt, runtimeClient: runtimeClient,
                maxRepairs: maxRepairs
            )
            results.append((fixture, outcome))
        }
        return report(from: results)
    }

    /// A small, synthetic-but-realistic frozen fixture set covering answerable (single- and
    /// multi-source) and not-answerable cases. Synthetic text only — no client data — so the
    /// harness measures schema-holding on realistic grounded inputs.
    public static func standardFixtures() -> [CapabilityFixture] {
        [
            CapabilityFixture(
                name: "single-source-fact",
                question: "When was the agreement signed?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "cap/agreement",
                                          text: "This Services Agreement was executed on March 3, 2024 by both parties.",
                                          lowConfidence: false)],
                expectsRefusal: false
            ),
            CapabilityFixture(
                name: "multi-source-fact",
                question: "What is the fee and when is it due?",
                spans: [
                    GroundedSpanInput(label: "S1", sourceID: "cap/fee", text: "The engagement fee is $9,000.", lowConfidence: false),
                    GroundedSpanInput(label: "S2", sourceID: "cap/due", text: "Payment is due no later than April 15, 2025.", lowConfidence: false),
                ],
                expectsRefusal: false
            ),
            CapabilityFixture(
                name: "not-answerable",
                question: "What are the addresses of the parties?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "cap/scope",
                                          text: "This Agreement governs the scope of services and the fee schedule.",
                                          lowConfidence: false)],
                expectsRefusal: true
            ),
        ]
    }
}
