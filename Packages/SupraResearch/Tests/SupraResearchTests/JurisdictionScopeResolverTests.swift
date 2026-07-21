import SupraResearch
import XCTest

/// Phase 3a (jurisdiction-as-data): the verifier's jurisdiction check must decide
/// scope from the court-hierarchy catalog, not from string containment.
///
/// Expected RED for every test in this file: `JurisdictionScopeResolver` does not
/// exist, so the file does not compile. Each case additionally records the
/// behavioral RED reason it would fail for if the type existed as a `contains()`
/// shim — the containment rule these tests exist to retire.
final class JurisdictionScopeResolverTests: XCTestCase {
    private let resolver = JurisdictionScopeResolver()

    // MARK: - Fails open today: one jurisdiction is a substring of another

    /// T-JSR-01. RED under containment: `"arkansas".contains("kansas")` is true, so an
    /// Arkansas authority silently satisfies a Kansas matter.
    func testSubstringStateNameIsNotWithinScope() {
        XCTAssertEqual(
            resolver.verdict(
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
            resolver.verdict(
                expected: "Virginia",
                authorityCourt: "Supreme Court of Appeals of West Virginia",
                authorityJurisdiction: "West Virginia",
                authorityCourtID: nil
            ),
            .outsideScope
        )
    }

    // MARK: - Fails closed today: notation variance defeats containment

    /// T-JSR-03. RED under containment: `uscourtofappealsforthe11thcircuit` and
    /// `unitedstatescourtofappealsfortheeleventhcircuit` contain neither each other
    /// nor the `ca11` courtID, so a correct Eleventh Circuit authority is flagged.
    func testAbbreviatedCircuitNotationIsWithinScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "U.S. Court of Appeals for the 11th Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: "ca11"
            ),
            .withinScope
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

    // MARK: - Nationally binding authority, derived from catalog data (R1)

    /// T-JSR-04. Replaces the hand-maintained `isNationallyBinding` needle list: SCOTUS
    /// is the federal `.supreme` catalog option. RED: no resolver.
    func testSupremeCourtIsWithinEveryScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "Supreme Court of the United States",
                authorityJurisdiction: nil,
                authorityCourtID: "scotus"
            ),
            .withinScope
        )
    }

    /// T-JSR-05. The metadata-poor saved record: Federal Circuit by court name alone,
    /// no courtID, and missing the "United States" prefix the catalog carries.
    /// RED: no resolver; and canonicalization is what makes this resolvable at all.
    func testFederalCircuitWithoutCourtIDIsWithinScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "United States Court of Appeals for the Ninth Circuit",
                authorityCourt: "Court of Appeals for the Federal Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .withinScope
        )
    }

    /// T-JSR-06. The national-binding exemption must stay narrow — a sister regional
    /// circuit is still out of scope. RED: no resolver.
    func testSisterRegionalCircuitIsOutsideScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "United States Court of Appeals for the Ninth Circuit",
                authorityCourt: "United States Court of Appeals for the Fifth Circuit",
                authorityJurisdiction: nil,
                authorityCourtID: "ca5"
            ),
            .outsideScope
        )
    }

    // MARK: - Federal/state hierarchy relations (R3, R5)

    /// T-JSR-07. A federal district court sitting in the expected state applies that
    /// state's law; it is not a forum mismatch. RED: no resolver.
    func testFederalDistrictCourtSittingInExpectedStateIsWithinScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "Florida",
                authorityCourt: "United States District Court for the Southern District of Florida",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .withinScope
        )
    }

    /// T-JSR-08. A district court under the expected circuit is within that circuit's
    /// hierarchy. RED: no resolver.
    func testDistrictCourtUnderExpectedCircuitIsWithinScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                authorityCourt: "United States District Court for the Southern District of Florida",
                authorityJurisdiction: nil,
                authorityCourtID: nil
            ),
            .withinScope
        )
    }

    /// T-JSR-09. Same-state court within a state scope. RED: no resolver.
    func testStateAppellateCourtIsWithinItsOwnStateScope() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "California",
                authorityCourt: "California Court of Appeal",
                authorityJurisdiction: "California",
                authorityCourtID: nil
            ),
            .withinScope
        )
    }

    /// T-JSR-10. Sister state remains out of scope. RED: no resolver.
    func testSisterStateCourtIsOutsideScope() {
        XCTAssertEqual(
            resolver.verdict(
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
    /// RED: no resolver.
    func testUnknownJurisdictionsAreIndeterminate() {
        XCTAssertEqual(
            resolver.verdict(
                expected: "Freedonia",
                authorityCourt: "High Court of Ruritania",
                authorityJurisdiction: "Ruritania",
                authorityCourtID: nil
            ),
            .indeterminate
        )
    }
}
