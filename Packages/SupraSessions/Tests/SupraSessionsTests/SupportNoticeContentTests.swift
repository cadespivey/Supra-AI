import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import XCTest

/// Render-time split of the out-of-band verification banners (the document-support
/// check and the entity-grounding check) from an assistant message's persisted
/// content, mirroring `ReasoningContent`: the store keeps the full text — the
/// pinned security warnings and the copy action are untouched — while the chat
/// surface renders the banner collapsed and subdued instead of letting it dwarf
/// the answer (user report: the banner often reads larger than the answer itself).
///
/// Expected RED for this file: `SupportNoticeContent` does not exist, so the file
/// does not compile.
final class SupportNoticeContentTests: XCTestCase {

    private func supportBanner(answer: String, sourceText: String) throws -> String {
        let report = try DocumentSupportVerifier.verify(
            answer: answer,
            sources: [
                DocumentSupportSource(
                    sourceID: "matter/S1", label: "S1", locator: "{}", text: sourceText
                ),
            ],
            scopeFullyIndexed: true
        )
        XCTAssertTrue(report.requiresReview, "fixture must trip the review banner")
        return try XCTUnwrap(GlobalChatController.documentSupportBanner(report))
    }

    /// T-NOTICE-01: the support banner — built by the REAL controller builder, so
    /// the split markers cannot drift from the appended text — splits off the body;
    /// the body keeps no trailing separator, the notice keeps the heading and the
    /// count line.
    func testSupportBannerSplitsFromAnswer() throws {
        let answer = "The fee was $900 [S1]. The contract was signed in 2020 [S1]."
        let banner = try supportBanner(answer: answer, sourceText: "The fee was $900.")
        let split = SupportNoticeContent.split(answer + banner)

        XCTAssertEqual(split.body, answer, "the answer body must survive unchanged, without the trailing separator")
        let notice = try XCTUnwrap(split.notice)
        XCTAssertTrue(notice.contains(SupportNoticeContent.documentSupportHeading))
        XCTAssertTrue(notice.contains("1 of 2"), "the count line stays in the notice: \(notice)")
        XCTAssertFalse(notice.hasPrefix("---"), "the horizontal rule is presentation, not notice content")
    }

    /// T-NOTICE-02: when both out-of-band banners are appended (entity grounding
    /// first, support check second — the streamed path's order), the whole trailing
    /// block becomes one notice, in order, and the body stays clean.
    func testEntityAndSupportBannersBothSplit() throws {
        let answer = "Jane Doe signed the agreement [S1]."
        let entityBanner = "\n\n"
            + SupportNoticeContent.entityGroundingHeading
            + " The following were stated in the answer above but do not appear verbatim in the sources:"
            + "\n- Jane Doe"
        let supportBanner = try supportBanner(answer: answer, sourceText: "The signature block is illegible.")
        let split = SupportNoticeContent.split(answer + entityBanner + supportBanner)

        XCTAssertEqual(split.body, answer)
        let notice = try XCTUnwrap(split.notice)
        let entityRange = try XCTUnwrap(notice.range(of: SupportNoticeContent.entityGroundingHeading))
        let supportRange = try XCTUnwrap(notice.range(of: SupportNoticeContent.documentSupportHeading))
        XCTAssertTrue(entityRange.lowerBound < supportRange.lowerBound, "banner order is preserved")
    }

    /// T-NOTICE-03: content without banners is untouched — including an answer that
    /// legitimately contains a markdown horizontal rule.
    func testAnswerWithoutBannerIsUntouched() {
        let content = "Part A of the analysis.\n\n---\n\nPart B of the analysis."
        let split = SupportNoticeContent.split(content)
        XCTAssertEqual(split.body, content)
        XCTAssertNil(split.notice)
    }

    /// T-NOTICE-04: composes with the reasoning split the message row already
    /// applies — reasoning first, then the notice — so a reasoning-model answer
    /// with a banner renders as (collapsed reasoning) + answer + (collapsed notice).
    func testChainsAfterReasoningSplit() throws {
        let answer = "The deadline is April 15, 2025 [S1]."
        let banner = try supportBanner(answer: answer, sourceText: "An unrelated sentence.")
        let full = "<think>work through the sources</think>" + answer + banner

        let withoutReasoning = ReasoningContent.answer(from: full)
        let split = SupportNoticeContent.split(withoutReasoning)
        XCTAssertEqual(split.body, answer)
        XCTAssertNotNil(split.notice)
    }
}
