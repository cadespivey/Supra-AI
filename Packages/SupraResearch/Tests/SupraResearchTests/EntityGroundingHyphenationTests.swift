import SupraResearch
import XCTest

/// Reported bug (matter chat, 2026-07-19): "Steven W. Ritcheson" was flagged as
/// not appearing verbatim in the cited documents even though the complaint
/// caption states it on line 1. PDF text extraction can split a word at a
/// line-break hyphen or soft hyphen ("Ritche-\nson"); the model reads through
/// the split, so the whole-word grounding check must too.
///
/// Expected RED reason: wordTokenSet tokenizes the raw extracted text only, so
/// a hyphen-split name yields tokens "ritche" + "son" and the assembled name is
/// flagged as ungrounded.
final class EntityGroundingHyphenationTests: XCTestCase {

    private let hyphenatedCaption = """
    Steven W. Ritche-
    son (SBN 174062)
    INSIGHT, PLC
    Email: swritcheson@insightplc.com
    Attorney for Plaintiff
    """

    private func flaggedExcerpts(_ answer: String, source: String) -> [String] {
        LegalCitationVerifier.verifyGroundedEntities(answer: answer, sourceText: source)
            .compactMap(\.excerpt)
    }

    func testNameSplitByLineBreakHyphenIsGrounded() {
        let flagged = flaggedExcerpts(
            "Steven W. Ritcheson is the attorney for Plaintiff.",
            source: hyphenatedCaption
        )
        XCTAssertFalse(flagged.contains("Steven W. Ritcheson"), "flagged: \(flagged)")
    }

    func testNameSplitBySoftHyphenIsGrounded() {
        let flagged = flaggedExcerpts(
            "Aaron Castellano signed the notice.",
            source: "/s/ Aaron Castel\u{00AD}lano\nAttorney for Defendant"
        )
        XCTAssertFalse(flagged.contains("Aaron Castellano"), "flagged: \(flagged)")
    }

    // Guard (expected GREEN before and after): de-hyphenation must not weaken
    // the check — a name genuinely absent from the record stays flagged.
    func testAbsentNameIsStillFlaggedAfterDehyphenation() {
        let flagged = flaggedExcerpts(
            "Michael Turrentine appeared for Plaintiff.",
            source: hyphenatedCaption
        )
        XCTAssertTrue(flagged.contains("Michael Turrentine"))
    }
}
