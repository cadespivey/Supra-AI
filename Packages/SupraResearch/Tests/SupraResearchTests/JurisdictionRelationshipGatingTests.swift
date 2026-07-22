import SupraResearch
import XCTest

/// Phase 3C (corrective safety slice, review finding #2 — critical): the generic
/// `.withinScope` verdict collapses legally distinct authority relationships, and two
/// of those collapses fail open on the hard jurisdiction gate:
///
/// 1. The Federal Circuit is treated as unconditionally nationally binding (R1), but
///    28 U.S.C. § 1295 makes its reach SUBJECT-MATTER dependent. With no qualifying
///    subject matter established, a Federal Circuit authority cited for a Ninth
///    Circuit question must fail closed to a flag — not receive a silent match.
/// 2. The symmetric federal/state family rule (R5) reads a state court as part of its
///    geographically overlapping federal circuit hierarchy. It is not: a state
///    supreme court cited for a federal-circuit question must be flagged. The same
///    symmetric rule also powers the named-case forum-neighborhood exemption, which
///    exempts authorities that merely share a derived forum with the named case.
///
/// These tests gate through the EXISTING `LegalCitationVerifier.verify` API, so every
/// RED is an observable assertion failure on the parent commit. The directional
/// `AuthorityRelationship` table gates live in `AuthorityRelationshipTests.swift`.
final class JurisdictionRelationshipGatingTests: XCTestCase {

    // MARK: - Federal Circuit is subject-matter dependent (expected RED)

    /// T-JREL-01. Expected RED: rule R1 (`isNationallyBinding` includes `cafc`) grants
    /// the Federal Circuit an unconditional jurisdiction match everywhere, so no
    /// `jurisdiction_mismatch` issue is emitted for a Ninth Circuit question with no
    /// patent or other Federal Circuit subject matter established.
    func testFederalCircuitAuthorityFailsClosedWithoutSubjectMatter() {
        let cafc = LegalAuthority(
            id: "courtlistener:opinion:synthetic-cafc",
            authorityType: .case,
            caseName: "Synth v. Etic",
            citation: "800 F.3d 1350",
            citations: ["800 F.3d 1350"],
            court: "United States Court of Appeals for the Federal Circuit",
            courtID: "cafc",
            text: "The court held that the notice requirement applies to all filings."
        )
        let report = LegalCitationVerifier.verify(
            answer: "Synth v. Etic, 800 F.3d 1350, held that the notice requirement applies to all filings [A1].",
            authorities: [cafc],
            expectedJurisdiction: "United States Court of Appeals for the Ninth Circuit"
        )
        XCTAssertTrue(
            report.issues.contains { $0.kind == .jurisdictionMismatch },
            "Federal Circuit authority must fail closed when no qualifying subject matter is established: \(report.issues.map(\.message))"
        )
    }

    // MARK: - A state court is not part of its overlapping federal hierarchy (expected RED)

    /// T-JREL-02. Expected RED: symmetric R5 reads the Florida Supreme Court as within
    /// the Eleventh Circuit's scope (the state sits in the circuit's footprint), so no
    /// issue is emitted for a state authority cited on a federal-circuit question.
    func testStateCourtIsFlaggedForAFederalCircuitQuestion() {
        let flaSupreme = LegalAuthority(
            id: "courtlistener:opinion:synthetic-fla",
            authorityType: .case,
            caseName: "Alpha v. Beta",
            citation: "300 So. 3d 100",
            citations: ["300 So. 3d 100"],
            court: "Supreme Court of Florida",
            jurisdiction: "Florida",
            text: "The court held that the notice requirement applies to all filings."
        )
        let report = LegalCitationVerifier.verify(
            answer: "Alpha v. Beta, 300 So. 3d 100, held that the notice requirement applies [A1].",
            authorities: [flaSupreme],
            expectedJurisdiction: "United States Court of Appeals for the Eleventh Circuit"
        )
        XCTAssertTrue(
            report.issues.contains { $0.kind == .jurisdictionMismatch },
            "a state court is not part of its geographically overlapping federal circuit hierarchy: \(report.issues.map(\.message))"
        )
    }

    // MARK: - Named-case exemption is exact, not forum-wide (expected RED)

