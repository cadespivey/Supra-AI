import SupraCore
import XCTest

final class PromptBudgetTests: XCTestCase {
    func testReservesOutputAndTemplateMargin() {
        XCTAssertEqual(
            PromptBudget.promptTokenBudget(maxContextTokens: 65_536, maxOutputTokens: 6000),
            65_536 - 6000 - PromptBudget.templateMargin
        )
    }

    func testNeverExceedsTheContextWindow() {
        // A degenerate config (output budget larger than a tiny window) must yield a
        // budget that does not exceed the window, so the overflow check still fires.
        XCTAssertEqual(PromptBudget.promptTokenBudget(maxContextTokens: 100, maxOutputTokens: 4096), 100)
        for ctx in [1, 100, 4096, 32_768, 65_536, 262_144] {
            for out in [1, 1024, 6000, 16_384] {
                XCTAssertLessThanOrEqual(
                    PromptBudget.promptTokenBudget(maxContextTokens: ctx, maxOutputTokens: out), ctx,
                    "budget must never exceed the window (ctx=\(ctx), out=\(out))"
                )
            }
        }
    }
}
