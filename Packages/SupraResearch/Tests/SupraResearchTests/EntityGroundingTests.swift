import SupraResearch
import XCTest

/// The fact-firewall fix for document-grounded chat: a name/email/phone asserted in an
/// answer but absent from the cited sources must be flagged (it was likely inferred,
/// e.g. a full name reconstructed from an email prefix), while a name that appears
/// verbatim in the sources must pass.
final class EntityGroundingTests: XCTestCase {

    // The exact reported bug: the docs contain only emails + one signature; the model
    // expanded the prefixes into full names.
    private let source = """
    Attorneys for McKernon Motors — Primary and Secondary E-Mail Addresses:
    hspecter@psl.com mross@psl.com llitt@psl.com dpaulsen@psl.com kbennett@psl.com
    Respectfully submitted, PEARSON SPECTER LITT By: /s/ Harvey Specter
    """

    private func flaggedExcerpts(_ answer: String) -> [String] {
        LegalCitationVerifier.verifyGroundedEntities(answer: answer, sourceText: source)
            .compactMap(\.excerpt)
    }

    func testFabricatedNameFromEmailPrefixIsFlagged() {
        let flagged = flaggedExcerpts("Counsel for McKernon Motors includes Mike Ross (mross@psl.com) and Donna Paulsen (dpaulsen@psl.com).")
        XCTAssertTrue(flagged.contains("Mike Ross"), "a name absent from the record must be flagged")
        XCTAssertTrue(flagged.contains("Donna Paulsen"))
    }

    func testNamePresentVerbatimInSourceIsNotFlagged() {
        // "Harvey Specter" appears as "/s/ Harvey Specter" in the source.
        XCTAssertFalse(flaggedExcerpts("The motion was signed by Harvey Specter.").contains("Harvey Specter"))
    }

    func testEvenPlausiblyCorrectInferredNameIsFlagged() {
        // llitt@ -> "Louis Litt" may be right, but it isn't spelled out in the
        // record, so per the "show but mark unverified" policy it is still flagged.
        XCTAssertTrue(flaggedExcerpts("Louis Litt is counsel.").contains("Louis Litt"))
    }

    func testOrganizationAndHeadingWordsAreNotTreatedAsPeople() {
        let flagged = flaggedExcerpts("Parties Involved: McKernon Motors is the Plaintiff.")
        XCTAssertFalse(flagged.contains("Parties Involved"))
        XCTAssertFalse(flagged.contains("McKernon Motors"))
        XCTAssertFalse(flagged.contains("McKernon"))
    }

    func testEmailAbsentFromSourceIsFlagged() {
        XCTAssertTrue(flaggedExcerpts("Reach them at fabricated@psl.com.").contains("fabricated@psl.com"))
    }

    func testEmailPresentInSourceIsNotFlagged() {
        XCTAssertFalse(flaggedExcerpts("Reach them at hspecter@psl.com.").contains("hspecter@psl.com"))
    }

    func testFullyGroundedAnswerProducesNoIssues() {
        XCTAssertTrue(LegalCitationVerifier.verifyGroundedEntities(
            answer: "The signer was Harvey Specter; the address is hspecter@psl.com.",
            sourceText: source
        ).isEmpty)
    }
}
