import Foundation
import SupraDocuments
@testable import SupraSessions
import XCTest

/// The document-support banner appended to a grounded chat answer must stay CONCISE: a reasoning
/// model's synthesis sentences cite sources but rarely match them verbatim, so the extractive
/// verifier flags several — and a bullet-per-proposition dump reads as noise on an answer that is
/// otherwise correct. The banner should collapse the per-statement misses into one count while
/// preserving the review warning and the specific structural notes.
final class DocumentSupportBannerTests: XCTestCase {

    private func report(answer: String, sources: [(label: String, text: String)]) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
            answer: answer,
            sources: sources.map {
                DocumentSupportSource(sourceID: "matter/\($0.label)", label: $0.label, locator: "{}", text: $0.text)
            },
            scopeFullyIndexed: true
        )
    }

    /// Three cited statements, one supported and two that don't match the source text. The banner
    /// summarizes the two misses as a single count line rather than one bullet each. Expected RED:
    /// the current banner emits one "No cited source text supports …" bullet per unsupported
    /// proposition.
    func testBannerCollapsesPerPropositionMissesIntoACount() throws {
        let report = try report(
            answer: "The fee was $900 [S1]. The contract was signed in 2020 [S1]. The parties agreed to arbitration [S1].",
            sources: [("S1", "The fee was $900.")]
        )
        XCTAssertTrue(report.requiresReview, "two of the three cited statements are unsupported")
        let banner = try XCTUnwrap(GlobalChatController.documentSupportBanner(report))

        // Concise: a single count summary, not a bullet per unconfirmed statement.
        XCTAssertTrue(
            banner.contains("2 of 3"),
            "banner should summarize the misses as a count; got:\n\(banner)"
        )
        let perPropositionBullets = banner.components(separatedBy: "No cited source text supports").count - 1
        XCTAssertEqual(
            perPropositionBullets, 0,
            "the per-proposition 'No cited source text supports …' bullets should be collapsed; got:\n\(banner)"
        )
        // The review warning itself must remain.
        XCTAssertTrue(banner.contains("Document support check"))
    }

    /// A structural warning (an unresolved citation) is specific and actionable, so it survives the
    /// collapse as its own line. Expected RED only in that the count summary is absent today.
    func testBannerKeepsSpecificStructuralWarning() throws {
        let report = try report(
            answer: "The fee was $900 [S1]. See also the schedule [S9].",
            sources: [("S1", "The fee was $900.")]
        )
        let banner = try XCTUnwrap(GlobalChatController.documentSupportBanner(report))
        XCTAssertTrue(
            banner.localizedCaseInsensitiveContains("do not resolve") || banner.localizedCaseInsensitiveContains("S9"),
            "an unresolved-citation warning is specific and should be kept; got:\n\(banner)"
        )
    }
}
