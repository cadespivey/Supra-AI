import Foundation
import SupraCore
@testable import SupraSessions
import XCTest

/// The typed-vs-prose pilot scores each (fixture, arm) into a 2x2: was the answer correct, and
/// did the verifier flag it. Only that table separates the number we care about — the verifier's
/// FALSE-POSITIVE rate on correct answers — from the number it is easily confused with, the raw
/// `requiresReview` rate.
///
/// Expected RED for this whole file: `TypedProseABScorer` and its types do not exist.
///
/// The behavioral RED each case pins is recorded per test: these reject specific WRONG scorers,
/// not merely the absence of one. Every fixture here is synthetic — the pilot never reads real
/// matter data.
final class TypedProseABScorerTests: XCTestCase {

    private func outcome(
        arm: TypedProseArm = .typed,
        fixture: String = "f1",
        answer: String,
        flagged: Bool,
        expectsRefusal: Bool = false,
        expectedFact: String? = "March 3, 2024"
    ) -> TypedProseABOutcome {
        TypedProseABOutcome(
            fixtureName: fixture,
            arm: arm,
            answer: answer,
            requiresReview: flagged,
            warnings: [],
            expectsRefusal: expectsRefusal,
            expectedFact: expectedFact,
            fellBack: false
        )
    }

    // MARK: - The 2x2 itself

    /// T-AB-01. A CORRECT answer that the verifier flagged is a false positive — the noise this
    /// pilot exists to measure.
    ///
    /// Behavioral RED: a scorer that reports `requiresReview` directly would call this "flagged"
    /// and stop, losing the distinction between noise and a real catch.
    func testCorrectAnswerFlaggedIsAFalsePositive() {
        let scored = TypedProseABScorer.classify(
            outcome(answer: "The agreement was signed on March 3, 2024 [S1].", flagged: true)
        )
        XCTAssertEqual(scored, .falsePositive)
    }

    /// T-AB-02. A WRONG answer that the verifier flagged is a TRUE positive — the gate working.
    /// A scorer that counts all flags as noise would wrongly reward a path for being un-flagged.
    func testWrongAnswerFlaggedIsATruePositive() {
        let scored = TypedProseABScorer.classify(
            outcome(answer: "The agreement was signed on January 9, 1999 [S1].", flagged: true)
        )
        XCTAssertEqual(scored, .truePositive)
    }

    /// T-AB-03. A WRONG answer the verifier did NOT flag is a missed error — strictly worse than
    /// a false positive, and invisible to any divergence-only comparison.
    func testWrongAnswerUnflaggedIsAMissedError() {
        let scored = TypedProseABScorer.classify(
            outcome(answer: "The agreement was signed on January 9, 1999 [S1].", flagged: false)
        )
        XCTAssertEqual(scored, .missedError)
    }

    func testCorrectAnswerUnflaggedIsATrueNegative() {
        let scored = TypedProseABScorer.classify(
            outcome(answer: "The agreement was signed on March 3, 2024 [S1].", flagged: false)
        )
        XCTAssertEqual(scored, .trueNegative)
    }

    // MARK: - The refusal confound

    /// T-AB-04. On a not-answerable fixture, refusing IS the correct answer.
    func testRefusalOnNotAnswerableFixtureCountsAsCorrect() {
        let scored = TypedProseABScorer.classify(
            outcome(
                answer: DocumentQAPromptBuilder.unsupportedAnswerReply,
                flagged: false,
                expectsRefusal: true,
                expectedFact: nil
            )
        )
        XCTAssertEqual(scored, .trueNegative)
    }

    /// T-AB-05. The confound the reviewer flagged: a model that refuses EVERYTHING must not score
    /// as perfect. Refusing an answerable fixture is a wrong answer, so an unflagged refusal is a
    /// missed error — not a clean result.
    ///
    /// Behavioral RED: a scorer keyed only on `requiresReview` rates would show 0% flags for a
    /// refuse-everything model and declare it the winner.
    func testRefusingAnAnswerableFixtureIsNotClean() {
        let scored = TypedProseABScorer.classify(
            outcome(
                answer: DocumentQAPromptBuilder.unsupportedAnswerReply,
                flagged: false,
                expectsRefusal: false,
                expectedFact: "March 3, 2024"
            )
        )
        XCTAssertEqual(scored, .missedError, "a refusal on an answerable question is a wrong answer")
    }

    // MARK: - Aggregation

    /// T-AB-06. The report must express the false-positive rate over CORRECT answers only —
    /// dividing by all fixtures would let a path with many wrong answers look quiet.
    ///
    /// Two correct answers, one flagged → 50%. One wrong answer, flagged, must not enter the
    /// denominator.
    func testFalsePositiveRateIsOverCorrectAnswersOnly() {
        let report = TypedProseABScorer.report(outcomes: [
            outcome(fixture: "a", answer: "Signed March 3, 2024 [S1].", flagged: true),
            outcome(fixture: "b", answer: "Signed March 3, 2024 [S1].", flagged: false),
            outcome(fixture: "c", answer: "Signed January 9, 1999 [S1].", flagged: true),
        ], arm: .typed)

        XCTAssertEqual(report.correct, 2)
        XCTAssertEqual(report.falsePositives, 1)
        XCTAssertEqual(report.falsePositiveRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.truePositives, 1)
        XCTAssertEqual(report.missedErrors, 0)
    }

    /// T-AB-07. A fallback (typed generation failed and the path degraded) must be counted and
    /// must NOT silently become a clean result — otherwise a path that always falls back looks
    /// flawless.
    func testFallbacksAreCountedAndNotTreatedAsClean() {
        var fell = outcome(answer: "", flagged: false)
        fell = TypedProseABOutcome(
            fixtureName: fell.fixtureName, arm: fell.arm, answer: fell.answer,
            requiresReview: fell.requiresReview, warnings: fell.warnings,
            expectsRefusal: fell.expectsRefusal, expectedFact: fell.expectedFact,
            fellBack: true
        )
        let report = TypedProseABScorer.report(outcomes: [fell], arm: .typed)

        XCTAssertEqual(report.fellBack, 1)
        XCTAssertEqual(report.correct, 0, "a fallback produced no correct answer")
        XCTAssertEqual(report.falsePositiveRate, 0, "no correct answers means no FP rate to report")
    }

    /// T-AB-08. The comparison is paired per fixture, so the arms must be scored over the SAME
    /// fixture set. A report mixing arms is meaningless.
    func testReportFiltersToItsOwnArm() {
        let report = TypedProseABScorer.report(outcomes: [
            outcome(arm: .typed, fixture: "a", answer: "Signed March 3, 2024 [S1].", flagged: true),
            outcome(arm: .prose, fixture: "a", answer: "Signed March 3, 2024 [S1].", flagged: false),
        ], arm: .prose)

        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.falsePositives, 0)
    }
}
