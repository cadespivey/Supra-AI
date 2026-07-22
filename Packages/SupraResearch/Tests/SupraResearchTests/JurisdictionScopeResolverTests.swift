import SupraResearch
import XCTest

/// Phase 3a (jurisdiction-as-data): the verifier's jurisdiction check must decide
/// scope from the court-hierarchy catalog, not from string containment.
///
/// REVISED in the Phase 3C RED commit (review finding #2, methodology §3.5): the
/// generic `JurisdictionScopeVerdict.withinScope` these tests consumed collapsed
/// legally distinct relationships, and two expectations encoded defects the review
/// caught — T-JSR-05 granted the Federal Circuit an unconditional national match
/// (its reach is subject-matter dependent and must fail closed), and T-JSR-07/08
/// read one symmetric "federal family" relation where the two directions differ
/// legally. The file now gates the directional `AuthorityRelationship` API; the
/// containment regressions the original file retired are preserved unchanged in
/// meaning.
///
/// Expected RED for the file: `relationship(...)`/`AuthorityRelationship` do not
/// exist, so the file does not compile. T-JSR-05/07/08 additionally record their
/// revised behavioral expectations below.
final class JurisdictionScopeResolverTests: XCTestCase {
    private let resolver = JurisdictionScopeResolver()

    // MARK: - Fails open under containment: one jurisdiction is a substring of another

    /// T-JSR-01. RED under containment: `"arkansas".contains("kansas")` is true, so an
    /// Arkansas authority silently satisfies a Kansas matter.
    func testSubstringStateNameIsNotWithinScope() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "Kansas",
                authorityCourt: "Supreme Court of Arkansas",
                authorityJurisdiction: "Arkansas",
                authorityCourtID: nil
            ),
            .outsideScope
        )
    }

    /// T-JSR-02. RED under containment: `"west virginia".contains("virginia")`.
    func testWestVirginiaIsNotWithinVirginiaScope() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "Virginia",
                authorityCourt: "Supreme Court of Appeals of West Virginia",
                authorityJurisdiction: "West Virginia",
                authorityCourtID: nil
            ),
            .outsideScope
        )
    }

    // MARK: - Notation variance resolves to identity

    /// T-JSR-03. RED under containment: `uscourtofappealsforthe11thcircuit` and
    /// `unitedstatescourtofappealsfortheeleventhcircuit` contain neither each other
    /// nor the `ca11` courtID, so a correct Eleventh Circuit authority is flagged.
    func testAbbreviatedCircuitNotationIsSameCourt() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "U.S. Court of Appeals for the 11th Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: "ca11"
            ),
            .sameCourt
        )
    }

    /// T-JSR-12 (wire-proof for the canonical key, §3.1). Both spellings must resolve
    /// to the *same* catalog option — asserted by identity, not by "both non-nil".
    /// RED under containment: there is no resolution step at all.
    func testCircuitNotationVariantsResolveToTheSameCatalogOption() throws {
        let spelled = try XCTUnwrap(
            resolver.resolvedOptionID(forCourtName: "United States Court of Appeals for the Eleventh Circuit")
        )
        let abbreviated = try XCTUnwrap(
            resolver.resolvedOptionID(forCourtName: "U.S. Court of Appeals for the 11th Circuit")
        )
        XCTAssertEqual(abbreviated, spelled)
        // Non-default value: pin the actual option, so a resolver that maps every
        // input to one sentinel cannot pass.
        XCTAssertEqual(
            JurisdictionCatalog.shared.option(id: spelled)?.courtListenerIDs,
            ["ca11"]
        )
    }

    // MARK: - Nationally binding vs subject-limited national authority

    /// T-JSR-04. SCOTUS is the federal `.supreme` catalog option and controls every
    /// resolvable forum — a directional relation, not a generic "within scope".
    func testSupremeCourtControlsEveryScope() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "Supreme Court of the United States",
                authorityJurisdiction: nil,
                authorityCourtID: "scotus"
            ),
            .controllingSuperior
        )
    }

    /// T-JSR-05 — REVISED (was: Federal Circuit `.withinScope` for a Ninth Circuit
    /// forum). The review caught the test, not just the code: 28 U.S.C. § 1295 makes
    /// the Federal Circuit's national reach SUBJECT-MATTER dependent, so absent
    /// established subject matter the relationship is `.subjectMatterDependent` and
    /// consumers fail closed. The metadata-poor saved-record shape (court name only,
    /// no courtID, no "United States" prefix) is retained from the original test.
    /// Behavioral RED: the old rule returns an unconditional match.
    func testFederalCircuitWithoutCourtIDIsSubjectMatterDependent() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "United States Court of Appeals for the Ninth Circuit",
                authorityCourt: "Court of Appeals for the Federal Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .subjectMatterDependent
        )
    }

    /// T-JSR-06. A sister regional circuit is still out of scope.
    func testSisterRegionalCircuitIsOutsideScope() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "United States Court of Appeals for the Ninth Circuit",
                authorityCourt: "United States Court of Appeals for the Fifth Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: "ca5"
            ),
            .outsideScope
        )
    }

    // MARK: - Federal/state relations are directional

    /// T-JSR-07 — REVISED (was: generic `.withinScope`). A federal district court
    /// sitting in the expected state applies that state's law: geographically related,
    /// in that direction — not part of the state's own hierarchy and not controlling.
    func testFederalDistrictCourtSittingInExpectedStateIsGeographicallyRelated() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "Florida",
                authorityCourt: "United States District Court for the Southern District of Florida",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .geographicallyRelated(.federalAuthorityInExpectedState)
        )
    }

    /// T-JSR-08 — REVISED (was: generic `.withinScope`). A district court under the
    /// expected circuit is within that circuit's federal family — but an inferior
    /// court's decision is not controlling authority, so the relation is
    /// `.sameFederalFamily`, never `.controllingSuperior`.
    func testDistrictCourtUnderExpectedCircuitIsSameFederalFamily() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "United States District Court for the Southern District of Florida",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .sameFederalFamily
        )
    }

    /// T-JSR-09. Same-state court within a state scope: same state, noncontrolling.
    func testStateAppellateCourtIsSameStateNoncontrolling() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "California",
                authorityCourt: "California Court of Appeal",
                authorityJurisdiction: "California",
                authorityCourtID: nil
            ),
            .sameStateNoncontrolling
        )
    }

    /// T-JSR-10. Sister state remains out of scope.
    func testSisterStateCourtIsOutsideScope() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "California",
                authorityCourt: "New York Court of Appeals",
                authorityJurisdiction: "New York",
                authorityCourtID: nil
            ),
            .outsideScope
        )
    }

    // MARK: - Unresolvable input

    /// T-JSR-11. Neither side is in the catalog: the resolver must say so rather than
    /// guess, so the caller can apply its own fail-closed fallback (SPEC §3.3).
    func testUnknownJurisdictionsAreIndeterminate() {
        XCTAssertEqual(
            resolver.relationship(
                expected: "Freedonia",
                authorityCourt: "High Court of Ruritania",
                authorityJurisdiction: "Ruritania",
                authorityCourtID: nil
            ),
            .indeterminate
        )
    }
}
