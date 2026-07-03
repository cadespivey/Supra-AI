import XCTest
@testable import SupraResearch

/// Regression tests for the named-case/statute retrieval hardening: short-caption
/// matching, phantom-citation extraction, jurisdiction gating, and state-statute
/// citation verification.
final class GroundedRetrievalHardeningTests: XCTestCase {

    // MARK: - LegalCitationMatch

    private func caseAuthority(name: String, citations: [String] = []) -> LegalAuthority {
        LegalAuthority(
            id: name,
            source: .courtlistener,
            authorityType: .case,
            caseName: name,
            citation: citations.first,
            citations: citations
        )
    }

    func testShortCaptionMatchesFullStoredCaption() {
        let stored = caseAuthority(
            name: "SunTrust Bank v. Houghton Mifflin Co.",
            citations: ["268 F.3d 1257"]
        )
        XCTAssertTrue(LegalCitationMatch.authority(stored, matchesLookup: "SunTrust v. Houghton Mifflin"))
        XCTAssertTrue(LegalCitationMatch.authority(stored, matchesLookup: "268 F.3d 1257"))
        XCTAssertFalse(LegalCitationMatch.authority(stored, matchesLookup: "Rush v. Savchuk"))
    }

    func testFlippedCaptionStillMatches() {
        // Captions flip on appeal: Thomas v. Peacock below became Peacock v.
        // Thomas at the Supreme Court.
        let stored = caseAuthority(name: "Peacock v. Thomas", citations: ["516 U.S. 349"])
        XCTAssertTrue(LegalCitationMatch.authority(stored, matchesLookup: "Thomas v. Peacock"))
    }

    func testCaptionWithReporterTailMatches() {
        let stored = caseAuthority(name: "Rush v. Savchuk", citations: ["444 U.S. 320"])
        XCTAssertTrue(LegalCitationMatch.authority(stored, matchesLookup: "Rush v. Savchuk, 444 U.S. 320"))
    }

    func testInReCaptionMatching() {
        let stored = caseAuthority(name: "In re Winship", citations: ["397 U.S. 358"])
        XCTAssertTrue(LegalCitationMatch.authority(stored, matchesLookup: "In re Winship"))
        XCTAssertTrue(LegalCitationMatch.isCaseNameLookup("In re Winship"))
        XCTAssertFalse(LegalCitationMatch.isCaseNameLookup("444 U.S. 320"))
        XCTAssertTrue(LegalCitationMatch.isCaseNameLookup("Rush v. Savchuk"))
    }

    func testUnrelatedReporterCiteDoesNotMatch() {
        let stored = caseAuthority(name: "Rush v. Savchuk", citations: ["444 U.S. 320"])
        XCTAssertFalse(LegalCitationMatch.authority(stored, matchesLookup: "516 U.S. 349"))
    }

    // MARK: - Ranker citation boost

    func testRankerBoostsNamedCaseDespiteFullCaption() {
        // The stored record carries the FULL caption; the lookup is the short
        // name the lawyer typed. The named case must outrank topical results.
        var named = caseAuthority(
            name: "MacKey v. Lanier Collection Agency & Service, Inc.",
            citations: ["486 U.S. 825"]
        )
        named.court = "Supreme Court of the United States"
        named.text = String(repeating: "The opinion text of the named case, which happens not to repeat the issue phrasing. ", count: 20)
        var others: [LegalAuthority] = []
        for index in 0..<8 {
            var other = caseAuthority(name: "Garnishment Case \(index) v. Debtor \(index)", citations: [])
            other.court = "Supreme Court of the United States"
            other.text = String(repeating: "garnishment welfare benefit plan ", count: 40)
            others.append(other)
        }
        var classification = LegalQueryClassifier.classify("What is the holding of MacKey v. Lanier?")
        classification.legalIssue = "garnishment welfare benefit plan"
        XCTAssertNotNil(classification.citationLookup)

        let ranked = LegalAuthorityRanker.rank(others + [named], for: classification)
        XCTAssertEqual(ranked.first?.authority.id, named.id, "\(ranked.map(\.authority.id))")
        XCTAssertTrue(ranked.first?.reasons.contains("citation_match") ?? false)
    }

    // MARK: - Classifier extraction

    func testUSCWithoutPeriodsOrSectionSignIsStatutory() {
        let classification = LegalQueryClassifier.classify("What does 18 USC 1001 prohibit?")
        XCTAssertEqual(classification.desiredAuthorityType, .statute)
        XCTAssertEqual(classification.citationLookup, "18 USC 1001")
    }

    func testOrdinaryProseIsNotAPhantomCitation() {
        // "(?i)" on the generic reporter pattern used to turn prose into a
        // citation lookup, disabling the local tier and poisoning requests.
        let amendments = LegalQueryClassifier.classify("How did the 2019 amendments to rule 1.510 change summary judgment practice in Florida?")
        XCTAssertNil(amendments.citationLookup)

        let damages = LegalQueryClassifier.classify("Can punitive damages reach 3 times compensatory or 500 in Georgia?")
        XCTAssertNil(damages.citationLookup)
    }