    /// T-JREL-03. The review's reproduction: Florida requested, a named Sixth Circuit
    /// case, and an additional Ohio Supreme Court authority. Expected RED: the
    /// forum-neighborhood exemption derives the named case's forum (ca6), and the Ohio
    /// aggregate's federal family CONTAINS ca6 under symmetric R5 — so the Ohio
    /// authority is silently exempted. It must be flagged; only the named case itself
    /// (and records resolving to that same case) are exempt.
    func testOhioAuthorityIsNotExemptedByANamedSixthCircuitCase() {
        let named = LegalAuthority(
            id: "courtlistener:opinion:named-ca6",
            authorityType: .case,
            caseName: "Sixth v. Circuit",
            citation: "900 F.2d 100",
            citations: ["900 F.2d 100"],
            court: "United States Court of Appeals for the Sixth Circuit",
            courtID: "ca6",
            text: "The court held that the limitations period runs from discovery."
        )
        let ohio = LegalAuthority(
            id: "courtlistener:opinion:synthetic-ohio",
            authorityType: .case,
            caseName: "Gamma v. Delta",
            citation: "150 Ohio St. 3d 200",
            citations: ["150 Ohio St. 3d 200"],
            court: "Supreme Court of Ohio",
            jurisdiction: "Ohio",
            text: "The court applied the discovery rule to the limitations period."
        )
        let report = LegalCitationVerifier.verify(
            answer: """
            Sixth v. Circuit, 900 F.2d 100, held that the limitations period runs from \
            discovery. Gamma v. Delta, 150 Ohio St. 3d 200, applied the same rule.
            """,
            authorities: [named, ohio],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: "Sixth v. Circuit, 900 F.2d 100"
        )
        XCTAssertFalse(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("900 F.2d") ?? false)
            },
            "the case the question named stays exempt"
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("Ohio St.") ?? false)
            },
            "an authority that merely relates to the named case's derived forum must be flagged: \(report.issues.map(\.message))"
        )
    }

    // MARK: - Standing guards (green on parent, justified per methodology §2)

    /// T-JREL-04. Standing guard: a federal court sitting in the requested STATE
    /// remains acceptable (it applies that state's law) — the R5 correction is
    /// directional and must not start flagging this direction.
    func testFederalDistrictInRequestedStateIsStillNotFlagged() {
        let flsd = LegalAuthority(
            id: "courtlistener:opinion:synthetic-flsd",
            authorityType: .case,
            caseName: "Epsilon v. Zeta",
            citation: "500 F. Supp. 3d 1200",
            citations: ["500 F. Supp. 3d 1200"],
            court: "United States District Court for the Southern District of Florida",
            text: "The court held that the notice requirement applies to all filings."
        )
        let report = LegalCitationVerifier.verify(
            answer: "Epsilon v. Zeta, 500 F. Supp. 3d 1200, held that the notice requirement applies [A1].",
            authorities: [flsd],
            expectedJurisdiction: "Florida"
        )
        XCTAssertFalse(
            report.issues.contains { $0.kind == .jurisdictionMismatch },
            "a federal court sitting in the requested state applies its law: \(report.issues.map(\.message))"
        )
    }

    /// T-JREL-05. Standing guard: SCOTUS remains controlling everywhere.
    func testSupremeCourtIsStillNotFlagged() {
        let scotus = LegalAuthority(
            id: "courtlistener:opinion:synthetic-scotus",
            authorityType: .case,
            caseName: "Eta v. Theta",
            citation: "590 U.S. 100",
            citations: ["590 U.S. 100"],
            court: "Supreme Court of the United States",
            courtID: "scotus",
            text: "The Court held that the notice requirement applies to all filings."
        )
        let report = LegalCitationVerifier.verify(
            answer: "Eta v. Theta, 590 U.S. 100, held that the notice requirement applies [A1].",
            authorities: [scotus],
            expectedJurisdiction: "United States Court of Appeals for the Ninth Circuit"
        )
        XCTAssertFalse(
            report.issues.contains { $0.kind == .jurisdictionMismatch },
            report.issues.map(\.message).joined(separator: "; ")
        )
    }
}
