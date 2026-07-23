import Foundation
import SupraCore
@testable import SupraSessions
import XCTest

/// Measurement-qualification gate for the typed-vs-prose A/B pilot (review finding #3):
/// the pilot may not run or publish while correctness is decided by `expectedFact`
/// substring containment, which
///
/// - scores "The engagement fee was not $9,000; it was $12,000." CORRECT for an
///   expected "$9,000" (wrong through negation),
/// - scores "The engagement fee was nine thousand dollars." WRONG for the same
///   expectation (correct paraphrase rejected), and
/// - scores "Beta Corp. paid the invoice on May 1, 2024." CORRECT for a fixture whose
///   actor is Alpha LLC (wrong actor, matching date).
///
/// Correctness is replaced by TYPED expected fields (`TypedProseExpectedAnswer`:
/// money / date / actor / word-bounded terms). Correct requires every requested field
/// affirmatively present; negated sentences never satisfy a field; for value-typed
/// fields (money, date) the answer's affirmative value set must equal exactly the
/// expected value — contradictions and unsupported additions fail closed. Substring
/// containment survives only as the honestly named diagnostic
/// `containsExpectedLiteral`, which no correctness decision consumes.
///
/// Expected RED for this file: `TypedProseExpectedAnswer` and the typed
/// `TypedProseABOutcome.expected` field do not exist, so the file does not compile.
/// The three defect demonstrations above were additionally OBSERVED against the old
/// scorer on the parent commit (recorded in the RED commit message).
final class TypedProseScorerQualificationTests: XCTestCase {

    private func outcome(
        answer: String,
        expected: TypedProseExpectedAnswer?,
        expectsRefusal: Bool = false,
        flagged: Bool = false
    ) -> TypedProseABOutcome {
        TypedProseABOutcome(
            fixtureName: "qualification",
            arm: .typed,
            answer: answer,
            requiresReview: flagged,
            warnings: [],
            expectsRefusal: expectsRefusal,
            expected: expected,
            fellBack: false
        )
    }

    // MARK: - The review's three disqualifying cases

    /// T-MQ-01. Wrong through negation: the expected value appears only inside a
    /// negated clause, and the answer affirms a DIFFERENT value.
    func testNegatedExpectedMoneyIsNotCorrect() {
        let scored = TypedProseABScorer.isCorrect(outcome(
            answer: "The engagement fee was not $9,000; it was $12,000 [S1].",
            expected: TypedProseExpectedAnswer(money: 9_000)
        ))
        XCTAssertFalse(scored, "a negated mention of the expected value is not a correct answer")
    }

    /// T-MQ-02. Correct paraphrase: the value stated in words is the same money.
    func testParaphrasedMoneyIsCorrect() {
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee was nine thousand dollars [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "typed money must accept a numerically identical paraphrase"
        )
    }

