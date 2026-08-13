import Foundation
@testable import SupraTestKit
import XCTest

/// T-RAG-EVAL-01 freezes the hand-calculated retrieval and citation metric contract before
/// the current native control or any one-variable challenger is measured.
final class RAGMetricContractTests: XCTestCase {
    func testGradedRankingUsesHandCalculatedRecallNDCGAndReciprocalRank() throws {
        // T-RAG-EVAL-01 expected RED: the graded RAG ranking score and formula entry point
        // do not exist. Existing rankingRecall cannot calculate full-set recall, DCG, nDCG,
        // or reciprocal rank from graded judgments.
        let score = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: ["A": 3, "B": 2, "C": 1],
            ranked: [
                BenchmarkRankedItem(id: "X", score: 0.99),
                BenchmarkRankedItem(id: "B", score: 0.81),
                BenchmarkRankedItem(id: "A", score: 0.72),
            ],
            k: 3
        )

        let recall = try measured(score.recallAtK)
        XCTAssertEqual(recall, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertNotEqual(recall, 1, "two retrieved relevant rows must not imply complete evidence recall")
        XCTAssertEqual(score.recallAtK.numerator, 2)
        XCTAssertEqual(score.recallAtK.denominator, 3)

        XCTAssertEqual(try measured(score.fullEvidenceSetRecallAtK), 0)
        XCTAssertEqual(score.fullEvidenceSetRecallAtK.numerator, 0)
        XCTAssertEqual(score.fullEvidenceSetRecallAtK.denominator, 1)

        XCTAssertEqual(try measured(score.discountedCumulativeGainAtK), 5.392_789, accuracy: 0.000_001)
        XCTAssertEqual(try measured(score.idealDiscountedCumulativeGainAtK), 9.392_789, accuracy: 0.000_001)
        let normalized = try measured(score.normalizedDiscountedCumulativeGainAtK)
        XCTAssertEqual(normalized, 0.574_141, accuracy: 0.000_001)
        XCTAssertNotEqual(normalized, 1, "nonideal order must not receive ideal ranking credit")

        XCTAssertEqual(try measured(score.reciprocalRankAtK), 0.5, accuracy: 0.000_001)
    }

    func testRankingStabilizesTiesAndCollapsesDuplicatesBeforeK() throws {
        // T-RAG-EVAL-01 expected RED: the complete RAG ranking contract is absent, including
        // duplicate collapse before K and the score-descending/ID-ascending tie rule.
        let tied = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: ["B": 1],
            ranked: [
                BenchmarkRankedItem(id: "B", score: 0.75),
                BenchmarkRankedItem(id: "A", score: 0.75),
            ],
            k: 1
        )
        XCTAssertEqual(try measured(tied.recallAtK), 0, "A must win the stable equal-score tie")
        XCTAssertEqual(try measured(tied.reciprocalRankAtK), 0)

