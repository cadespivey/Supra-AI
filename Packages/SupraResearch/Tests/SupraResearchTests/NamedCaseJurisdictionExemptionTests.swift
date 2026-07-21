import SupraResearch
import XCTest

/// Phase 3 (I-FIXME-1): the named-case jurisdiction exemption must be scoped to the
/// case the question named and its own forum — not applied to the whole packet.
///
/// Today the caller expresses the exemption by passing `expectedJurisdiction: nil`
/// whenever the classification carries a `citationLookup`, which switches the
/// jurisdiction check off for EVERY cited authority. Because that `citationLookup`
/// can be *synthesized* from history by the anaphora heuristic, a misfire silently
/// disables the gate for an entire answer. `jurisdiction_mismatch` is a hard
/// verification failure on the default legal routes, so this is a fail-open on a
/// hard gate — the SPEC's cautionary template.
///
/// Expected RED for every test here: `verify` has no `namedAuthorityLookup`
/// parameter, so the file does not compile. Each case also records the behavioral
/// RED reason it would fail for if the parameter existed but were ignored.
final class NamedCaseJurisdictionExemptionTests: XCTestCase {
    private func sixthCircuitNamedCase() -> LegalAuthority {
        LegalAuthority(
            id: "courtlistener:opinion:named-ca6",
            authorityType: .case,
            caseName: "Sixth v. Circuit",
            citation: "900 F.2d 100",
            citations: ["900 F.2d 100"],
            court: "United States Court of Appeals for the Sixth Circuit",
            courtID: "ca6",
            text: "The court held that the limitations period runs from discovery."
        )
    }

    private func sixthCircuitNeighbor() -> LegalAuthority {
        LegalAuthority(
            id: "courtlistener:opinion:neighbor-ca6",
            authorityType: .case,
            caseName: "Neighbor v. Sixth",
            citation: "901 F.2d 200",
            citations: ["901 F.2d 200"],
            court: "United States Court of Appeals for the Sixth Circuit",
            courtID: "ca6",
            text: "The court applied the same discovery rule."
        )
    }

    private func unrelatedCaliforniaCase() -> LegalAuthority {
        LegalAuthority(
            id: "courtlistener:opinion:unrelated-ca",
            authorityType: .case,
            caseName: "Cal v. Ifornia",
            citation: "1 Cal. 5th 1",
            citations: ["1 Cal. 5th 1"],
            court: "Supreme Court of California",
            jurisdiction: "California",
            text: "An unrelated state holding."
        )
    }

    /// T-JANA-01. The named case is exempt — the matter's forum must not veto quoting
    /// the very case the question asked about — but an unrelated out-of-forum authority
    /// cited in the same answer is still flagged.
    ///
    /// Behavioral RED if the parameter were ignored: with `expectedJurisdiction`
    /// actually applied, the named Sixth Circuit case is itself flagged, so the first
    /// assertion fails.
    func testNamedCaseIsExemptButUnrelatedForeignAuthorityIsFlagged() {
        let named = sixthCircuitNamedCase()
        let unrelated = unrelatedCaliforniaCase()
        let answer = """
        Sixth v. Circuit, 900 F.2d 100, held that the limitations period runs from \
        discovery. Cal v. Ifornia, 1 Cal. 5th 1, is also cited.
        """
        let report = LegalCitationVerifier.verify(
            answer: answer,
            authorities: [named, unrelated],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: "Sixth v. Circuit, 900 F.2d 100"
        )
        XCTAssertFalse(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("900 F.2d") ?? false)
            },
            "the case the question named must not be flagged for the matter's forum"
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("Cal. 5th") ?? false)
            },
            "an unrelated out-of-forum authority must still be flagged"
        )
    }

    /// T-JANA-02. Authorities sharing the named case's forum are exempt too: asking
    /// about a Sixth Circuit case has to let the answer cite that case's own line of
    /// authority, which is why the blanket exemption was introduced in the first place.
    ///
    /// Behavioral RED if the parameter were ignored: the neighbor is flagged.
    func testAuthorityInTheNamedCasesForumIsExempt() {
        let named = sixthCircuitNamedCase()
        let neighbor = sixthCircuitNeighbor()
        let answer = """
        Sixth v. Circuit, 900 F.2d 100, held that the limitations period runs from \
        discovery, and Neighbor v. Sixth, 901 F.2d 200, applied the same rule.
        """
        let report = LegalCitationVerifier.verify(
            answer: answer,
            authorities: [named, neighbor],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: "Sixth v. Circuit, 900 F.2d 100"
        )
        XCTAssertFalse(
            report.issues.contains { $0.kind == .jurisdictionMismatch },
            report.issues.map(\.message).joined(separator: "; ")
        )
    }

    /// T-JANA-03. The exemption is anchored to an authority that is actually in the
    /// packet. A lookup that resolves to nothing — the anaphora heuristic inheriting a
    /// stale citation from an older turn — must NOT silently exempt the whole answer.
    /// This is the fail-open being closed.
    ///
    /// Behavioral RED if the parameter were ignored, or implemented as "any lookup
    /// disables the check": no issue is emitted and the assertion fails.
    func testUnresolvableNamedLookupDoesNotExemptTheWholeAnswer() {
        let unrelated = unrelatedCaliforniaCase()
        let report = LegalCitationVerifier.verify(
            answer: "Cal v. Ifornia, 1 Cal. 5th 1, states the controlling rule.",
            authorities: [unrelated],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: "Stale v. Citation, 999 F.3d 999"
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("Cal. 5th") ?? false)
            },
            "a named-case lookup matching no retrieved authority must not disable the gate"
        )
    }

    /// T-JANA-04. With no named case at all, every authority is checked as before —
    /// the exemption must not leak into ordinary questions.
    func testWithoutANamedCaseEveryAuthorityIsChecked() {
        let named = sixthCircuitNamedCase()
        let report = LegalCitationVerifier.verify(
            answer: "Sixth v. Circuit, 900 F.2d 100, states the controlling rule.",
            authorities: [named],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: nil
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("900 F.2d") ?? false)
            },
            "without a named case the ordinary jurisdiction check applies"
        )
    }
}
