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

    func testSpelledOutSectionCitationIsExtracted() {
        // "Florida Statutes section 95.11" (no §) must be a citation lookup so a
        // question pinpointing it is treated as statutory; bare "code section"
        // prose without a number must not be.
        let spelled = LegalQueryClassifier.classify("What does Florida Statutes section 95.11 provide?")
        XCTAssertEqual(spelled.citationLookup, "Florida Statutes section 95.11")
        XCTAssertEqual(spelled.desiredAuthorityType, .statute)

        let prose = LegalQueryClassifier.classify("Does the code section apply here?")
        XCTAssertNil(prose.citationLookup)
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
        // The exact cite goes to the LINK SERVICE first; with no resolution
        // available the lookup falls back to search — either way govinfo runs.
        XCTAssertEqual(recorder.resolvedCites.count, 1)
        XCTAssertEqual(recorder.resolvedCites.first?.title, 18)
        XCTAssertEqual(recorder.resolvedCites.first?.section, "1001")
        XCTAssertEqual(recorder.searchTerms.count, 1, "federal cite must reach govinfo despite the state jurisdiction")

        // Without a federal cite, the state gate still applies.
        _ = await source.lookup(StatutoryQuery(
            terms: "sovereign immunity waiver",
            jurisdiction: "Florida",
            citation: nil,
            limit: 3
        ))
        XCTAssertEqual(recorder.searchTerms.count, 1, "state-only statutory query must still skip govinfo")
    }

    func testGovInfoExactCiteResolvesThroughLinkServiceWithoutSearch() async throws {
        // The link service resolves an exact cite deterministically — no search,
        // no API key — and yields citable official section text.
        let recorder = RecordingGovInfoClient()
        recorder.resolution = GovInfoResolvedSection(
            packageId: "USCODE-2024-title18",
            granuleId: "USCODE-2024-title18-partI-chap47-sec1001",
            editionYear: "2024",
            rawHTML: "<html><body>§ 1001. Statements or entries generally. Whoever knowingly and willfully falsifies a material fact shall be fined under this title.</body></html>"
        )
        let source = GovInfoStatutorySource(client: recorder)

        let result = await source.lookup(StatutoryQuery(
            terms: "what does 18 U.S.C. § 1001 require",
            jurisdiction: nil,
            citation: "18 U.S.C. § 1001",
            limit: 3
        ))

        XCTAssertTrue(recorder.searchTerms.isEmpty, "an exact-cite resolution must skip search entirely")
        let provision = try XCTUnwrap(result.provisions.first)
        XCTAssertEqual(provision.citation, "18 U.S.C. § 1001")
        XCTAssertTrue(provision.isCitableAuthority)
        XCTAssertTrue(provision.text.contains("Statements or entries"))
        XCTAssertEqual(provision.effectiveDate, "2024")
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

    // MARK: - Quote checks on text-less packets

    func testQuoteAgainstTextlessPacketIsUnverifiableNotFabricated() {
        // A packet restored after an app restart carries no opinion text; a
        // genuine quote must be reported "unverifiable", never "fabricated".
        let bare = LegalAuthority(
            id: "1",
            source: .courtlistener,
            authorityType: .case,
            caseName: "Sniadach v. Family Finance Corp.",
            citation: "395 U.S. 337",
            citations: ["395 U.S. 337"]
        )
        let answer = "The Court held that \"prejudgment garnishment without notice violates due process\" (Sniadach v. Family Finance Corp.) [A1]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [bare], expectedJurisdiction: nil)
        XCTAssertTrue(report.issues.contains { $0.kind == .unverifiableQuote }, "\(report.issues)")
        XCTAssertFalse(report.issues.contains { $0.kind == .unsupportedQuote }, "\(report.issues)")
    }

    func testFabricatedQuoteStillFlaggedWhenTextIsPresent() {
        var grounded = caseAuthority(name: "Sniadach v. Family Finance Corp.", citations: ["395 U.S. 337"])
        grounded.text = String(repeating: "The wage garnishment procedure at issue denied the debtor notice and a prior hearing. ", count: 5)
        let answer = "The Court held that \"a completely invented sentence that appears nowhere\" (Sniadach v. Family Finance Corp.) [A1]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [grounded], expectedJurisdiction: nil)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedQuote }, "\(report.issues)")
        XCTAssertFalse(report.issues.contains { $0.kind == .unverifiableQuote }, "\(report.issues)")
    }

    // MARK: - Statutory packet merge relevance

    private func provision(citation: String, heading: String, source: String) -> StatutoryProvision {
        StatutoryProvision(
            sourceID: source,
            sourceName: source,
            weightTier: .currencyVerifiable,
            jurisdictionID: source,
            jurisdictionName: "United States Code",
            citation: citation,
            heading: heading,
            snippet: heading,
            text: String(repeating: heading + ". ", count: 20),
            url: "https://example.test/\(source)",
            effectiveDate: "2024"
        )
    }

    func testCitedProvisionLeadsPacketOverTangentialArrival() {
        // The tangential eCFR regulation arrives FIRST (higher source tier);
        // the provision the user actually cited must still LEAD the packet.
        let tangential = provision(
            citation: "29 C.F.R. § 1910.132",
            heading: "Personal protective equipment general requirements",
            source: "ecfr"
        )
        let cited = provision(
            citation: "18 U.S.C. § 1001",
            heading: "Statements or entries generally",
            source: "govinfo"
        )
        let merged = StatutoryPacketMerge.merge(
            statutoryProvisions: [tangential, cited],
            rankedCases: [],
            jurisdictionLabel: "Federal",
            cap: 10,
            citation: "18 U.S.C. § 1001",
            queryTerms: "false statements liability"
        )
        XCTAssertTrue(merged.first?.authority.citation?.contains("18 U.S.C. § 1001") ?? false, "\(merged.map { $0.authority.citation ?? "?" })")

        // Without a cited provision, arrival (source-tier) order is preserved.
        let neutral = StatutoryPacketMerge.merge(
            statutoryProvisions: [tangential, cited],
            rankedCases: [],
            jurisdictionLabel: "Federal",
            cap: 10
        )
        XCTAssertTrue(neutral.first?.authority.citation?.contains("29 C.F.R. § 1910.132") ?? false)
    }

    func testNeighborSectionCannotStealTheCitationBoost() {
        // Token-boundary matching: § 672.201 must not +100 on a § 672.20 cite,
        // and a semicolon-joined multi-cite target must not manufacture digit
        // runs ("…201; 29…" ≠ § 2012).
        let exact = provision(citation: "Fla. Stat. § 672.20", heading: "Exact section", source: "olc")
        let neighbor = provision(citation: "Fla. Stat. § 672.201", heading: "Neighbor section", source: "olc")
        XCTAssertEqual(StatutoryPacketMerge.relevance(of: neighbor, citation: "Fla. Stat. § 672.20", queryTerms: ""), 0)
        XCTAssertEqual(StatutoryPacketMerge.relevance(of: exact, citation: "Fla. Stat. § 672.20", queryTerms: ""), 100)

        let unrelated = provision(citation: "18 U.S.C. § 2012", heading: "Unrelated", source: "govinfo")
        XCTAssertEqual(
            StatutoryPacketMerge.relevance(of: unrelated, citation: "29 U.S.C. § 201; 29 U.S.C. § 216(b)", queryTerms: ""),
            0
        )
        // A reporter cite riding in the citation target matches no provision.
        XCTAssertEqual(
            StatutoryPacketMerge.relevance(of: provision(citation: "Cal. Civ. Code § 320", heading: "H", source: "olc"), citation: "444 U.S. 320", queryTerms: ""),
            0
        )
    }

    // MARK: - Bluebook citation formatting + star pagination

    func testBluebookFormattingAcrossCourts() {
        let scotus = BluebookCitation(
            caseName: "Rush v. Savchuk, 444 U.S. 320",
            citation: "444 U.S. 320",
            court: "Supreme Court of the United States",
            courtID: "scotus",
            year: 1980
        )
        XCTAssertEqual(scotus.formatted(pinPages: (328, 328)), "Rush v. Savchuk, 444 U.S. 320, 328 (1980).")
        XCTAssertEqual(scotus.formatted(), "Rush v. Savchuk, 444 U.S. 320 (1980).")

        let circuit = BluebookCitation(
            caseName: "SunTrust Bank v. Houghton Mifflin Co.",
            citation: "268 F.3d 1257",
            court: "United States Court of Appeals for the Eleventh Circuit",
            year: 2001
        )
        XCTAssertEqual(
            circuit.formatted(pinPages: (1260, 1261)),
            "SunTrust Bank v. Houghton Mifflin Co., 268 F.3d 1257, 1260–61 (11th Cir. 2001)."
        )

        let district = BluebookCitation(
            caseName: "Adams v. Fritz Martin Cabinetry LLC",
            citation: "300 F. Supp. 3d 1300",
            court: "United States District Court for the Middle District of Florida",
            year: 2018
        )
        XCTAssertEqual(
            district.formatted(),
            "Adams v. Fritz Martin Cabinetry LLC, 300 F. Supp. 3d 1300 (M.D. Fla. 2018)."
        )

        let stateHigh = BluebookCitation(
            caseName: "Smith v. Jones",
            citation: "123 So. 3d 456",
            court: "Supreme Court of Florida",
            year: 2013
        )
        XCTAssertEqual(stateHigh.formatted(), "Smith v. Jones, 123 So. 3d 456 (Fla. 2013).")

        // Unknown court degrades to a year-only parenthetical, never a guess.
        let unknown = BluebookCitation(caseName: "In re Doe", citation: "77 X.Y.Z. 1", court: "Tribal Court of Appeals", year: 1999)
        XCTAssertEqual(unknown.formatted(), "In re Doe, 77 X.Y.Z. 1 (1999).")
    }

    func testFloridaDCAUsesFloridaStyleAbbreviation() {
        // Florida practitioners cite DCAs Florida-style: "(Fla. 1st DCA 2026)".
        let first = BluebookCitation(
            caseName: "Smith v. Jones",
            citation: "300 So. 3d 100",
            court: "District Court of Appeal of Florida, First District",
            year: 2026
        )
        XCTAssertEqual(first.formatted(), "Smith v. Jones, 300 So. 3d 100 (Fla. 1st DCA 2026).")

        let second = BluebookCitation(
            caseName: "Roe v. Coe",
            citation: "310 So. 3d 200",
            court: "Florida District Court of Appeal, Second District",
            year: 2021
        )
        XCTAssertEqual(second.courtAbbreviation, "Fla. 2d DCA")

        let third = BluebookCitation(
            caseName: "A v. B",
            citation: "320 So. 3d 300",
            court: "District Court of Appeal of Florida, 3rd District",
            year: 2020
        )
        XCTAssertEqual(third.courtAbbreviation, "Fla. 3d DCA")

        // District unknown → generic Bluebook form, never a guessed district.
        let unknownDistrict = BluebookCitation(
            caseName: "C v. D",
            citation: "330 So. 3d 400",
            court: "District Court of Appeal of Florida",
            year: 2019
        )
        XCTAssertEqual(unknownDistrict.courtAbbreviation, "Fla. Dist. Ct. App.")
    }

    func testAllCapsCaptionIsRecasedForTheCitation() {
        // Filing-style ALL-CAPS captions re-case to cite style…
        let capped = BluebookCitation(
            caseName: "ADAMS V. FRITZ MARTIN CABINETRY LLC, ET AL.",
            citation: "300 F. Supp. 3d 1300",
            court: "United States District Court for the Middle District of Florida",
            year: 2018
        )
        XCTAssertEqual(
            capped.formatted(),
            "Adams v. Fritz Martin Cabinetry LLC, et al., 300 F. Supp. 3d 1300 (M.D. Fla. 2018)."
        )

        XCTAssertEqual(BluebookCitation.recasedCaption("IN RE WINSHIP"), "In re Winship")
        XCTAssertEqual(BluebookCitation.recasedCaption("J.B. V. STATE OF FLORIDA"), "J.B. v. State of Florida")
        XCTAssertEqual(BluebookCitation.recasedCaption("BANK OF AMERICA, N.A. V. SMITH-JONES"), "Bank of America, N.A. v. Smith-Jones")
        XCTAssertEqual(BluebookCitation.recasedCaption("STATE EX REL. DOE V. ROE III"), "State ex rel. Doe v. Roe III")

        // …while mixed-case captions pass through untouched.
        XCTAssertEqual(
            BluebookCitation.recasedCaption("SunTrust Bank v. Houghton Mifflin Co."),
            "SunTrust Bank v. Houghton Mifflin Co."
        )
        XCTAssertEqual(BluebookCitation.recasedCaption("McDonald's Corp. v. Doe"), "McDonald's Corp. v. Doe")
    }

    func testFlaggBrosCaptionRecasesDespiteMixedEtAl() {
        // CourtListener's exact stored caption: the mixed "Et Al." particles
        // dilute the caps ratio, which used to defeat the recaser entirely.
        XCTAssertEqual(
            BluebookCitation.recasedCaption("FLAGG BROS., INC., Et Al. v. BROOKS Et Al."),
            "Flagg Bros., Inc., et al. v. Brooks et al."
        )
        // Agency acronyms survive a full recase.
        XCTAssertEqual(BluebookCitation.recasedCaption("NLRB V. JONES & LAUGHLIN STEEL CORP."), "NLRB v. Jones & Laughlin Steel Corp.")
        XCTAssertEqual(BluebookCitation.recasedCaption("SEC V. W.J. HOWEY CO."), "SEC v. W.J. Howey Co.")
    }

    func testJustiaPageHeadersYieldPinCites() {
        // Old SCOTUS records carry Justia-style "Page 436 U. S. 152" markers
        // (their plain_text is empty; text comes from stripped HTML).
        let text = "Syllabus text here. Page 436 U. S. 152 The State action doctrine requires more. Page 436 U. S. 157 A warehouseman's sale is not state action."
        let holding = (text as NSString).range(of: "warehouseman").location
        XCTAssertEqual(StarPagination.page(at: holding, in: text, firstPage: 149), 157)
        let earlier = (text as NSString).range(of: "doctrine").location
        XCTAssertEqual(StarPagination.page(at: earlier, in: text, firstPage: 149), 152)

        // Bare centered page lines count too.
        let dashText = "Intro words.\n-152-\nBody of page one hundred fifty-two."
        let offset = (dashText as NSString).range(of: "Body").location
        XCTAssertEqual(StarPagination.page(at: offset, in: dashText, firstPage: 149), 152)
    }

    func testStarPaginationPinLookup() {
        let text = "Intro before pagination. *321 The first page of substance. More words here. *322 Second page text with the holding language."
        let holdingOffset = (text as NSString).range(of: "holding language").location
        XCTAssertEqual(StarPagination.page(at: holdingOffset, in: text, firstPage: 320), 322)
        let earlyOffset = (text as NSString).range(of: "first page").location
        XCTAssertEqual(StarPagination.page(at: earlyOffset, in: text, firstPage: 320), 321)
        // Before any marker, or with no markers at all → nil (no guessed pin).
        XCTAssertNil(StarPagination.page(at: 3, in: text, firstPage: 320))
        XCTAssertNil(StarPagination.page(at: 50, in: "No pagination markers anywhere in this text.", firstPage: 320))
        // A stray "*3" footnote star is rejected by the first-page bound.
        XCTAssertNil(StarPagination.page(at: 30, in: "A footnote *3 reference only, way out of range.", firstPage: 320))

        // Selection spanning pages yields a range.
        let span = StarPagination.pages(
            forSelectionAt: (text as NSString).range(of: "first page").location,
            length: text.count - (text as NSString).range(of: "first page").location - 1,
            in: text,
            firstPage: 320
        )
        XCTAssertEqual(span?.0, 321)
        XCTAssertEqual(span?.1, 322)
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

/// GovInfo client that records search terms and link-service resolutions.
private final class RecordingGovInfoClient: GovInfoClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _searchTerms: [String] = []
    private var _resolvedCites: [(title: Int, section: String)] = []
    var searchTerms: [String] { lock.withLock { _searchTerms } }
    var resolvedCites: [(title: Int, section: String)] { lock.withLock { _resolvedCites } }
    var resolution: GovInfoResolvedSection?

    func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse {
        lock.withLock { _searchTerms.append(term) }
        return try JSONDecoder().decode(GovInfoSearchResponse.self, from: Data(#"{"results": []}"#.utf8))
    }

    func fetchGranuleText(packageId: String, granuleId: String) async throws -> String {
        throw GovInfoError.invalidResponse
    }

    func resolveUSCodeSection(title: Int, section: String) async throws -> GovInfoResolvedSection? {
        lock.withLock { _resolvedCites.append((title: title, section: section)) }
        return resolution
    }
}
