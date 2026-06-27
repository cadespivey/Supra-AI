import Foundation
import SupraResearch
import XCTest

final class StatutoryOrchestrationTests: XCTestCase {

    // MARK: - Jurisdiction mapping

    func testMapsStateNameToStatutesCode() {
        XCTAssertEqual(
            StatutoryJurisdictionMapper.olcJurisdictionIDs(jurisdiction: "Florida", citation: nil, terms: "statute of frauds"),
            ["fl-statutes"]
        )
    }

    func testMapsFederalCitationToUSCTitle() {
        XCTAssertEqual(
            StatutoryJurisdictionMapper.olcJurisdictionIDs(jurisdiction: "Federal", citation: "42 U.S.C. § 1983", terms: "civil rights"),
            ["us-usc-title-42"]
        )
    }

    func testMapsMultipleFederalCitationsToAllUSCTitles() {
        XCTAssertEqual(
            StatutoryJurisdictionMapper.olcJurisdictionIDs(
                jurisdiction: "Federal",
                citation: "42 U.S.C. § 1651; 33 U.S.C. § 913",
                terms: "Defense Base Act limitations"
            ),
            ["us-usc-title-42", "us-usc-title-33"]
        )
    }

    func testFederalCourtWithoutTitleMapsToNothing() {
        XCTAssertTrue(
            StatutoryJurisdictionMapper.olcJurisdictionIDs(jurisdiction: "Ninth Circuit", citation: nil, terms: "qualified immunity").isEmpty
        )
    }

    // MARK: - OLC source (best-effort, caveated)

    func testOLCSourceReturnsCaveatedConvenienceProvisions() async throws {
        let json = """
        {"data":{"jurisdiction":"fl-statutes","jurisdictionName":"Florida Statutes","query":"statute of frauds","results":[{"path":"title-xxxix/chapter-672/section-672.201","num":"§ 672.201","heading":"Statute of frauds","snippet":"a contract for the sale of goods for $500 or more...","url":"https://openlegalcodes.org/fl/672.201"}]},"meta":{}}
        """
        let results = try JSONDecoder().decode(OLCEnvelope<OLCSearchResults>.self, from: Data(json.utf8)).data
        let source = OpenLegalCodesStatutorySource(client: StubOLCClient(search: .success(results)), hydrateLimit: 0)

        let result = await source.lookup(StatutoryQuery(terms: "statute of frauds", jurisdiction: "Florida"))
        XCTAssertEqual(result.provisions.count, 1)
        let provision = try XCTUnwrap(result.provisions.first)
        XCTAssertEqual(provision.citation, "§ 672.201")
        XCTAssertEqual(provision.weightTier, .convenience)
        XCTAssertEqual(provision.sourceID, "open-legal-codes")
        XCTAssertNotNil(provision.currencyCaveat)
    }

    func testOLCSourceDegradesGracefullyOnCrawlFailure() async {
        let source = OpenLegalCodesStatutorySource(
            client: StubOLCClient(search: .failure(.crawlFailed(reason: "database or disk is full", retryAfter: 549))),
            hydrateLimit: 0
        )
        let result = await source.lookup(StatutoryQuery(terms: "x", jurisdiction: "Florida"))
        XCTAssertTrue(result.provisions.isEmpty, "a crawl failure must not surface provisions")
        XCTAssertNotNil(result.note, "a transient failure leaves an explanatory note")
    }

    func testOLCSourceSkipsWhenNoJurisdictionMaps() async {
        // A court jurisdiction with no statutory code never even hits the network.
        let source = OpenLegalCodesStatutorySource(client: StubOLCClient(search: .failure(.invalidResponse)), hydrateLimit: 0)
        let result = await source.lookup(StatutoryQuery(terms: "x", jurisdiction: "Ninth Circuit"))
        XCTAssertTrue(result.provisions.isEmpty)
        XCTAssertNil(result.note)
    }

