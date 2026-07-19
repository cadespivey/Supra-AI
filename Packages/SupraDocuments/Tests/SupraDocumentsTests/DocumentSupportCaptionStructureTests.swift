import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

/// Reported bug (matter chat, 2026-07-19): a correct "who are the attorneys"
/// answer over pleading-caption sources produced five false support warnings.
/// Two mechanical causes:
///
/// 1. The sentence splitter treats every period as a boundary, so middle
///    initials ("Steven W. Ritcheson") and legal abbreviations ("Fed. R. Civ.
///    P.") fragment a proposition away from its own inline citation.
/// 2. Support candidates are single sentences/lines, but captions and signature
///    blocks state one fact across several short lines (name / role / party),
///    so a correct cross-line synthesis could never verify.
///
/// Expected RED reason: DocumentSupportVerifier still splits at abbreviation
/// periods and has no line-block candidates, so the caption scenario reports
/// fragmented, citation-less propositions and unsupported claims.
final class DocumentSupportCaptionStructureTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    // Mirrors the reported complaint p.1 caption ([S6] in the bug report).
    private let complaintCaption = """
    Steven W. Ritcheson (SBN 174062)
    INSIGHT, PLC
    578 Washington Blvd. #503
    Marina del Rey, California 90292
    Telephone: (424) 289-9191
    Facsimile: (818) 337-0383
    Email: swritcheson@insightplc.com
    Attorney for Plaintiff

    UNITED STATES DISTRICT COURT
    FOR THE CENTRAL DISTRICT OF CALIFORNIA

    OPTIMUM VECTOR DYNAMICS LLC, a California limited liability company, Plaintiff,
    vs.
    LOWE'S HOME CENTERS, LLC, a North Carolina company, Defendant.
    """

    // Mirrors the reported motion p.23 certificate/signature block ([S3]).
    private let certificateSignature = """
    Certificate of Compliance

    The undersigned, counsel of record for Defendant Lowe's Home Centers, LLC, certifies that this brief contains 5072 words, which complies with the word limit of L.R. 11-6.1.

    /s/ Aaron R. Hand
    Aaron R. Hand
    Attorney for Defendant
    Lowe's Home Centers, LLC
    """

    func testCaptionGroundedAttorneyAnswerVerifiesCleanly() throws {
        // The exact reported answer: a colon lead-in plus two bullets whose
        // middle initials must not decapitate the names from their citations.
        let answer = """
        The attorneys mentioned in the provided sources are:
        - Steven W. Ritcheson, attorney for Plaintiff Optimum Vector Dynamics LLC [S6].
        - Aaron R. Hand, attorney for Defendant Lowe's Home Centers, LLC [S3].
        """
        let report = try verify(answer, sources: [
            source(label: "S3", text: certificateSignature),
            source(label: "S6", text: complaintCaption),
        ])

        XCTAssertEqual(report.propositions.count, 2, "lead-in is an introducer, each bullet is one proposition")
        XCTAssertEqual(report.propositions.map(\.citationLabels), [["S6"], ["S3"]])
        XCTAssertTrue(
            report.propositions[0].text.contains("Steven W. Ritcheson, attorney for Plaintiff"),
            "the name must stay attached to its role, got: \(report.propositions[0].text)"
        )
        XCTAssertEqual(report.results.map(\.status), [.supported, .supported])
        XCTAssertEqual(report.verificationStatus, .allSupported)
        XCTAssertFalse(report.requiresReview)
        XCTAssertTrue(report.warnings.isEmpty, "unexpected warnings: \(report.warnings)")
    }

    func testAbbreviationPeriodsDoNotSplitAProposition() throws {
        let report = try verify(
            "Lowe's moved to dismiss under Fed. R. Civ. P. 12(b)(6) [S1].",
            sources: [source(label: "S1", text: "Defendant Lowe's Home Centers moved to dismiss the complaint under Fed. R. Civ. P. 12(b)(6).")]
        )

        XCTAssertEqual(report.propositions.count, 1, "citation abbreviations are not sentence boundaries")
        XCTAssertEqual(report.propositions.first?.citationLabels, ["S1"])
        XCTAssertEqual(report.results.map(\.status), [.supported])
        XCTAssertFalse(report.requiresReview)
    }

    func testBulletWithInitialsKeepsItsCitationBinding() throws {
        let report = try verify(
            "- Steven W. Ritcheson appeared for Plaintiff [S2].",
            sources: [source(label: "S2", text: "Steven W. Ritcheson appeared for Plaintiff Optimum Vector Dynamics LLC.")]
        )

        XCTAssertEqual(report.propositions.count, 1)
        XCTAssertEqual(report.propositions.first?.citationLabels, ["S2"])
        XCTAssertEqual(report.results.map(\.status), [.supported])
    }

    func testColonLeadInIsNotAMaterialProposition() throws {
        let answer = """
        The attorneys of record are:
        - Aaron R. Hand for Defendant [S1].
        """
        let report = try verify(answer, sources: [source(label: "S1", text: certificateSignature)])

        XCTAssertEqual(report.propositions.count, 1, "a list introducer ending in a colon is not a claim")
        XCTAssertEqual(report.results.map(\.status), [.supported])
    }

    func testHyphenatedLineBreakInSourceStillSupports() throws {
        // PDF text extraction splits words at line-break hyphens; the verifier
        // must read through them like the model does.
        let hyphenated = """
        Steven W. Ritche-
        son (SBN 174062)
        Attorney for Plaintiff
        """
        let report = try verify(
            "Steven W. Ritcheson is the attorney for Plaintiff [S1].",
            sources: [source(label: "S1", text: hyphenated)]
        )

        XCTAssertEqual(report.results.map(\.status), [.supported])
    }

    func testSupportWarningsQuoteThePropositionInsteadOfInternalIDs() throws {
        let uncited = try verify(
            "Payment was due March 3, 2025 [S1]. The agreement renewed automatically.",
            sources: [source(label: "S1", text: "Payment was due March 3, 2025.")]
        )
        let unsupported = try verify(
            "The contract renewed automatically [S1].",
            sources: [source(label: "S1", text: "Payment was due March 3, 2025.")]
        )

        XCTAssertTrue(
            uncited.warnings.contains { $0.contains("The agreement renewed automatically") },
            "warning must quote the claim, got: \(uncited.warnings)"
        )
        XCTAssertTrue(
            unsupported.warnings.contains { $0.contains("The contract renewed automatically") },
            "warning must quote the claim, got: \(unsupported.warnings)"
        )
        for warning in uncited.warnings + unsupported.warnings {
            XCTAssertFalse(warning.contains("document-proposition"), "internal IDs must not leak: \(warning)")
        }
    }

    // MARK: - Conservatism guards (expected GREEN before and after the fix;
    // they pin that line-block candidates cannot smear distant facts together
    // or reassign roles).

    func testDistantCrossBlockSynthesisRemainsUnsupported() throws {
        // Ritcheson is Plaintiff's counsel; binding him to the Defendant would
        // need tokens from the caption's first line AND its last line — beyond
        // any bounded block window and in the wrong order.
        let report = try verify(
            "Steven W. Ritcheson, attorney for Defendant Lowe's Home Centers, LLC [S1].",
            sources: [source(label: "S1", text: complaintCaption)]
        )

        XCTAssertEqual(report.results.map(\.status), [.unsupported])
        XCTAssertTrue(report.requiresReview)
    }

    func testRoleReversalWithinASignatureBlockRemainsUnsupported() throws {
        let report = try verify(
            "Aaron R. Hand, attorney for Plaintiff [S1].",
            sources: [source(label: "S1", text: certificateSignature)]
        )

        XCTAssertEqual(report.results.map(\.status), [.unsupported])
        XCTAssertTrue(report.requiresReview)
    }

    // MARK: - Helpers

    private func verify(
        _ answer: String,
        sources: [DocumentSupportSource],
        scopeFullyIndexed: Bool = true
    ) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
            answer: answer,
            sources: sources,
            scopeFullyIndexed: scopeFullyIndexed,
            timestamp: timestamp
        )
    }

    private func source(label: String, text: String) -> DocumentSupportSource {
        DocumentSupportSource(
            sourceID: "matter-ovd/chunk-\(label)",
            label: label,
            locator: "p. 1",
            text: text
        )
    }
}
