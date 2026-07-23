import SupraCore
@testable import SupraDocuments
import XCTest

/// Wire-proofs for the grounded-QA prompt rules that steer a reasoning model toward citations the
/// extractive verifier can confirm: a bare `[S1]` placed inside the claim sentence (no `[CITE: …]`
/// or prose), and — in short mode — the answer stated exactly once as one final line beginning
/// "Answer:". (REVISED in RED: the rule previously FORBADE the "Answer:" label; the user chose the
/// labeled single-line form as the displayed answer shape, and the render-time fold treats
/// everything before that final line as collapsed preamble.) The memo mode keeps its headed
/// sections and is not told to say the answer once.
final class DocumentQAPromptRulesTests: XCTestCase {

    private let source = GroundingSource(
        sourceID: "matter/chunk-a",
        label: "S1",
        documentName: "Complaint.pdf",
        locatorDisplay: "p. 1",
        text: "The case number is 2:26-cv-00856-MWC-PVC.",
        excerpt: "case number"
    )

    private func prompt(_ mode: DocumentAnswerMode) -> String {
        DocumentQAPromptBuilder.buildQAPrompt(question: "What is the case number?", sources: [source], mode: mode)
    }

    func testShortModeDemandsInSentenceBareLabelAndOneFinalAnswerLine() {
        let short = prompt(.short)
        XCTAssertTrue(short.contains("within the same sentence"), "citation must be required inside the claim sentence")
        XCTAssertTrue(short.contains("[CITE:"), "the rule names [CITE: …] as a form to avoid")
        XCTAssertTrue(
            short.contains("State the answer exactly once"),
            "short mode demands a single statement of the answer"
        )
        XCTAssertTrue(
            short.contains("final line that begins \"Answer:\""),
            "short mode requires the labeled single-line form the display folds to"
        )
        XCTAssertFalse(
            short.contains("do not open with a label"),
            "the old prohibition on the \"Answer:\" label must be gone"
        )
    }

    func testMemoKeepsHeadedSectionsAndIsNotToldToSayItOnce() {
        let memo = prompt(.memo)
        // The tightened citation rule applies to the memo too.
        XCTAssertTrue(memo.contains("within the same sentence"))
        // But the memo keeps its intentional multi-section structure and is NOT told to say it once.
        XCTAssertTrue(memo.contains("Question Presented"))
        XCTAssertFalse(memo.contains("State the answer exactly once"), "the say-it-once clause is short-mode only")
        XCTAssertFalse(memo.contains("final line that begins \"Answer:\""), "the labeled-line rule is short-mode only")
    }
}
