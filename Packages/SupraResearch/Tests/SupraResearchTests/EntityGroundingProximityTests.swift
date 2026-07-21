import SupraResearch
import XCTest

/// `verifyGroundedEntities` grounds a name by SET membership over the whole source:
/// `sourceWords` is a flat token set, so every token of "Nancy Rust" merely has to
/// appear *somewhere*. "Nancy" in a caption and "Rust" forty pages later ground a name
/// that the record never states.
///
/// This is a PRECISION fix for a heuristic, not a security control. The check is by
/// construction "does this string appear in the retrieved record", so anyone who
/// controls a cited document defeats it by writing the name into the document. That is
/// definitionally true of any verbatim-presence check and is an accepted non-goal. What
/// is fixable is the false negative from unordered matching, and from pooling every
/// packed source into one haystack.
final class EntityGroundingProximityTests: XCTestCase {

    /// Tokens scattered across an unrelated document must not ground a name.
    ///
    /// Expected RED: `sourceWords.contains` is satisfied by both tokens independently,
    /// so no issue is raised.
    func testScatteredTokensDoNotGroundAName() {
        let source = """
        Nancy served the discovery responses on March 3, 2024, and the parties conferred \
        about the production schedule at length before the hearing was continued.
        The deposition transcript was lodged with the clerk and the exhibits were \
        admitted without objection over the course of the following week.
        Counsel later withdrew the pending motion for a protective order after the \
        parties resolved the remaining disputes informally among themselves.
        The corrosion expert testified that the Rust observed on the frame was \
        consistent with prolonged exposure to road salt during winter months.
        """
        let flagged = LegalCitationVerifier.verifyGroundedEntities(
            answer: "Nancy Rust signed the certificate of service.",
            sourceText: source
        ).compactMap(\.excerpt)

        XCTAssertTrue(
            flagged.contains("Nancy Rust"),
            "tokens far apart in unrelated passages must not ground a name: \(flagged)"
        )
    }

    /// Regression pin, and the reason the fix cannot be strict left-to-right adjacency:
    /// captions and signature blocks routinely invert the name.
    func testCommaInvertedNameIsNotFlagged() {
        let flagged = LegalCitationVerifier.verifyGroundedEntities(
            answer: "Nancy Rust signed the certificate of service.",
            sourceText: "Rust, Nancy — Attorney for Defendant\nBar No. 55512"
        ).compactMap(\.excerpt)

        XCTAssertFalse(flagged.contains("Nancy Rust"), "an inverted caption name is grounded: \(flagged)")
    }

    /// Regression pin: a middle initial between the tokens must not break grounding.
    func testMiddleInitialNameIsNotFlagged() {
        let flagged = LegalCitationVerifier.verifyGroundedEntities(
            answer: "Nancy Rust signed the certificate of service.",
            sourceText: "/s/ Nancy P. Rust\nAttorney for Defendant"
        ).compactMap(\.excerpt)

        XCTAssertFalse(flagged.contains("Nancy Rust"), "a middle initial must not break grounding: \(flagged)")
    }

    /// A name must ground within a SINGLE packed source. Tokens drawn from two different
    /// documents are not a name the record states.
    ///
    /// Expected RED: the per-source overload does not exist, so this does not compile;
    /// and pooling would ground the name even once it does.
    func testNameSplitAcrossTwoSourcesIsFlagged() {
        let flagged = LegalCitationVerifier.verifyGroundedEntities(
            answer: "Nancy Rust signed the certificate of service.",
            sourceTexts: [
                "Nancy appeared telephonically for the status conference.",
                "The Rust on the undercarriage was documented by the inspector.",
            ]
        ).compactMap(\.excerpt)

        XCTAssertTrue(
            flagged.contains("Nancy Rust"),
            "tokens from two different documents must not combine into a grounded name: \(flagged)"
        )
    }

    /// The per-source overload must still ground a name that appears whole in one source.
    func testNameWithinOneSourceIsNotFlaggedByTheOverload() {
        let flagged = LegalCitationVerifier.verifyGroundedEntities(
            answer: "Nancy Rust signed the certificate of service.",
            sourceTexts: [
                "The Rust on the undercarriage was documented by the inspector.",
                "/s/ Nancy Rust, Attorney for Defendant",
            ]
        ).compactMap(\.excerpt)

        XCTAssertFalse(flagged.contains("Nancy Rust"), "a name whole in one source is grounded: \(flagged)")
    }
}