        let deduplicated = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: ["A": 2, "B": 1],
            ranked: [
                BenchmarkRankedItem(id: "A", score: 0.90),
                BenchmarkRankedItem(id: "A", score: 0.80),
                BenchmarkRankedItem(id: "B", score: 0.70),
            ],
            k: 2
        )
        XCTAssertEqual(try measured(deduplicated.recallAtK), 1)
        XCTAssertEqual(try measured(deduplicated.fullEvidenceSetRecallAtK), 1)

        let boundary = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: ["A": 2, "B": 1],
            ranked: [
                BenchmarkRankedItem(id: "A", score: 0.90),
                BenchmarkRankedItem(id: "A", score: 0.80),
                BenchmarkRankedItem(id: "B", score: 0.70),
            ],
            k: 1
        )
        XCTAssertEqual(try measured(boundary.recallAtK), 0.5)
        XCTAssertEqual(try measured(boundary.fullEvidenceSetRecallAtK), 0)
    }

    func testRankingEmptyGoldenAndInvalidKAreExplicitlyNotApplicable() throws {
        // T-RAG-EVAL-01 expected RED: the RAG ranking result cannot yet make every undefined
        // metric explicitly N/A instead of silently perfect or zero.
        let empty = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: [:],
            ranked: [BenchmarkRankedItem(id: "X", score: 0.8)],
            k: 8
        )
        try assertRankingNotApplicable(empty, expectedReasonFragment: "relevant")

        let invalidK = BenchmarkMetrics.ragRankingScore(
            relevanceGrades: ["A": 1],
            ranked: [BenchmarkRankedItem(id: "A", score: 0.8)],
            k: 0
        )
        try assertRankingNotApplicable(invalidK, expectedReasonFragment: "positive")
    }

    func testContextAndCitationMetricsUseUniqueExactEvidenceEdges() throws {
        // T-RAG-EVAL-01 expected RED: RAG context scoring and exact claim/evidence citation
        // edges do not exist. Set-only scoring cannot express citation precision, recall,
        // and claim coverage independently.
        let context = BenchmarkMetrics.ragContextScore(
            relevantEvidenceIDs: Set(["A", "B", "C"]),
            packedEvidenceIDs: ["A", "A", "X"]
        )
        XCTAssertEqual(try measured(context.precision), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try measured(context.recall), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measured(context.f1), 0.4, accuracy: 0.000_001)

        let citation = BenchmarkMetrics.ragCitationScore(
            expectedEdges: Set([
                BenchmarkCitationEdge(claimID: "claim-1", evidenceID: "A"),
                BenchmarkCitationEdge(claimID: "claim-2", evidenceID: "B"),
                BenchmarkCitationEdge(claimID: "claim-3", evidenceID: "C"),
            ]),
            predictedEdges: [
                BenchmarkCitationEdge(claimID: "claim-1", evidenceID: "A"),
                BenchmarkCitationEdge(claimID: "claim-2", evidenceID: "X"),
                BenchmarkCitationEdge(claimID: "claim-2", evidenceID: "X"),
            ],
            claimIDsRequiringCitation: Set(["claim-1", "claim-2", "claim-3"])
        )
        XCTAssertEqual(try measured(citation.precision), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try measured(citation.recall), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try measured(citation.coverage), 2.0 / 3.0, accuracy: 0.000_001)

        let empty = BenchmarkMetrics.ragCitationScore(
            expectedEdges: [],
            predictedEdges: [],
            claimIDsRequiringCitation: []
        )
        XCTAssertEqual(empty.precision.status, .notApplicable)
        XCTAssertEqual(empty.recall.status, .notApplicable)
        XCTAssertEqual(empty.coverage.status, .notApplicable)
        XCTAssertNil(empty.precision.value, "empty citation precision must not silently become 100%")
        XCTAssertNil(empty.recall.value, "empty citation recall must not silently become 100%")
        XCTAssertNil(empty.coverage.value, "empty citation coverage must not silently become 100%")
    }

    func testZeroResultAccuracyChecksAnswerableAndNoAnswerQueries() throws {
        // T-RAG-EVAL-01 expected RED: zero-result observations and their accuracy metric do
        // not exist. Ordinary recall cannot score a correct empty result independently.
        let result = BenchmarkMetrics.zeroResultAccuracy([
            BenchmarkZeroResultObservation(
                expectedAnswerable: true,
                returnedEvidenceCount: 2,
                producedSupportedAnswer: true
            ),
            BenchmarkZeroResultObservation(
                expectedAnswerable: true,
                returnedEvidenceCount: 0,
                producedSupportedAnswer: false
            ),
            BenchmarkZeroResultObservation(
                expectedAnswerable: false,
                returnedEvidenceCount: 0,
                producedSupportedAnswer: false
            ),
            BenchmarkZeroResultObservation(
                expectedAnswerable: false,
                returnedEvidenceCount: 1,
                producedSupportedAnswer: true
            ),
        ])

        XCTAssertEqual(try measured(result), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.numerator, 2)
        XCTAssertEqual(result.denominator, 4)

        let empty = BenchmarkMetrics.zeroResultAccuracy([])
        XCTAssertEqual(empty.status, .notApplicable)
        XCTAssertNil(empty.value, "no observations must not silently become perfect accuracy")
        XCTAssertFalse(try XCTUnwrap(empty.reason).isEmpty)
    }

    private func measured(
        _ result: BenchmarkResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        XCTAssertEqual(result.status, .measured, file: file, line: line)
        return try XCTUnwrap(result.value, file: file, line: line)
    }

    private func assertRankingNotApplicable(
        _ result: BenchmarkRAGRankingScore,
        expectedReasonFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let metrics = [
            result.recallAtK,
            result.fullEvidenceSetRecallAtK,
            result.discountedCumulativeGainAtK,
            result.idealDiscountedCumulativeGainAtK,
            result.normalizedDiscountedCumulativeGainAtK,
            result.reciprocalRankAtK,
        ]
        for metric in metrics {
            XCTAssertEqual(metric.status, .notApplicable, file: file, line: line)
            XCTAssertNil(metric.value, file: file, line: line)
            XCTAssertTrue(
                try XCTUnwrap(metric.reason, file: file, line: line).contains(expectedReasonFragment),
                file: file,
                line: line
            )
        }
    }
}
