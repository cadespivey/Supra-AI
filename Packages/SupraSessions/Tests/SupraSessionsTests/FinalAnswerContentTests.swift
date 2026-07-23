import Foundation
import SupraCore
@testable import SupraSessions
import XCTest

/// Render-time fold of a grounded answer's preamble, completing the response
/// layout the user asked for (Reasoning, Support check, then ONE "Answer:" line,
/// then sources). DeepSeek-R1 reliably restates the answer as working prose
/// before its final "**Answer:** …" line — the user sees the same answer twice.
/// Everything before the LAST line-anchored "Answer:" marker is preamble that
/// belongs with the collapsed Reasoning section; the displayed answer starts at
/// the marker. Content without a marker is untouched, so compliant single-line
/// answers, memos, research output, and refusals render exactly as before.
/// Persistence and copy keep the full text.
///
/// Expected RED for this file: `FinalAnswerContent` does not exist, so the file
/// does not compile.
final class FinalAnswerContentTests: XCTestCase {

    /// T-FANS-01: the observed duplicate shape — a prose restatement followed by
    /// the bold answer line — folds the restatement into the preamble and keeps
    /// the answer line (bold marker included) as the displayed answer.
    func testPreambleBeforeBoldAnswerLineFolds() throws {
        let body = "The case number for this case is 2:26-cv-00856-MWC-PVC, as mentioned in sources S1 and S7.\n\n"
            + "**Answer:** The case number is 2:26-cv-00856-MWC-PVC. [S1] [S7]"
        let split = FinalAnswerContent.split(body)
        XCTAssertEqual(
            split.preamble,
            "The case number for this case is 2:26-cv-00856-MWC-PVC, as mentioned in sources S1 and S7."
        )
        XCTAssertEqual(split.answer, "**Answer:** The case number is 2:26-cv-00856-MWC-PVC. [S1] [S7]")
    }

    /// T-FANS-02: a plain (unbolded) "Answer:" line folds the same way.
    func testPlainAnswerMarkerFolds() throws {
        let body = "Working through the sources.\nAnswer: The fee is $9,000. [S1]"
        let split = FinalAnswerContent.split(body)
        XCTAssertEqual(split.preamble, "Working through the sources.")
        XCTAssertEqual(split.answer, "Answer: The fee is $9,000. [S1]")
    }

    /// T-FANS-03: no marker — the body is untouched. Compliant bare answers,
    /// memos, research memos, and refusals must render exactly as before.
    func testBodyWithoutMarkerIsUntouched() {
        for body in [
            "The case number is 2:26-cv-00856-MWC-PVC. [S1]",
            "## Question Presented\nWhether the deadline ran. Short answer: yes.",
            "The provided sources do not support an answer to that question.",
        ] {
            let split = FinalAnswerContent.split(body)
            XCTAssertNil(split.preamble, body)
            XCTAssertEqual(split.answer, body)
        }
    }

    /// T-FANS-04: a marker already at the start has no preamble to fold.
    func testMarkerAtStartHasNoPreamble() {
        let body = "**Answer:** The fee is $9,000. [S1]"
        let split = FinalAnswerContent.split(body)
        XCTAssertNil(split.preamble)
        XCTAssertEqual(split.answer, body)
    }

    /// T-FANS-05: when the model repeats the marker, the LAST one wins — earlier
    /// attempts are preamble.
    func testLastMarkerWins() throws {
        let body = "Answer: draft attempt. [S1]\nActually, refining.\n**Answer:** The fee is $9,000. [S1]"
        let split = FinalAnswerContent.split(body)
        XCTAssertEqual(split.preamble, "Answer: draft attempt. [S1]\nActually, refining.")
        XCTAssertEqual(split.answer, "**Answer:** The fee is $9,000. [S1]")
    }

    /// T-FANS-06: the marker is line-anchored — a mid-sentence "Answer:" never
    /// splits the body.
    func testMidLineAnswerIsNotAMarker() {
        let body = "The short Answer: is that the deadline ran. [S1]"
        let split = FinalAnswerContent.split(body)
        XCTAssertNil(split.preamble)
        XCTAssertEqual(split.answer, body)
    }

    /// T-FANS-07: composes with the splits the message row already applies —
    /// reasoning first, then the support notice, then the answer fold.
    func testChainsAfterReasoningAndNoticeSplits() {
        let full = "<think>compare S1 and S7</think>"
            + "The case number appears in both sources.\n\n**Answer:** The case number is X. [S1]"
            + "\n\n---\n\n" + SupportNoticeContent.documentSupportHeading
            + "\n- 1 of 2 cited statements could not be confirmed against the cited sources."

        let noticeSplit = SupportNoticeContent.split(ReasoningContent.answer(from: full))
        XCTAssertNotNil(noticeSplit.notice)
        let answerSplit = FinalAnswerContent.split(noticeSplit.body)
        XCTAssertEqual(answerSplit.preamble, "The case number appears in both sources.")
        XCTAssertEqual(answerSplit.answer, "**Answer:** The case number is X. [S1]")
    }
}
