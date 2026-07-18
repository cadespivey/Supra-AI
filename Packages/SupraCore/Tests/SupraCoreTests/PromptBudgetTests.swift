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

    func testExactTokenCountsChangePackedPrefixAndFallbackParityIsFrozen() {
        // T-TOK-02 expected RED: no shared token-aware packet budgeter exists.
        let packets = [
            String(repeating: "a", count: 40),
            String(repeating: "b", count: 80),
            String(repeating: "c", count: 120),
        ]
        let inflated = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: packets,
            exactCounts: [20, 70, 110],
            maxContextTokens: 100,
            outputReserveTokens: 20,
            safetyMargin: 20
        )
        XCTAssertEqual(inflated.packedItemCount, 1)
        XCTAssertEqual(inflated.omittedItemCount, 2)
        XCTAssertEqual(inflated.countMethod, .exact)

        let fallback = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: packets,
            maxContextTokens: 100,
            outputReserveTokens: 20,
            safetyMargin: 20
        )
        let exactAtFallbackCounts = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: packets,
            exactCounts: packets.map(TokenBudgeter.fallbackTokenCount),
            maxContextTokens: 100,
            outputReserveTokens: 20,
            safetyMargin: 20
        )
        XCTAssertEqual(fallback.packedItemCount, exactAtFallbackCounts.packedItemCount)
        XCTAssertEqual(fallback.selectedInputTokens, exactAtFallbackCounts.selectedInputTokens)
    }

    func testConservativeFallbackNeverAcceptsBeyondWindowAndRefusesOversizedSingleton() {
        // T-TOK-03 expected RED: fallback bounds and cannot-pack semantics are missing.
        let packets = [
            "plain ASCII instruction envelope",
            "Unicode evidence — café 東京 ⚖️",
            #"{"source":"S1","text":"quoted evidence"}"#,
        ]
        for window in [64, 96, 160, 512] {
            for reserve in [8, 16, 32] {
                for packet in packets {
                    let decision = TokenBudgeter.chooseLargestFittingPrefix(
                        serializedPackets: [packet],
                        maxContextTokens: window,
                        outputReserveTokens: reserve,
                        safetyMargin: 12
                    )
                    if decision.canPack {
                        XCTAssertLessThanOrEqual(
                            decision.selectedInputTokens + reserve,
                            window - 12
                        )
                    }
                }
            }
        }

        let oversized = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: [String(repeating: "x", count: 4_000)],
            maxContextTokens: 128,
            outputReserveTokens: 32,
            safetyMargin: 16
        )
        XCTAssertFalse(oversized.canPack)
        XCTAssertEqual(oversized.packedItemCount, 0)
        XCTAssertEqual(oversized.cannotPackReason, "required_packet_exceeds_context")
    }
}