    func testOLCSourceCollectsAcrossMultipleFederalTitles() async throws {
        let client = RecordingOLCClient(resultsByJurisdiction: [
            "us-usc-title-42": try Self.olcResults("""
            {"data":{"jurisdiction":"us-usc-title-42","jurisdictionName":"United States Code, Title 42","query":"dba","results":[{"path":"chapter-11/section-1651","num":"§ 1651","heading":"Defense Base Act","snippet":"The Longshore and Harbor Workers' Compensation Act applies...","url":"https://openlegalcodes.org/us/usc/title-42/1651"}]},"meta":{}}
            """),
            "us-usc-title-33": try Self.olcResults("""
            {"data":{"jurisdiction":"us-usc-title-33","jurisdictionName":"United States Code, Title 33","query":"dba","results":[{"path":"chapter-18/section-913","num":"§ 913","heading":"Filing of claims","snippet":"Time for filing claims...","url":"https://openlegalcodes.org/us/usc/title-33/913"}]},"meta":{}}
            """)
        ])
        let source = OpenLegalCodesStatutorySource(client: client, hydrateLimit: 0)

        let result = await source.lookup(StatutoryQuery(
            terms: "Defense Base Act Longshore claim filing limitations 42 U.S.C. § 1651 33 U.S.C. § 913",
            jurisdiction: "Federal",
            citation: "42 U.S.C. § 1651; 33 U.S.C. § 913",
            limit: 4
        ))

        let searchedJurisdictionIDs = await client.searchedJurisdictionIDs
        XCTAssertEqual(searchedJurisdictionIDs, ["us-usc-title-42", "us-usc-title-33"])
        XCTAssertEqual(result.provisions.map(\.citation), ["§ 1651", "§ 913"])
    }

    // MARK: - Orchestrator weighting

    func testOrchestratorKeepsHigherTierOnConflict() async {
        let olc = StubStatutorySource(id: "olc", weightTier:.convenience, provisions: [provision(tier: .convenience, citation: "§ 1.1")])
        let gov = StubStatutorySource(id: "gov", weightTier:.currencyVerifiable, provisions: [provision(tier: .currencyVerifiable, citation: "§ 1.1")])
        let (merged, _) = await StatutorySourceOrchestrator(sources: [olc, gov]).lookup(StatutoryQuery(terms: "x", jurisdiction: "Florida"))
        XCTAssertEqual(merged.count, 1, "same provision from two sources is deduped")
        XCTAssertEqual(merged.first?.weightTier, .currencyVerifiable, "the higher-tier source wins")
    }

    func testCanonicalDedupAcrossProvidersKeepsHigherTier() async {
        // The SAME federal reg from two providers with DIFFERENT display citations/names must
        // dedupe on canonical (jurisdictionID, section), so eCFR overrides OLC.
        let olc = StubStatutorySource(id: "olc", weightTier: .convenience, provisions: [
            StatutoryProvision(sourceID: "olc", sourceName: "OLC", weightTier: .convenience,
                               jurisdictionID: "us-cfr-title-40", jurisdictionName: "us-cfr-title-40",
                               citation: "§ 261.11", text: "olc text")
        ])
        let ecfr = StubStatutorySource(id: "ecfr", weightTier: .currencyVerifiable, provisions: [
            StatutoryProvision(sourceID: "ecfr", sourceName: "eCFR", weightTier: .currencyVerifiable,
                               jurisdictionID: "us-cfr-title-40", jurisdictionName: "Code of Federal Regulations, Title 40",
                               citation: "40 CFR § 261.11", text: "ecfr text", effectiveDate: "2024-01-01")
        ])
        let (merged, _) = await StatutorySourceOrchestrator(sources: [olc, ecfr]).lookup(StatutoryQuery(terms: "x", jurisdiction: "Federal"))
        XCTAssertEqual(merged.count, 1, "different display strings, same section → deduped")
        XCTAssertEqual(merged.first?.sourceID, "ecfr", "currency-verifiable eCFR overrides convenience-tier OLC")
    }

    func testOrchestratorSortsByTierDescending() async {
        let olc = StubStatutorySource(id: "olc", weightTier:.convenience, provisions: [provision(tier: .convenience, citation: "§ 2.2")])
        let gov = StubStatutorySource(id: "gov", weightTier:.currencyVerifiable, provisions: [provision(tier: .currencyVerifiable, citation: "§ 3.3")])
        let (merged, _) = await StatutorySourceOrchestrator(sources: [olc, gov]).lookup(StatutoryQuery(terms: "x"))
        XCTAssertEqual(merged.map(\.weightTier), [.currencyVerifiable, .convenience])
    }

    // MARK: - Packet merge + LegalAuthority bridge

    func testPacketMergeLeadsWithStatutesThenCases() {
        let cases = LegalAuthorityRanker.rank([caseAuthority("A"), caseAuthority("B")], for: statuteClassification())
        let merged = StatutoryPacketMerge.merge(
            statutoryProvisions: [provision(tier: .convenience, citation: "§ 1.1")],
            rankedCases: cases,
            jurisdictionLabel: "Florida",
            cap: 12
        )
        XCTAssertEqual(merged.count, 3, "1 statute + 2 cases")
        XCTAssertEqual(merged.first?.authority.authorityType, .statute, "statutes lead the packet")
        XCTAssertEqual(merged.first?.authority.source, .openlegalcodes)
        XCTAssertEqual(merged.last?.authority.authorityType, .case)
    }

