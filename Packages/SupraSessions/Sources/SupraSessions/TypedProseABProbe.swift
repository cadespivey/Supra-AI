import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface

/// One authored A/B case: a question, the evidence a grounded turn would have retrieved, and the
/// ground truth needed to score the answer.
///
/// SYNTHETIC ONLY. The pilot never reads real matter data, which is also what makes the 2x2
/// possible: because the evidence is authored, the correct answer is known, so a verifier flag can
/// be classified as noise or as a real catch rather than merely counted.
public struct TypedProseABFixture: Sendable, Equatable {
    public let name: String
    public let question: String
    public let spans: [GroundedSpanInput]
    /// The typed ground truth a correct answer must state (never a literal to
    /// substring-match). Nil when the honest answer is a refusal.
    public let expected: TypedProseExpectedAnswer?
    public let expectsRefusal: Bool

    public init(
        name: String,
        question: String,
        spans: [GroundedSpanInput],
        expected: TypedProseExpectedAnswer?,
        expectsRefusal: Bool
    ) {
        self.name = name
        self.question = question
        self.spans = spans
        self.expected = expected
        self.expectsRefusal = expectsRefusal
    }
}

/// Runs both grounded-answer paths over the same authored fixtures and verifies each result with
/// the production `DocumentSupportVerifier`, so the typed path's effect on verifier noise can be
/// measured rather than argued.
///
/// Both arms receive the SAME spans, model, and options — the comparison is otherwise worthless.
/// Scoring lives in `TypedProseABScorer` and is unit-tested without a model.
public enum TypedProseABProbe {