    func testInReCitationExtractionSurvivesTailTrimming() {
        // " re " is a stop-phrase for tail comments — it must not truncate an
        // "In re" caption to "In".
        let classification = LegalQueryClassifier.classify("What is the holding of In re Winship?")
        XCTAssertEqual(classification.citationLookup, "In re Winship")
    }

    // MARK: - Source plan

    func testNamedCaseSatisfiesJurisdictionRequirement() {
        // "What is the holding of X v. Y?" pins its own court; the plan must not
        // demand a jurisdiction word before answering.
        let classification = LegalQueryClassifier.classify("What is the holding of Rush v. Savchuk?")
        XCTAssertNotNil(classification.citationLookup)
        let plan = LegalResearchSourcePlanner.plan(
            classification: classification,
            target: LegalSourceTarget(kind: .global)
        )
        XCTAssertTrue(plan.satisfiesJurisdictionRequirement)
    }

    // MARK: - Federal statutory sources in state matters

    func testReferencesFederalLawDetection() {
        XCTAssertTrue(StatutoryJurisdictionMapper.referencesFederalLaw(citation: "42 U.S.C. § 1983", terms: ""))
        XCTAssertTrue(StatutoryJurisdictionMapper.referencesFederalLaw(citation: nil, terms: "the standard under 29 CFR 1910.132"))
        XCTAssertFalse(StatutoryJurisdictionMapper.referencesFederalLaw(citation: "Fla. Stat. § 768.28", terms: "sovereign immunity waiver"))
    }

    func testGovInfoRunsForFederalCitationDespiteStateJurisdiction() async throws {
        // A U.S.C. question raised inside a Florida matter used to be silenced:
        // the state jurisdiction disabled every federal statutory source.
        let recorder = RecordingGovInfoClient()
        let source = GovInfoStatutorySource(client: recorder)

        _ = await source.lookup(StatutoryQuery(
            terms: "false statements liability",
            jurisdiction: "Florida",
            citation: "18 U.S.C. § 1001",
            limit: 3
        ))
        XCTAssertEqual(recorder.searchTerms.count, 1, "federal cite must reach govinfo despite the state jurisdiction")
        // And the exact cite — not the prose — is the search term.
        XCTAssertEqual(recorder.searchTerms.first, "18 U.S.C. § 1001")

        // Without a federal cite, the state gate still applies.
        _ = await source.lookup(StatutoryQuery(
            terms: "sovereign immunity waiver",
            jurisdiction: "Florida",
            citation: nil,
            limit: 3
        ))
        XCTAssertEqual(recorder.searchTerms.count, 1, "state-only statutory query must still skip govinfo")
    }

    // MARK: - Verifier state-statute citations

    private func statuteAuthority(citation: String, text: String) -> LegalAuthority {
        LegalAuthority(
            id: citation,
            source: .courtlistener,
            authorityType: .statute,
            caseName: citation,
            citation: citation,
            citations: [citation],
            snippet: text,
            text: text
        )
    }

    func testBluebookStateStatuteCiteMatchesProviderLabel() {
        let authority = statuteAuthority(
            citation: "Florida Statutes § 768.28",
            text: String(repeating: "The state waives sovereign immunity for tort liability as provided here. ", count: 10)
        )
        let answer = "Florida waives sovereign immunity in tort, subject to statutory caps. (Fla. Stat. § 768.28) [A1]"
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority], expectedJurisdiction: nil)
        XCTAssertFalse(
            report.issues.contains { $0.kind == .unsupportedCitation },
            "\(report.issues)"
        )
    }

    func testWrongSectionStillFlagged() {
        let authority = statuteAuthority(
            citation: "Florida Statutes § 768.28",
            text: String(repeating: "Sovereign immunity waiver text. ", count: 10)
        )
        let answer = "The limitations period is four years. (Fla. Stat. § 95.11) [A1]"
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority], expectedJurisdiction: nil)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation }, "\(report.issues)")
    }

    func testStateReferenceResolution() {
        XCTAssertEqual(StatutoryJurisdictionMapper.postalCode(forStateReference: "Fla."), "FL")
        XCTAssertEqual(StatutoryJurisdictionMapper.postalCode(forStateReference: "N.Y."), "NY")
        XCTAssertEqual(StatutoryJurisdictionMapper.postalCode(forStateReference: "Cal."), "CA")
        XCTAssertEqual(StatutoryJurisdictionMapper.postalCode(forStateReference: "W. Va."), "WV")
        XCTAssertEqual(StatutoryJurisdictionMapper.postalCode(forStateReference: "Florida"), "FL")
        XCTAssertNil(StatutoryJurisdictionMapper.postalCode(forStateReference: "United States"))
    }
}

/// GovInfo client that records search terms and returns no results.
private final class RecordingGovInfoClient: GovInfoClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _searchTerms: [String] = []
    var searchTerms: [String] { lock.withLock { _searchTerms } }

    func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse {
        lock.withLock { _searchTerms.append(term) }
        return try JSONDecoder().decode(GovInfoSearchResponse.self, from: Data(#"{"results": []}"#.utf8))
    }

    func fetchGranuleText(packageId: String, granuleId: String) async throws -> String {
        throw GovInfoError.invalidResponse
    }
}
