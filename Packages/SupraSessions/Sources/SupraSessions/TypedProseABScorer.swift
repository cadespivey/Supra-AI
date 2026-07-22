import Foundation
import SupraCore
import SupraDocuments

/// Which grounded-answer path produced an outcome.
public enum TypedProseArm: String, Sendable, Equatable, Codable {
    /// `TypedGroundedGenerator` → `AnswerDraftRenderer`.
    case typed
    /// The streamed prose path: `DocumentQAPromptBuilder` → normalize → reasoning-strip.
    case prose
}

/// One scored (fixture, arm) result. Everything needed to classify it, and nothing that
/// identifies a real matter — the pilot runs on authored fixtures only.
public struct TypedProseABOutcome: Sendable, Equatable, Codable {
    public let fixtureName: String
    public let arm: TypedProseArm
    public let answer: String
    /// `DocumentSupportReport.requiresReview` for this answer.
    public let requiresReview: Bool
    public let warnings: [String]
    /// True when the fixture's honest answer is a refusal.
    public let expectsRefusal: Bool
    /// The fact a correct answer must state, for an answerable fixture. Nil when `expectsRefusal`.
    public let expectedFact: String?
    /// True when the path failed and degraded (typed fallback, or a failed generation).
    public let fellBack: Bool

    public init(
        fixtureName: String,
        arm: TypedProseArm,
        answer: String,
        requiresReview: Bool,
        warnings: [String],
        expectsRefusal: Bool,
        expectedFact: String?,
        fellBack: Bool
    ) {
        self.fixtureName = fixtureName
        self.arm = arm
        self.answer = answer
        self.requiresReview = requiresReview
        self.warnings = warnings
        self.expectsRefusal = expectsRefusal
        self.expectedFact = expectedFact
        self.fellBack = fellBack
    }
}

/// The 2x2 cell an outcome falls into.
public enum TypedProseABCell: String, Sendable, Equatable, Codable {
    /// Correct answer, verifier flagged it — the noise this pilot measures.
    case falsePositive
    /// Wrong answer, verifier flagged it — the gate working.
    case truePositive
    /// Wrong answer, verifier stayed quiet — worse than noise.
    case missedError
    /// Correct answer, verifier stayed quiet.
    case trueNegative
}

/// Per-arm tally.
public struct TypedProseABReport: Sendable, Equatable, Codable {
    public let arm: TypedProseArm
    public let total: Int
    public let correct: Int
    public let falsePositives: Int
    public let truePositives: Int
    public let missedErrors: Int
    public let trueNegatives: Int
    public let fellBack: Int

    /// The headline: of the answers that were RIGHT, how many did the verifier flag anyway.
    ///
    /// Denominator is `correct`, not `total`, deliberately. Over all fixtures a path that answers
    /// badly would look quiet, since wrong answers draw true positives rather than false ones.
    public var falsePositiveRate: Double { correct == 0 ? 0 : Double(falsePositives) / Double(correct) }
    /// Of the answers that were WRONG, how many slipped past the verifier.
    public var missedErrorRate: Double {
        let wrong = truePositives + missedErrors
        return wrong == 0 ? 0 : Double(missedErrors) / Double(wrong)
    }
    public var correctRate: Double { total == 0 ? 0 : Double(correct) / Double(total) }
}

/// Scores typed-vs-prose pilot outcomes.
///
/// Pure and model-free, so the arithmetic that decides the pilot is unit-tested independently of
/// any generation run. The measurement it protects is the distinction between the verifier being
/// NOISY (flagging correct answers) and the verifier WORKING (flagging wrong ones) — a raw
/// `requiresReview` rate conflates the two, and a divergence tally between the paths sees neither.
public enum TypedProseABScorer {

    /// Whether the answer is the one the fixture calls for.
    ///
    /// A refusal is correct only on a not-answerable fixture. Refusing an answerable question is a
    /// WRONG answer — without that rule a model that refuses everything posts a perfect,
    /// unflagged scorecard.
    public static func isCorrect(_ outcome: TypedProseABOutcome) -> Bool {
        if outcome.fellBack { return false }
        let refused = RefusalContract.isRefusal(outcome.answer)
        if outcome.expectsRefusal { return refused }
        if refused { return false }
        guard let fact = outcome.expectedFact, !fact.isEmpty else { return false }
        return outcome.answer.localizedCaseInsensitiveContains(fact)
    }

    public static func classify(_ outcome: TypedProseABOutcome) -> TypedProseABCell {
        switch (isCorrect(outcome), outcome.requiresReview) {
        case (true, true): return .falsePositive
        case (false, true): return .truePositive
        case (false, false): return .missedError
        case (true, false): return .trueNegative
        }
    }

    /// Folds outcomes for ONE arm into a report. Outcomes from other arms are filtered out — the
    /// comparison is paired per fixture, so a mixed report would be meaningless.
    public static func report(outcomes: [TypedProseABOutcome], arm: TypedProseArm) -> TypedProseABReport {
        let mine = outcomes.filter { $0.arm == arm }
        var falsePositives = 0, truePositives = 0, missedErrors = 0, trueNegatives = 0
        for outcome in mine {
            switch classify(outcome) {
            case .falsePositive: falsePositives += 1
            case .truePositive: truePositives += 1
            case .missedError: missedErrors += 1
            case .trueNegative: trueNegatives += 1
            }
        }
        return TypedProseABReport(
            arm: arm,
            total: mine.count,
            correct: falsePositives + trueNegatives,
            falsePositives: falsePositives,
            truePositives: truePositives,
            missedErrors: missedErrors,
            trueNegatives: trueNegatives,
            fellBack: mine.filter(\.fellBack).count
        )
    }
}
