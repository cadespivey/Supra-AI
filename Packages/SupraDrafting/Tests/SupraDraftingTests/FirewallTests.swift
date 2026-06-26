import Foundation
import SupraDrafting
import SupraDraftingCore
import XCTest

/// Authority + fact firewall fixtures (MotionToDismiss §3.2 / LetterDemand §4) — the most
/// important safety invariants: no model-invented cite, no untraced fact, scrubbed propositions.
final class FirewallTests: XCTestCase {

    /// A citator that returns whatever it is told — lets us simulate "no authority found" and "hit".
    private struct StubCitator: CitatorClient {
        var hits: [CitatorHit]
        var validity: CiteValidity = .confirmed
        func find(proposition: ScrubbedProposition) async -> [CitatorHit] { hits }
        func validate(_ cite: CitationRef) async -> CiteValidity { validity }
    }

    // MARK: - Authority never invented (Decision B)

    func testNoAuthorityFound_ResolvesToPlaceholderNeverFabricated() async {
        let resolver = AuthorityResolver(citator: StubCitator(hits: []), threshold: 0.6)
        let outcome = await resolver.resolve(ScrubbedProposition(text: "MTD failure to state a claim standard"))
        XCTAssertEqual(outcome, .placeholder)
    }

    func testOnPointHit_ResolvesToThatCiteFromCourtListenerNeverModel() async {
        let hit = CitatorHit(cite: CitationRef(raw: "301 So. 3d 880"), snippet: "…", onPointScore: 0.92)
        let resolver = AuthorityResolver(citator: StubCitator(hits: [hit]), threshold: 0.6)
        let outcome = await resolver.resolve(ScrubbedProposition(text: "written instrument must be attached"))
        guard case let .cite(authority) = outcome else { return XCTFail("expected a cite") }
        XCTAssertEqual(authority.cite.raw, "301 So. 3d 880")
        XCTAssertEqual(authority.source, .courtListener)
        XCTAssertNotEqual(authority.source, .userSupplied)
    }

    func testBelowThresholdHit_FallsBackToPlaceholder() async {
        let weak = CitatorHit(cite: CitationRef(raw: "123 So. 3d 1"), snippet: "…", onPointScore: 0.3)
        let resolver = AuthorityResolver(citator: StubCitator(hits: [weak]), threshold: 0.6)
        let outcome = await resolver.resolve(ScrubbedProposition(text: "weakly related"))
        XCTAssertEqual(outcome, .placeholder, "a weak hit must not be passed off as on-point authority")
    }

    // MARK: - Firewall sanitize: strips model cites + untraced facts

    func testSanitizeReplacesUnverifiedCiteWithPlaceholder() {
        let section = GeneratedSection(
            blocks: [.paragraph("The standard is well settled.")],
            citesUsed: [CitationRef(raw: "999 So. 3d 999")],   // model-originated, not in authorities
            assertedFacts: []
        )
        let (repaired, followUps) = Firewall.sanitize(section, facts: [], authorities: [])
        XCTAssertEqual(repaired.citesUsed, [CitationRef(raw: "[cite]")])
        XCTAssertTrue(repaired.citesUsed.allSatisfy { $0.isPlaceholder })
        XCTAssertTrue(followUps.contains { $0.message.contains("999 So. 3d 999") })
    }

    func testSanitizeKeepsVerifiedCite() {
        let verified = VerifiedAuthority(cite: CitationRef(raw: "301 So. 3d 880"), snippet: "…", source: .courtListener)
        let section = GeneratedSection(
            blocks: [.paragraph("…")],
            citesUsed: [CitationRef(raw: "301 So. 3d 880")],
            assertedFacts: []
        )
        let (repaired, followUps) = Firewall.sanitize(section, facts: [], authorities: [verified])
        XCTAssertEqual(repaired.citesUsed, [CitationRef(raw: "301 So. 3d 880")])
        XCTAssertTrue(followUps.isEmpty)
    }

    func testSanitizeStripsUntracedFact() {
        let section = GeneratedSection(
            blocks: [.paragraph("The Vandelay contract dated 1/8/2099 is overdue [S9].")],
            citesUsed: [],
            assertedFacts: [FactRef(label: "[S9]")]   // not in facts
        )
        let realFacts = [GroundedFact(text: "Invoice unpaid", label: "[S1]", docId: "d1", locator: "p.1")]
        let (repaired, followUps) = Firewall.sanitize(section, facts: realFacts, authorities: [])
        XCTAssertFalse(repaired.assertedFacts.contains(FactRef(label: "[S9]")), "untraced fact must be stripped")
        XCTAssertTrue(followUps.contains { $0.message.contains("[S9]") })
    }

    func testSanitizeKeepsTracedFact() {
        let facts = [GroundedFact(text: "Invoice unpaid", label: "[S1]", docId: "d1", locator: "p.1")]
        let section = GeneratedSection(blocks: [.paragraph("…[S1]")], citesUsed: [], assertedFacts: [FactRef(label: "[S1]")])
        let (repaired, followUps) = Firewall.sanitize(section, facts: facts, authorities: [])
        XCTAssertEqual(repaired.assertedFacts, [FactRef(label: "[S1]")])
        XCTAssertTrue(followUps.isEmpty)
    }

    // MARK: - Verifier flags unverified cites / untraced facts (no regeneration)

    func testVerifierFlagsUntracedFactWithoutFabricating() async {
        let verifier = DraftVerifier()
        let section = GeneratedSection(blocks: [.paragraph("…[S5]")], citesUsed: [], assertedFacts: [FactRef(label: "[S5]")])
        let result = await verifier.verify(
            .section(section, requirement: SectionRequirement(section: .argument, mustContain: [], elementKeys: []),
                     facts: [GroundedFact(text: "x", label: "[S1]", docId: "d", locator: "p")], authorities: []),
            kind: .motionToDismiss, style: .defaultFL
        )
        XCTAssertTrue(result.failures.contains { $0.gate == .factProvenance && $0.repair == .stripToPlaceholderAndFlag })
    }

    // MARK: - Voice boundary (LetterDemand §4)

    func testVoiceContextIsToneOnlyForLetterAndNilForMotion() {
        // Letter: voice present, tone-only.
        let voice = LetterDemand.voiceContext(AssistantVoiceProfile(registerNotes: "formal, firm"))
        XCTAssertTrue(voice.toneOnly, "a grounded letter may mine tone only, never facts")
        // Motion's PromptParts carry NO voice — the contrast case.
        let motionParts = PromptParts(
            taskInstruction: "argue", voice: nil,
            sectionContract: SectionRequirement(section: .argument, mustContain: [], elementKeys: []),
            facts: [], authorities: [], decoding: .grounded
        )
        XCTAssertNil(motionParts.voice, "Auth sections carry no voice channel (§8.6)")
    }

    // MARK: - Scrub (the confidentiality line)

    func testScrubbedPropositionCarriesOnlyTheLegalIssue() throws {
        // The deterministic ground specs feed scrubbed propositions; assert they carry no party
        // names or matter facts (only the legal proposition).
        let ground = try MotionGroundSpec.knownGround(for: "failure to state a claim")
        for proposition in ground.authorityQueries {
            XCTAssertFalse(proposition.text.contains("Atlantic Ridge"))
            XCTAssertFalse(proposition.text.contains("Meridian"))
            XCTAssertFalse(proposition.text.contains("$"))
        }
    }
}
