import SupraResearch
import XCTest

/// Phase 3C (corrective safety slice, review finding #2): the directional
/// `AuthorityRelationship` model replacing the generic `.withinScope` verdict, which
/// collapsed same-tribunal, binding-superior, same-federal-family, same-state,
/// state/federal geographic overlap, subject-limited national jurisdiction, and
/// persuasive authority into one value. Every consumer must now choose explicitly
/// which relationships it accepts; symmetry exists only where legally appropriate
/// (aliases and exact same-court identity).
///
/// Expected RED for every test in this file: `AuthorityRelationship` and
/// `JurisdictionScopeResolver.relationship(...)` do not exist, so the file does not
/// compile (missing symbols named in the build log).
final class AuthorityRelationshipTests: XCTestCase {
    private let resolver = JurisdictionScopeResolver()

    private func relationship(
        expected: String,
        court: String? = nil,
        jurisdiction: String? = nil,
        courtID: String? = nil
    ) -> AuthorityRelationship {
        resolver.relationship(
            expected: expected,
            authorityCourt: court,
            authorityJurisdiction: jurisdiction,
            authorityCourtID: courtID
        )
    }

    // MARK: - Alias equivalence (symmetry IS legally appropriate here)

    /// T-REL-01. Notation variants of one court are the SAME court, in both
    /// directions.
    func testAliasNotationVariantsAreSameCourt() {
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                court: "U.S. Court of Appeals for the 11th Circuit",
                courtID: "ca11"
            ),
            .sameCourt
        )
        XCTAssertEqual(
            relationship(
                expected: "U.S. Court of Appeals for the 11th Circuit",
                court: "United States Court of Appeals for the Eleventh Circuit"
            ),
            .sameCourt
        )
    }

    /// T-REL-02. Identity property: a court is always `.sameCourt` with itself.
    func testSameCourtIdentityProperty() {
        let courts = [
            "Supreme Court of the United States",
            "United States Court of Appeals for the Eleventh Circuit",
            "United States District Court for the Southern District of Florida",
            "Supreme Court of Florida",
        ]
        for court in courts {
            XCTAssertEqual(
                relationship(expected: court, court: court),
                .sameCourt,
                "identity must hold for \(court)"
            )
        }
    }

    // MARK: - Federal hierarchy is directional

    /// T-REL-03. The circuit above a district is CONTROLLING; the district below its
    /// circuit is same-family but NOT controlling. The two directions must differ.
    func testCircuitDistrictHierarchyIsDirectional() {
        let circuit = "United States Court of Appeals for the Eleventh Circuit"
        let district = "United States District Court for the Southern District of Florida"
        XCTAssertEqual(
            relationship(expected: district, court: circuit),
            .controllingSuperior,
            "the circuit controls its districts"
        )
        XCTAssertEqual(
            relationship(expected: circuit, court: district),
            .sameFederalFamily,
            "a district under the expected circuit is family, not controlling authority"
        )
    }

    /// T-REL-04. Sibling districts in one state's federal family are family,
    /// not controlling.
    func testSiblingDistrictsAreSameFederalFamily() {
        XCTAssertEqual(
            relationship(
                expected: "United States District Court for the Middle District of Florida",
                court: "United States District Court for the Southern District of Florida"
            ),
            .sameFederalFamily
        )
    }

    /// T-REL-05. A sister regional circuit is simply outside scope.
    func testSisterCircuitIsOutsideScope() {
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Ninth Circuit",
                court: "United States Court of Appeals for the Fifth Circuit",
                courtID: "ca5"
            ),
            .outsideScope
        )
    }

    // MARK: - State hierarchy is directional

    /// T-REL-06. The state supreme court controls the state's other courts; a lower
    /// state court is same-state noncontrolling for a higher expected forum.
    func testStateHierarchyIsDirectional() {
        XCTAssertEqual(
            relationship(
                expected: "Third District Court of Appeal of Florida",
                court: "Supreme Court of Florida"
            ),
            .controllingSuperior
        )
        XCTAssertEqual(
            relationship(
                expected: "Supreme Court of Florida",
                court: "Third District Court of Appeal of Florida"
            ),
            .sameStateNoncontrolling
        )
        XCTAssertEqual(
            relationship(expected: "Florida", court: "Supreme Court of Florida"),
            .controllingSuperior,
            "the state supreme court controls the statewide forum"
        )
        XCTAssertEqual(
            relationship(expected: "Florida", court: "Third District Court of Appeal of Florida"),
            .sameStateNoncontrolling
        )
    }

    /// T-REL-06A. A CourtListener id owned by one precise tribunal must resolve to
    /// that tribunal, not the statewide aggregate that happens to appear first.
    func testStateSupremeCourtIDPreservesPreciseIdentity() {
        XCTAssertEqual(
            relationship(
                expected: "Third District Court of Appeal of Florida",
                courtID: "fla"
            ),
            .controllingSuperior
        )
    }

    /// T-REL-07. A sister state stays outside scope.
    func testSisterStateIsOutsideScope() {
        XCTAssertEqual(
            relationship(expected: "Florida", court: "Supreme Court of Ohio", jurisdiction: "Ohio"),
            .outsideScope
        )
    }

    // MARK: - State/federal geographic overlap: related, directional, never controlling

    /// T-REL-08. A federal court sitting in the expected state is geographically
    /// related (it applies that state's law); a state court inside the expected
    /// federal forum's footprint is geographically related in the OTHER direction —
    /// and is not part of the federal hierarchy. The directions must not collapse.
    func testGeographicOverlapIsDirectional() {
        XCTAssertEqual(
            relationship(
                expected: "Florida",
                court: "United States District Court for the Southern District of Florida"
            ),
            .geographicallyRelated(.federalAuthorityInExpectedState)
        )
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                court: "Supreme Court of Florida",
                jurisdiction: "Florida"
            ),
            .geographicallyRelated(.stateAuthorityInExpectedFederalFootprint)
        )
        XCTAssertEqual(
            relationship(expected: "Florida", court: "United States Court of Appeals for the Eleventh Circuit"),
            .geographicallyRelated(.federalAuthorityInExpectedState),
            "the state's own circuit is related to the state forum, not controlling for state law"
        )
    }

    // MARK: - SCOTUS

    /// T-REL-09. SCOTUS is controlling superior authority for every resolvable U.S.
    /// forum; the reverse direction is not.
    func testSupremeCourtControlsEveryForum() {
        for expected in [
            "United States Court of Appeals for the Eleventh Circuit",
            "United States District Court for the Southern District of Florida",
            "Florida",
        ] {
            XCTAssertEqual(
                relationship(expected: expected, court: "Supreme Court of the United States", courtID: "scotus"),
                .controllingSuperior,
                "SCOTUS controls \(expected)"
            )
        }
        XCTAssertEqual(
            relationship(
                expected: "Supreme Court of the United States",
                court: "United States Court of Appeals for the Eleventh Circuit",
                courtID: "ca11"
            ),
            .outsideScope,
            "a circuit is persuasive at most for a SCOTUS forum — never binding"
        )
    }

    // MARK: - Federal Circuit: subject-matter dependent, fail closed

    /// T-REL-10. The Federal Circuit's national reach is subject-limited
    /// (28 U.S.C. § 1295). Without established subject matter the relationship is
    /// `.subjectMatterDependent` — consumers fail closed — for any non-CAFC forum.
    /// Only the Federal Circuit itself yields `.sameCourt`.
    func testFederalCircuitIsSubjectMatterDependent() {
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Ninth Circuit",
                court: "Court of Appeals for the Federal Circuit"
            ),
            .subjectMatterDependent
        )
        XCTAssertEqual(
            relationship(expected: "Florida", court: "United States Court of Appeals for the Federal Circuit", courtID: "cafc"),
            .subjectMatterDependent
        )
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Federal Circuit",
                court: "Court of Appeals for the Federal Circuit",
                courtID: "cafc"
            ),
            .sameCourt
        )
    }

    // MARK: - Indeterminate catalog inputs fail closed

    /// T-REL-11. Unresolvable inputs are `.indeterminate` — never a guess — whether
    /// the unknown side is the authority, the expected forum, or both.
    func testUnresolvableInputsAreIndeterminate() {
        XCTAssertEqual(
            relationship(expected: "Freedonia", court: "High Court of Ruritania", jurisdiction: "Ruritania"),
            .indeterminate
        )
        XCTAssertEqual(
            relationship(expected: "Florida", court: "High Court of Ruritania", jurisdiction: "Ruritania"),
            .indeterminate
        )
        XCTAssertEqual(
            relationship(expected: "Freedonia", court: "Supreme Court of Florida"),
            .indeterminate
        )
    }

    /// T-REL-12. Independently resolvable identifiers that name different tribunals
    /// are malformed metadata. An id must not silently override the court name.
    func testConflictingCourtNameAndIDAreIndeterminate() {
        XCTAssertEqual(
            relationship(
                expected: "United States Court of Appeals for the Eleventh Circuit",
                court: "United States Court of Appeals for the Fifth Circuit",
                courtID: "ca11"
            ),
            .indeterminate
        )
    }
}