    func testGovInfoProvisionKeepsGovInfoProvenance() {
        let provision = StatutoryProvision(
            sourceID: "govinfo", sourceName: "govinfo", weightTier: .currencyVerifiable,
            jurisdictionName: "United States Code", citation: "33 U.S.C. § 913",
            text: "official text", effectiveDate: "2026-01-01"
        )
        let authority = provision.asLegalAuthority(jurisdictionLabel: "Federal")
        XCTAssertEqual(authority.source, .govinfo)
        XCTAssertEqual(authority.authorityType, .statute)
    }

    func testProvisionBridgesToStatutoryAuthorityWithCaveatInText() {
        let provision = StatutoryProvision(
            sourceID: "open-legal-codes", sourceName: "Open Legal Codes", weightTier: .convenience,
            jurisdictionName: "Florida Statutes", citation: "§ 672.201", heading: "Statute of frauds",
            text: "the section body", currencyCaveat: "Confirm against the official Florida Statutes."
        )
        let authority = provision.asLegalAuthority(jurisdictionLabel: "Florida")
        XCTAssertEqual(authority.source, .openlegalcodes)
        XCTAssertEqual(authority.authorityType, .statute)
        XCTAssertEqual(authority.jurisdiction, "Florida", "jurisdiction label matches the classifier so verification passes")
        XCTAssertTrue(authority.text?.contains("Confirm against the official") ?? false, "the currency caveat rides in the grounding text")
        XCTAssertTrue(authority.citation?.contains("§ 672.201") ?? false)
    }

    // MARK: - Helpers

    private func provision(tier: SourceWeightTier, citation: String) -> StatutoryProvision {
        StatutoryProvision(sourceID: "s", sourceName: "S", weightTier: tier, jurisdictionName: "Florida Statutes", citation: citation, text: "text")
    }

    private func caseAuthority(_ id: String) -> LegalAuthority {
        LegalAuthority(id: id, source: .courtlistener, authorityType: .case, caseName: "Case \(id)", citation: "100 F.3d \(id)", jurisdiction: "Florida")
    }

    private func statuteClassification() -> LegalQueryClassification {
        LegalQueryClassification(jurisdiction: "Florida", legalIssue: "statute of frauds", desiredAuthorityType: .statute)
    }

    private static func olcResults(_ json: String) throws -> OLCSearchResults {
        try JSONDecoder().decode(OLCEnvelope<OLCSearchResults>.self, from: Data(json.utf8)).data
    }
}

private struct StubOLCClient: OpenLegalCodesClientProtocol {
    let search: Result<OLCSearchResults, OpenLegalCodesError>

    func searchCode(jurisdictionID: String, query: String, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        try search.get()
    }
    func searchAcross(query: String, state: String?, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        try search.get()
    }
    func fetchSection(jurisdictionID: String, path: String, relatedResearchSessionID: String?) async throws -> OLCSection {
        throw OpenLegalCodesError.invalidResponse
    }
    func jurisdiction(id: String) async throws -> OLCJurisdiction {
        throw OpenLegalCodesError.invalidResponse
    }
}

private actor RecordingOLCClient: OpenLegalCodesClientProtocol {
    private let resultsByJurisdiction: [String: OLCSearchResults]
    private(set) var searchedJurisdictionIDs: [String] = []

    init(resultsByJurisdiction: [String: OLCSearchResults]) {
        self.resultsByJurisdiction = resultsByJurisdiction
    }

    func searchCode(jurisdictionID: String, query: String, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        searchedJurisdictionIDs.append(jurisdictionID)
        guard let result = resultsByJurisdiction[jurisdictionID] else {
            throw OpenLegalCodesError.invalidResponse
        }
        return result
    }

    func searchAcross(query: String, state: String?, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        throw OpenLegalCodesError.invalidResponse
    }

    func fetchSection(jurisdictionID: String, path: String, relatedResearchSessionID: String?) async throws -> OLCSection {
        throw OpenLegalCodesError.invalidResponse
    }

    func jurisdiction(id: String) async throws -> OLCJurisdiction {
        throw OpenLegalCodesError.invalidResponse
    }
}

private struct StubStatutorySource: StatutorySource {
    let id: String
    let displayName = "Stub"
    let weightTier: SourceWeightTier
    let providesCurrency = false
    let provisions: [StatutoryProvision]

    func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult {
        StatutoryLookupResult(provisions: provisions)
    }
}
