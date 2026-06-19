import SupraCore
import XCTest

final class ReasoningContentTests: XCTestCase {

    func testNonReasoningOutputIsReturnedUnchanged() {
        let raw = "The agreement does not require arbitration."
        XCTAssertEqual(ReasoningContent.answer(from: raw), raw)
        XCTAssertNil(ReasoningContent.reasoning(from: raw))
    }

    func testStripsReasoningWhenCloseTagPresentWithoutOpenTag() {
        // Qwen3-style: the opening <think> is in the prompt, so generated text
        // starts with the reasoning and contains only the closing tag.
        let raw = "Thinking Process: weigh the clause.\n</think>\n\nNo — it is not required."
        XCTAssertEqual(ReasoningContent.answer(from: raw), "No — it is not required.")
        XCTAssertEqual(ReasoningContent.reasoning(from: raw), "Thinking Process: weigh the clause.")
    }

    func testStripsFullThinkBlockWithBothTags() {
        let raw = "<think>\nstep one\nstep two\n</think>\n\nFinal answer."
        XCTAssertEqual(ReasoningContent.answer(from: raw), "Final answer.")
        XCTAssertEqual(ReasoningContent.reasoning(from: raw), "step one\nstep two")
    }

    func testAnswerIsEmptyWhenOnlyReasoningEmittedSoFar() {
        let raw = "still reasoning, no answer yet\n</think>"
        XCTAssertEqual(ReasoningContent.answer(from: raw), "")
        XCTAssertEqual(ReasoningContent.reasoning(from: raw), "still reasoning, no answer yet")
    }

    func testMidStreamReasoningWithoutCloseTagIsPassthrough() {
        // No close tag yet: we cannot know where reasoning ends, so passthrough.
        let raw = "Thinking Process: 1. Analyze"
        XCTAssertEqual(ReasoningContent.answer(from: raw), raw)
        XCTAssertNil(ReasoningContent.reasoning(from: raw))
    }

    func testUsesFirstCloseTagSoAnswerMayContainTheLiteral() {
        let raw = "reasoning\n</think>\n\nThe tag </think> appears in prose here."
        XCTAssertEqual(
            ReasoningContent.answer(from: raw),
            "The tag </think> appears in prose here."
        )
    }

    func testResolveFlagsTruncatedReasoningWhenThinkingEnabledAndNoCloseTag() {
        let raw = "Step 1: the model is still reasoning and ran out of tokens"
        XCTAssertEqual(
            ReasoningContent.resolve(rawOutput: raw, thinkingEnabled: true),
            .truncatedReasoning(raw)
        )
    }

    func testResolveTreatsNoCloseTagAsAnswerWhenThinkingDisabled() {
        let raw = "The agreement does not require arbitration."
        XCTAssertEqual(
            ReasoningContent.resolve(rawOutput: raw, thinkingEnabled: false),
            .answer(raw)
        )
    }

    func testResolveReturnsAnswerAfterCloseTagEvenWhenThinkingEnabled() {
        let raw = "weigh the clause\n</think>\n\nNo — it is not required."
        XCTAssertEqual(
            ReasoningContent.resolve(rawOutput: raw, thinkingEnabled: true),
            .answer("No — it is not required.")
        )
    }

    func testResolveEmptyOutputIsAnswerNotTruncation() {
        XCTAssertEqual(ReasoningContent.resolve(rawOutput: "   ", thinkingEnabled: true), .answer(""))
    }
}
