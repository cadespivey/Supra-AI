import SupraResearch
import XCTest

/// Phase 3 (I-FIXME-1), tightened by Phase 3C (review finding #2): the named-case
/// jurisdiction exemption must be scoped to EXACTLY the case the question named —
/// its authority ID and packet records the same lookup strictly resolves to — never
/// to the whole packet, and never to authorities that merely share the named case's
/// court or derived forum.
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

    /// T-JANA-02 — REVISED in the Phase 3C RED commit (review finding #2, methodology
    /// §3.5). This test previously asserted that authorities merely SHARING the named
    /// case's forum are exempt — the forum-neighborhood expansion the review ordered
    /// removed: it exempted whole swaths of out-of-forum authority (including, via the
    /// symmetric federal-family relation, an Ohio Supreme Court case "sharing" a Sixth
    /// Circuit forum). The exemption is now exact: the named authority's ID and packet
    /// records the same lookup strictly resolves to. A different case from the same
    /// court is out-of-forum authority like any other and must be flagged.
    ///
    /// Behavioral RED: today the neighbor is exempted, so no issue is emitted.
    func testAuthorityMerelySharingTheNamedCasesForumIsFlagged() {
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
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("900 F.2d") ?? false)
            },
            "the named case itself stays exempt"
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("901 F.2d") ?? false)
            },
            "a different case from the named case's court is not exempt: \(report.issues.map(\.message))"
        )
    }

    /// T-JANA-05. The exemption extends to ALIASES of the named case — packet records
    /// the same lookup strictly resolves to (e.g. the same opinion appearing twice
    /// under different provider IDs) — and no further.
    ///
    /// Standing guard on the alias half (the duplicate is exempt today via the broader
    /// rule and must remain exempt under the exact rule); the second assertion is RED
    /// with T-JANA-02 (the neighbor is wrongly exempt today).
    func testAliasRecordsOfTheNamedCaseAreExemptButNeighborsAreNot() {
        let named = sixthCircuitNamedCase()
        let alias = LegalAuthority(
            id: "courtlistener:opinion:named-ca6-duplicate",
            authorityType: .case,
            caseName: "Sixth v. Circuit",
            citation: "900 F.2d 100",
            citations: ["900 F.2d 100"],
            court: "United States Court of Appeals for the Sixth Circuit",
            courtID: "ca6",
            text: "The court held that the limitations period runs from discovery."
        )
        let neighbor = sixthCircuitNeighbor()
        let report = LegalCitationVerifier.verify(
            answer: """
            Sixth v. Circuit, 900 F.2d 100, held that the limitations period runs from \
            discovery, and Neighbor v. Sixth, 901 F.2d 200, applied the same rule.
            """,
            authorities: [named, alias, neighbor],
            expectedJurisdiction: "Florida",
            namedAuthorityLookup: "Sixth v. Circuit, 900 F.2d 100"
        )
        XCTAssertFalse(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("900 F.2d") ?? false)
            },
            "records resolving to the named case (including duplicates) stay exempt"
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("901 F.2d") ?? false)
            },
            "the exact-alias exemption must not leak to forum neighbors: \(report.issues.map(\.message))"
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