    /// T-MQ-03. Wrong actor, matching date: the date alone must not carry the answer
    /// when the fixture requests the actor too.
    func testWrongActorWithMatchingDateIsNotCorrect() {
        let expected = TypedProseExpectedAnswer(
            date: TypedProseExpectedAnswer.Day(year: 2024, month: 5, day: 1),
            actor: "Alpha LLC"
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "Beta Corp. paid the invoice on May 1, 2024 [S1].",
                expected: expected
            )),
            "every requested field must be satisfied — a matching date with the wrong actor fails"
        )
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "Alpha LLC paid the invoice in full on May 1, 2024 [S1].",
                expected: expected
            ))
        )
    }

    /// T-MQ-03A. Individually matching fields in different propositions cannot be
    /// assembled into a correct answer. The actor must own the dated event.
    func testRequestedFieldsMustBelongToTheSameProposition() {
        let expected = TypedProseExpectedAnswer(
            date: TypedProseExpectedAnswer.Day(year: 2024, month: 5, day: 1),
            actor: "Alpha LLC"
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "Alpha LLC appears in the file. Beta Corp. paid the invoice on May 1, 2024 [S1].",
                expected: expected
            )),
            "the scorer must not bind the date in Beta Corp.'s proposition to Alpha LLC"
        )
    }

    // MARK: - Contradictions and unsupported additions fail closed

    /// T-MQ-04. An answer that affirms the expected value AND a competing value of the
    /// same type contradicts itself; it is not correct.
    func testContradictoryAffirmativeMoneyIsNotCorrect() {
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is $9,000 [S1]. The engagement fee is $12,000 [S2].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            ))
        )
    }

    /// T-MQ-05. Every typed value must be authorized by the fixture, even when that
    /// value's type was not requested. Incidental evidence-backed detail is permitted
    /// only when the fixture enumerates it.
    func testUnsupportedAdditionOfAnyTypedValueFailsClosed() {
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The agreement was signed on March 3, 2024 and again on June 9, 2025 [S1].",
                expected: TypedProseExpectedAnswer(date: TypedProseExpectedAnswer.Day(year: 2024, month: 3, day: 3))
            )),
            "an invented second value of the requested type is an unsupported addition"
        )
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is $9,000, due no later than April 15, 2025 [S1] [S2].",
                expected: TypedProseExpectedAnswer(
                    money: 9_000,
                    allowedDates: [TypedProseExpectedAnswer.Day(year: 2025, month: 4, day: 15)]
                )
            )),
            "an enumerated incidental value remains valid"
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is $9,000, due June 9, 2025 [S1].",
                expected: TypedProseExpectedAnswer(
                    money: 9_000,
                    allowedDates: [TypedProseExpectedAnswer.Day(year: 2025, month: 4, day: 15)]
                )
            )),
            "an invented value of an unrequested type must fail closed"
        )
    }

    // MARK: - Format variants of typed values

    /// T-MQ-06. Dates are compared as dates, not strings: ISO, slash, and long-form
    /// notation all satisfy the same expected day, and a different day never does.
    func testDateFormatVariantsAreEquivalent() {
        let expected = TypedProseExpectedAnswer(date: TypedProseExpectedAnswer.Day(year: 2024, month: 5, day: 1))
        for answer in [
            "The invoice was paid on 2024-05-01 [S1].",
            "The invoice was paid on 5/1/2024 [S1].",
            "The invoice was paid on May 1st, 2024 [S1].",
        ] {
            XCTAssertTrue(
                TypedProseABScorer.isCorrect(outcome(answer: answer, expected: expected)),
                "notation must not decide correctness: \(answer)"
            )
        }
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The invoice was paid on May 2, 2024 [S1].",
                expected: expected
            ))
        )
    }

    /// T-MQ-07. Money is compared as an amount: symbol, word, and decimal forms all
    /// satisfy 9000, and a different amount never does.
    func testMoneyFormatVariantsAreEquivalent() {
        let expected = TypedProseExpectedAnswer(money: 9_000)
        for answer in [
            "The fee is $9,000 [S1].",
            "The fee is $9,000.00 [S1].",
            "The fee is 9,000 dollars [S1].",
            "The fee is nine thousand dollars [S1].",
        ] {
            XCTAssertTrue(
                TypedProseABScorer.isCorrect(outcome(answer: answer, expected: expected)),
                "notation must not decide correctness: \(answer)"
            )
        }
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The fee is ninety thousand dollars [S1].",
                expected: expected
            ))
        )
    }

    // MARK: - Terms: word-bounded, negation-guarded, honestly limited

    /// T-MQ-08. A term is satisfied only word-bounded and only in a non-negated
    /// sentence. Terms measure term recall, not semantic correctness — the field
    /// documents that limit.
    func testTermsAreWordBoundedAndNegationGuarded() {
        let expected = TypedProseExpectedAnswer(terms: ["material"])
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "Relators must show the claim was false and material to payment [S1].",
                expected: expected
            ))
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The alleged misstatement was immaterial to payment [S1].",
                expected: expected
            )),
            "\"immaterial\" must not satisfy the word-bounded term \"material\""
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The misstatement was not material to payment [S1].",
                expected: expected
            )),
            "a negated sentence never satisfies a term"
        )
    }

    // MARK: - Refusal rule survives the scorer replacement

    /// T-MQ-09. Refusing an answerable fixture stays a wrong answer, so a
    /// refuse-everything model can never post a perfect scorecard; refusing a
    /// not-answerable fixture stays correct.
    func testRefuseEverythingStillCannotScorePerfectly() {
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: DocumentQAPromptBuilder.unsupportedAnswerReply,
                expected: TypedProseExpectedAnswer(money: 9_000)
            ))
        )
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: DocumentQAPromptBuilder.unsupportedAnswerReply,
                expected: nil,
                expectsRefusal: true
            ))
        )
    }

    // MARK: - The renamed diagnostic

    /// T-MQ-10. Substring containment survives only as `containsExpectedLiteral`, and
    /// it is demonstrably NOT correctness: it accepts the negation case the typed
    /// scorer rejects.
    func testContainsExpectedLiteralIsADiagnosticNotCorrectness() {
        let negated = "The engagement fee was not $9,000; it was $12,000 [S1]."
        XCTAssertTrue(TypedProseABScorer.containsExpectedLiteral(negated, literal: "$9,000"))
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: negated,
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "the diagnostic and the correctness decision must be allowed to disagree"
        )
    }

    // MARK: - Contrastive negation scope (review follow-up)

    /// T-MQ-13. A correct contrastive answer states the expected value and denies the
    /// competitor in one sentence: "The fee is $9,000, not $12,000." The whole-sentence
    /// negation rule scores it WRONG (the sentence contains "not", so its $9,000 is
    /// never affirmative), which understates verifier noise — the very metric the
    /// pilot publishes.
    ///
    /// Expected RED: both contrastive forms score `isCorrect == false` because
    /// `isNegated` classifies the entire sentence by token presence.
    func testContrastiveDenialOfTheCompetitorIsCorrect() {
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is $9,000, not $12,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "denying the competing value must not erase the affirmative statement of the expected value"
        )
        XCTAssertTrue(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is not $12,000, but $9,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "the reverse contrastive form affirms the value after \"but\""
        )
    }

    /// T-MQ-13A. The contrastive refinement must stay fail-closed: a sentence that
    /// only DENIES the expected value never becomes correct, in either clause
    /// position, and the denied competitor never counts as a contradiction the
    /// answer must not have made.
    ///
    /// Expected RED: none — these guard assertions already hold and must survive the
    /// contrastive change; they are committed with T-MQ-13 so the GREEN cannot
    /// overshoot into treating denial as affirmation.
    func testContrastiveRefinementStaysFailClosed() {
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is not $9,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "a bare denial of the expected value is not an answer"
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is $12,000, not $9,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "affirming the competitor while denying the expected value is wrong"
        )
        XCTAssertFalse(
            TypedProseABScorer.isCorrect(outcome(
                answer: "The engagement fee is not $9,000, not even close [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            )),
            "stacked denials must not resolve to an affirmative head"
        )
    }

    // MARK: - Artifact schema enforcement (review follow-up)

    /// T-MQ-14. A schema version that is merely RECORDED protects nothing: an
    /// artifact produced under old scoring semantics decodes silently and re-scores
    /// under the new semantics with no mismatch signal. Decoding must refuse any
    /// artifact whose schema is not the current one.
    ///
    /// Expected RED: synthesized `Codable` decodes a `schemaVersion: 2` artifact
    /// without complaint, so `XCTAssertThrowsError` fails.
    func testDecodingRefusesAnArtifactFromAnotherSchema() throws {
        let outcomes = [
            outcome(
                answer: "The engagement fee is $9,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            ),
        ]
        let record = TypedProseABRunRecord(
            outcomes: outcomes,
            typed: TypedProseABScorer.report(outcomes: outcomes, arm: .typed),
            prose: TypedProseABScorer.report(outcomes: outcomes, arm: .prose)
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = TypedProseABRunRecord.currentSchemaVersion - 1
        let stale = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(TypedProseABRunRecord.self, from: stale),
            "an artifact recorded under different scoring semantics must not silently re-score"
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("schema refusal must be a decoding error, got \(error)")
            }
        }
    }

    // MARK: - Fixtures and raw-output record

    /// T-MQ-11. Every answerable standard fixture carries a typed expectation (no
    /// fixture may fall back to literal matching), and refusal fixtures carry none.
    func testStandardFixturesCarryTypedExpectations() {
        for fixture in TypedProseABProbe.standardFixtures() {
            if fixture.expectsRefusal {
                XCTAssertNil(fixture.expected, "\(fixture.name): a refusal fixture has no expected answer")
            } else {
                let expected = fixture.expected
                XCTAssertNotNil(expected, "\(fixture.name): answerable fixtures must carry typed expectations")
                let hasField = expected.map {
                    $0.money != nil || $0.date != nil || $0.actor != nil || !$0.terms.isEmpty
                } ?? false
                XCTAssertTrue(hasField, "\(fixture.name): a typed expectation must request at least one field")
            }
        }
    }

    /// T-MQ-12. The run record retains raw outputs and round-trips losslessly, so a
    /// published measurement can be independently re-scored from its own artifact.
    func testRunRecordRetainsRawOutputsAndRoundTrips() throws {
        XCTAssertEqual(
            TypedProseABRunRecord.currentSchemaVersion, 3,
            "a scoring-semantics change (contrastive negation scope) requires a new artifact schema"
        )
        let outcomes = [
            outcome(
                answer: "The engagement fee is $9,000 [S1].",
                expected: TypedProseExpectedAnswer(money: 9_000)
            ),
        ]
        let record = TypedProseABRunRecord(
            outcomes: outcomes,
            typed: TypedProseABScorer.report(outcomes: outcomes, arm: .typed),
            prose: TypedProseABScorer.report(outcomes: outcomes, arm: .prose)
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TypedProseABRunRecord.self, from: encoded)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.outcomes.first?.answer, "The engagement fee is $9,000 [S1].")
        // Re-scoring the retained outcomes must reproduce the recorded report.
        XCTAssertEqual(
            TypedProseABScorer.report(outcomes: decoded.outcomes, arm: .typed),
            record.typed
        )
    }
}
