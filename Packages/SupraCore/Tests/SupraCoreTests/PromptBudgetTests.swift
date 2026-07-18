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

    func testTTOK06CanonicalCandidatePackingReportAccountsForEveryDisposition() throws {
        // T-TOK-06 expected RED: the in-memory summary has aggregate counts only;
        // there is no candidate-level, canonically encodable persistence contract.
        let report = DocumentPackingReport(
            countMethod: .exact,
            availableInputTokens: 700,
            selectedInputTokens: 620,
            overflowRetryCount: 1,
            candidates: [
                .init(
                    sourceID: "candidate-considered", label: "S0", rank: 0,
                    disposition: .considered, reason: "retrieval_candidate",
                    originalTokenCount: 25, packedTokenCount: 0
                ),
                .init(
                    sourceID: "candidate-packed", label: "S1", rank: 1,
                    disposition: .packed, reason: "within_context_budget",
                    originalTokenCount: 300, packedTokenCount: 300
                ),
                .init(
                    sourceID: "candidate-truncated", label: "S2", rank: 2,
                    disposition: .truncated, reason: "per_source_character_limit",
                    originalTokenCount: 500, packedTokenCount: 320
                ),
                .init(
                    sourceID: "candidate-omitted", label: "S3", rank: 3,
                    disposition: .omitted, reason: "context_budget",
                    originalTokenCount: 410, packedTokenCount: 0
                ),
                .init(
                    sourceID: "candidate-deferred", label: "S4", rank: 4,
                    disposition: .deferred, reason: "overflow_retry",
                    originalTokenCount: 390, packedTokenCount: 0
                ),
            ]
        )

        XCTAssertEqual(Set(report.candidates.map(\.sourceID)).count, report.candidates.count)
        XCTAssertEqual(report.packedSourceIDs, ["candidate-packed", "candidate-truncated"])
        XCTAssertEqual(
            try report.canonicalJSON(),
            #"{"available_input_tokens":700,"candidates":[{"disposition":"considered","label":"S0","original_token_count":25,"packed_token_count":0,"rank":0,"reason":"retrieval_candidate","source_id":"candidate-considered"},{"disposition":"packed","label":"S1","original_token_count":300,"packed_token_count":300,"rank":1,"reason":"within_context_budget","source_id":"candidate-packed"},{"disposition":"truncated","label":"S2","original_token_count":500,"packed_token_count":320,"rank":2,"reason":"per_source_character_limit","source_id":"candidate-truncated"},{"disposition":"omitted","label":"S3","original_token_count":410,"packed_token_count":0,"rank":3,"reason":"context_budget","source_id":"candidate-omitted"},{"disposition":"deferred","label":"S4","original_token_count":390,"packed_token_count":0,"rank":4,"reason":"overflow_retry","source_id":"candidate-deferred"}],"count_method":"exact","overflow_retry_count":1,"schema_version":1,"selected_input_tokens":620}"#
        )
    }

    func testTokenPackingSummaryDecodesPreCandidateAccountingJSON() throws {
        let legacy = #"{"availableInputTokens":700,"cannotPackReason":null,"consideredItemCount":3,"countMethod":"exact","omissionReason":"context_budget","omittedItemCount":1,"overflowRetryCount":0,"packedItemCount":2,"selectedInputTokens":620}"#
        let report = try JSONDecoder().decode(TokenPackingReport.self, from: Data(legacy.utf8))
        XCTAssertEqual(report.packedItemCount, 2)
        XCTAssertEqual(report.cumulativeInputTokenCounts, [])
    }
}