    /// The authored fixture set.
    ///
    /// The first three mirror `CapabilityHarness.standardFixtures()` so the two probes agree on
    /// basic grounded behavior. The rest are written in the register where the verifier has
    /// historically produced false positives on correct answers: hedged phrasing, a quoted
    /// instruction-shaped line, and legal prose whose wording collides with the verifier's own
    /// heuristics. All content is invented.
    public static func standardFixtures() -> [TypedProseABFixture] {
        [
            TypedProseABFixture(
                name: "single-source-fact",
                question: "When was the agreement signed?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/agreement",
                                          text: "This Services Agreement was executed on March 3, 2024 by both parties.",
                                          lowConfidence: false)],
                expected: TypedProseExpectedAnswer(
                    date: TypedProseExpectedAnswer.Day(year: 2024, month: 3, day: 3)
                ),
                expectsRefusal: false
            ),
            TypedProseABFixture(
                name: "multi-source-fact",
                question: "What is the fee?",
                spans: [
                    GroundedSpanInput(label: "S1", sourceID: "ab/fee", text: "The engagement fee is $9,000.", lowConfidence: false),
                    GroundedSpanInput(label: "S2", sourceID: "ab/due", text: "Payment is due no later than April 15, 2025.", lowConfidence: false),
                ],
                expected: TypedProseExpectedAnswer(money: 9_000),
                expectsRefusal: false
            ),
            TypedProseABFixture(
                name: "not-answerable",
                question: "What are the addresses of the parties?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/scope",
                                          text: "This Agreement governs the scope of services and the fee schedule.",
                                          lowConfidence: false)],
                expected: nil,
                expectsRefusal: true
            ),
            // The verifier's false positives cluster on answers whose SOURCE prose collides with
            // its heuristics. "the claim was false" is False Claims Act boilerplate.
            TypedProseABFixture(
                name: "fca-phrasing",
                question: "What must relators show?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/fca",
                                          text: "Relators must show the claim was false and material to payment.",
                                          lowConfidence: false)],
                // Terms-only expectation: measures term recall on a rule-style
                // answer, not semantic correctness (the field's documented limit).
                expected: TypedProseExpectedAnswer(terms: ["false", "material"]),
                expectsRefusal: false
            ),
            TypedProseABFixture(
                name: "quoted-notice",
                question: "What did the letter state?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/notice",
                                          text: "The letter stated: \"You are now in default under the Note.\"",
                                          lowConfidence: false)],
                expected: TypedProseExpectedAnswer(terms: ["default"]),
                expectsRefusal: false
            ),
            TypedProseABFixture(
                name: "date-and-actor",
                question: "Who paid the invoice and when?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/payment",
                                          text: "Alpha LLC paid the invoice in full on May 1, 2024.",
                                          lowConfidence: false)],
                expected: TypedProseExpectedAnswer(
                    date: TypedProseExpectedAnswer.Day(year: 2024, month: 5, day: 1),
                    actor: "Alpha LLC"
                ),
                expectsRefusal: false
            ),
            TypedProseABFixture(
                name: "second-not-answerable",
                question: "What was the interest rate on the note?",
                spans: [GroundedSpanInput(label: "S1", sourceID: "ab/note",
                                          text: "The Note was executed by the borrower and delivered to the lender.",
                                          lowConfidence: false)],
                expected: nil,
                expectsRefusal: true
            ),
        ]
    }

    /// Runs both arms over every fixture, `repeats` times each.
    ///
    /// Local generation samples, so a single pass over a handful of fixtures is mostly noise;
    /// `repeats` is how the caller buys enough observations for the rates to mean anything.
    public static func run(
        fixtures: [TypedProseABFixture] = standardFixtures(),
        modelID: ModelID,
        options: GenerationOptions,
        systemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol,
        repeats: Int = 1
    ) async -> [TypedProseABOutcome] {
        var outcomes: [TypedProseABOutcome] = []
        for _ in 0..<max(1, repeats) {
            for fixture in fixtures {
                outcomes.append(await runTyped(fixture, modelID: modelID, options: options,
                                               systemPrompt: systemPrompt, runtimeClient: runtimeClient))
                outcomes.append(await runProse(fixture, modelID: modelID, options: options,
                                               systemPrompt: systemPrompt, runtimeClient: runtimeClient))
            }
        }
        return outcomes
    }

    // MARK: - Arms

    private static func runTyped(
        _ fixture: TypedProseABFixture,
        modelID: ModelID,
        options: GenerationOptions,
        systemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol
    ) async -> TypedProseABOutcome {
        let outcome = await TypedGroundedGenerator.generate(
            question: fixture.question,
            spans: fixture.spans,
            modelID: modelID,
            options: options,
            systemPrompt: systemPrompt,
            runtimeClient: runtimeClient
        )
        switch outcome {
        case let .generated(result):
            let labels = Dictionary(fixture.spans.map { (SpanID($0.sourceID), $0.label) },
                                    uniquingKeysWith: { first, _ in first })
            let rendered = AnswerDraftRenderer.render(result.draft, labelForSpanID: labels)
            return verified(fixture, arm: .typed, answer: rendered, fellBack: false)
        case .fallback:
            return TypedProseABOutcome(
                fixtureName: fixture.name, arm: .typed, answer: "", requiresReview: true,
                warnings: ["typed generation fell back"], expectsRefusal: fixture.expectsRefusal,
                expected: fixture.expected, fellBack: true
            )
        }
    }

    /// Reproduces the production prose path's post-processing ORDER: normalize citation markers,
    /// then strip the reasoning trace, then verify. Reordering these changes the result — the
    /// reasoning strip exists precisely so chain-of-thought is not mined as uncited propositions.
    private static func runProse(
        _ fixture: TypedProseABFixture,
        modelID: ModelID,
        options: GenerationOptions,
        systemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol
    ) async -> TypedProseABOutcome {
        let prompt = DocumentQAPromptBuilder.buildQAPrompt(
            question: fixture.question,
            sources: fixture.spans.map(groundingSource),
            mode: .short
        )
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID,
            prompt: prompt, systemPrompt: systemPrompt, options: options
        )
        guard let raw = try? await runtimeClient.collectGeneratedText(request) else {
            return TypedProseABOutcome(
                fixtureName: fixture.name, arm: .prose, answer: "", requiresReview: true,
                warnings: ["generation failed"], expectsRefusal: fixture.expectsRefusal,
                expected: fixture.expected, fellBack: true
            )
        }
        let answer = ReasoningContent.answer(from: CitationNormalizer.normalize(raw))
        return verified(fixture, arm: .prose, answer: answer, fellBack: false)
    }

    // MARK: - Shared verification

    /// Both arms are verified by the SAME production verifier over the SAME sources. Anything else
    /// would measure the harness rather than the paths.
    private static func verified(
        _ fixture: TypedProseABFixture,
        arm: TypedProseArm,
        answer: String,
        fellBack: Bool
    ) -> TypedProseABOutcome {
        let sources = fixture.spans.map {
            DocumentSupportSource(
                sourceID: $0.sourceID, label: $0.label,
                locator: "fixture", text: $0.text, lowConfidence: $0.lowConfidence
            )
        }
        let report = try? DocumentSupportVerifier.verify(
            answer: answer, sources: sources, scopeFullyIndexed: true
        )
        return TypedProseABOutcome(
            fixtureName: fixture.name,
            arm: arm,
            answer: answer,
            requiresReview: report?.requiresReview ?? true,
            warnings: report?.warnings ?? [],
            expectsRefusal: fixture.expectsRefusal,
            expected: fixture.expected,
            fellBack: fellBack
        )
    }

    private static func groundingSource(_ span: GroundedSpanInput) -> GroundingSource {
        GroundingSource(
            sourceID: span.sourceID,
            label: span.label,
            documentName: "fixture",
            locatorDisplay: "fixture",
            text: span.text,
            excerpt: span.text,
            lowConfidence: span.lowConfidence
        )
    }
}
