import SupraCore
import XCTest

final class PromptBudgetTests: XCTestCase {
    func testReservesOutputAndTemplateMargin() {
        XCTAssertEqual(
            PromptBudget.promptTokenBudget(maxContextTokens: 65_536, maxOutputTokens: 6000),
            65_536 - 6000 - PromptBudget.templateMargin
        )
    }

    func testFloorsAtSmallPositiveValueWhenOutputExceedsContext() {
        // A degenerate config (output budget larger than the window) still yields a
        // small positive budget rather than a negative one.
        XCTAssertEqual(PromptBudget.promptTokenBudget(maxContextTokens: 100, maxOutputTokens: 4096), 512)
    }
}
