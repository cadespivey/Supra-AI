import Foundation
@testable import SupraDocuments
import XCTest

final class OCRCandidateSelectionTests: XCTestCase {
    func testTOCR01LongerLowConfidenceGarbledOCRCannotWin() throws {
        // T-OCR-01 expected RED: OCRCandidateSelection does not exist and the
        // shipping integration still chooses the longer candidate by length.
        let embedded = OCRCandidateSelection.RevisionCandidate(
            id: "embedded-payment-term",
            origin: .embeddedPDF,
            text: "PAYMENT DUE 30 DAYS"
        )
        let ocr = OCRCandidateSelection.RevisionCandidate(
            id: "ocr-longer-garbled",
            origin: .ocr,
            text: "@@@@ PAYMENT ??? DUE 30 DAYS ##### duplicated duplicated duplicated",
            confidence: 0.21,
            boundingBoxesJSON: boxesJSON([0.12, 0.18, 0.21])
        )

        let decision = OCRCandidateSelection.select(embedded: embedded, ocr: ocr, policy: .v1)

        XCTAssertEqual(decision.selectedRevisionID, embedded.id)
        XCTAssertEqual(decision.chosenOrigin, .embeddedPDF)
        XCTAssertNotEqual(decision.decidingRule, .ocrWinsByLength)
        XCTAssertEqual(decision.decidingRule, .embeddedOCRConfidenceBelowThreshold)
    }

    func testTOCR02DecisionPersistsEveryScoreThresholdAndStableCanonicalJSON() throws {
        // T-OCR-02 expected RED: there is no policy-v1 decision payload with
        // candidate IDs, criterion scores, thresholds, or a canonical encoder.
        let embedded = OCRCandidateSelection.RevisionCandidate(
            id: "embedded-poor-quality",
            origin: .embeddedPDF,
            text: "%%%% datum datum datum"
        )
        let ocr = OCRCandidateSelection.RevisionCandidate(
            id: "ocr-two-quality-wins",
            origin: .ocr,
            text: "Payment is due thirty days after receipt of the verified invoice.",
            confidence: 0.94,
            boundingBoxesJSON: boxesJSON([0.93, 0.95, 0.94])
        )

        let first = OCRCandidateSelection.select(embedded: embedded, ocr: ocr, policy: .v1)
        let replay = OCRCandidateSelection.select(embedded: embedded, ocr: ocr, policy: .v1)

        XCTAssertEqual(first.policyVersion, 1)
        XCTAssertEqual(first.candidateRevisionIDs, [embedded.id, ocr.id])
        XCTAssertEqual(first.selectedRevisionID, ocr.id)
        XCTAssertEqual(first.chosenOrigin, .ocr)
        XCTAssertEqual(Set(first.scores.keys), Set(first.candidateRevisionIDs))
        XCTAssertNotNil(first.scores[embedded.id])
        XCTAssertNotNil(first.scores[ocr.id])
        XCTAssertEqual(first.thresholds.lowConfidenceThreshold, OCRPolicy.lowConfidenceThreshold)
        XCTAssertEqual(first.thresholds.minimumUsableTextLength, OCRPolicy.minimumUsableTextLength)
        XCTAssertGreaterThanOrEqual(first.thresholds.minimumCriteriaWins, 2)
        XCTAssertTrue(first.ocrWinningCriteria.contains(.confidence))
        XCTAssertTrue(first.ocrWinningCriteria.contains(.scriptConsistency))
        XCTAssertTrue(first.ocrWinningCriteria.contains(.duplication))
        XCTAssertEqual(first.decidingRule, .ocrWinsMultiCriterion)
        XCTAssertFalse(first.needsReview)
        XCTAssertGreaterThan(first.selectedConfidence, 0)
        XCTAssertLessThanOrEqual(first.selectedConfidence, 1)

        let firstJSON = try first.canonicalJSON()
        XCTAssertEqual(firstJSON, try replay.canonicalJSON())
        XCTAssertEqual(try JSONDecoder().decode(OCRCandidateSelection.Decision.self, from: Data(firstJSON.utf8)), first)
        XCTAssertLessThan(
            try XCTUnwrap(firstJSON.range(of: "\"candidateRevisionIDs\"" )?.lowerBound),
            try XCTUnwrap(firstJSON.range(of: "\"selectedRevisionID\"" )?.lowerBound),
            "sorted-key JSON must put candidateRevisionIDs before selectedRevisionID"
        )
    }

    func testTOCR03BothPoorCandidatesRequireReview() {
        // T-OCR-03 expected RED: there is no comparative quality floor or
        // selection-specific review reason before policy v1.
        let decision = OCRCandidateSelection.select(
            embedded: .init(id: "embedded-sparse", origin: .embeddedPDF, text: "x"),
            ocr: .init(
                id: "ocr-sparse-garbled",
                origin: .ocr,
                text: "## ?? @@",
                confidence: 0.19,
                boundingBoxesJSON: boxesJSON([0.11, 0.18])
            ),
            policy: .v1
        )

        XCTAssertTrue(decision.needsReview)
        XCTAssertEqual(decision.reviewReason, "both_candidates_below_quality_floor")
    }

    func testTOCR04HighConfidenceOCRWinsOverSparseEmbeddedNoise() {
        // T-OCR-04 expected RED: the policy-v1 API and versioned decision do not
        // exist, even though longer-wins happens to choose this OCR candidate.
        let ocrText = "The inspected premises show active water intrusion above Unit 2C. "
            + "Repair should begin after written notice and verified access."
        let decision = OCRCandidateSelection.select(
            embedded: .init(id: "embedded-four-char-noise", origin: .embeddedPDF, text: "N0!S"),
            ocr: .init(
                id: "ocr-high-quality",
                origin: .ocr,
                text: ocrText,
                confidence: 0.97,
                boundingBoxesJSON: boxesJSON([0.96, 0.98, 0.97])
            ),
            policy: .v1
        )

        XCTAssertEqual(decision.selectedRevisionID, "ocr-high-quality")
        XCTAssertEqual(decision.chosenOrigin, .ocr)
        XCTAssertEqual(decision.policyVersion, 1)
        XCTAssertFalse(decision.needsReview)
    }

    private func boxesJSON(_ confidences: [Double]) -> String {
        let boxes = confidences.enumerated().map { index, confidence in
            [
                "x": Double(index) / 10,
                "y": 0.5,
                "w": 0.08,
                "h": 0.04,
                "confidence": confidence,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: boxes, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
