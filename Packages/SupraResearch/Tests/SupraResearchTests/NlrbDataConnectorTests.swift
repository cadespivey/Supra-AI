import Foundation
import SupraNetworking
import XCTest
@testable import SupraResearch

/// NLRB connector: CSV-link discovery from official-page fixtures, RFC-4180
/// parsing, normalization, classification, idempotent local import, local
/// search/filtering, neutral RAG and party summaries, and provenance.
final class NlrbDataConnectorTests: XCTestCase {

    private func fixtureText(_ name: String, ext: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/NLRB"),
            "missing fixture \(name).\(ext)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeStore() -> (NlrbLocalRecordStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlrb-tests-\(UUID().uuidString)", isDirectory: true)
        return (NlrbLocalRecordStore(directory: dir), dir)
    }

    private func connector(
        stub: ScriptedHTTPStub,
        store: NlrbLocalRecordStore
    ) -> NlrbDataConnector {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlrb-conn-\(UUID().uuidString)", isDirectory: true)
        return NlrbDataConnector(
            httpClient: stub,
            configuration: LegalDataConnectorConfiguration(
                cacheDirectory: tmp, nlrbLocalDataDirectory: tmp, nlrbRateLimitPerSecond: 5
            ),
            cache: NoopConnectorCache(),
            localStore: store,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }

    /// Imports the recent-filings fixture through the full connector path.
    private func importFilings(store: NlrbLocalRecordStore) async throws -> (NlrbDataConnector, NlrbImportRun) {
        let stub = ScriptedHTTPStub(script: [
            .success(Data(try fixtureText("recent-filings", ext: "csv").utf8))
        ])
        let sut = connector(stub: stub, store: store)
        let source = NlrbDatasetSource(
            name: "Recent filings",
            sourceVariant: .officialRecentFilings,
            status: .available,
            downloadUrl: "https://www.nlrb.gov/reports/graphs-data/recent-filings/export?_format=csv",
            pageUrl: NlrbSources.recentFilingsPage.absoluteString,
            note: nil,
            discoveredAt: Date()
        )
        let run = try await sut.importDataset(source)
        return (sut, run)
    }

    // MARK: - Required tests

    func testFindsOfficialRecentFilingsCSVLink() throws {
        let html = try fixtureText("recent-filings-page", ext: "html")
        let link = NlrbSources.downloadCSVLink(inHTML: html, pageURL: NlrbSources.recentFilingsPage)
        XCTAssertEqual(
            link?.absoluteString,
            "https://www.nlrb.gov/reports/graphs-data/recent-filings/export?_format=csv&date_start=2024-03-01",
            "relative href resolves against the page; the off-host decoy link must be rejected"
        )
    }

    func testFindsOfficialElectionResultsCSVLink() throws {
        let html = try fixtureText("recent-election-results-page", ext: "html")
        let link = NlrbSources.downloadCSVLink(inHTML: html, pageURL: NlrbSources.recentElectionResultsPage)
        XCTAssertEqual(
            link?.absoluteString,
            "https://www.nlrb.gov/reports/graphs-data/recent-election-results/export.csv",
            "nested markup inside the anchor text must still match"
        )
    }

    func testRejectsJavaScriptDownloadTrayButton() {
        // The live pages' "Download CSV" is a JS tray button whose href is the
        // page itself (real download sits behind a cookie token). Discovery
        // must NOT treat it as an importable export.
        let html = """
        <a href="/reports/graphs-data/recent-filings" id="download-button" \
           class="usa-button nlrb-download-button" role="button" \
           data-typeofreport="recent_filings" data-cacheid="recent_filings_data___abc">Download CSV</a>
        """
        XCTAssertNil(NlrbSources.downloadCSVLink(inHTML: html, pageURL: NlrbSources.recentFilingsPage))
    }

    func testImportLocalCSVDetectsVariantAndImports() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [])
        let sut = connector(stub: stub, store: store)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlrb-manual-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try fixtureText("recent-election-results", ext: "csv").write(to: file, atomically: true, encoding: .utf8)

        let run = try await sut.importLocalCSV(fileURL: file)
        XCTAssertEqual(run.sourceVariant, .officialRecentElectionResults, "variant is detected from headers")
        XCTAssertEqual(run.importedRecordCount, 2)
        XCTAssertNil(run.sourceUrl, "no dataset URL for a manual import")
        XCTAssertTrue(run.datasetName.contains(file.lastPathComponent))
        XCTAssertFalse(run.datasetName.contains(FileManager.default.temporaryDirectory.path), "never store the local PATH")
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0, "local import must not touch the network")

        let elections = try await sut.getElectionResults()
        XCTAssertEqual(elections.count, 2)
    }

    func testImportLocalCSVRejectsUnrecognizableFile() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sut = connector(stub: ScriptedHTTPStub(script: []), store: store)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlrb-bogus-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try "just,some,columns\n1,2,3\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await sut.importLocalCSV(fileURL: file)
            XCTFail("expected validation error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .validation)
        }
    }

    func testDetectVariantMatchesEveryNormalizerAlias() throws {
        // The election export uses the ALTERNATE header spellings the
        // normalizer aliases (Date Tally Issued / Votes for Labor Org /
        // Against Votes / Number of Eligible Voters) — detectVariant must
        // classify it as election, not silently fall through to filings and
        // drop the vote data.
        let electionAltHeader = "Case Number,Case Name,Region,City,State,Unit ID,Date Tally Issued,Labor Organization,Votes for Labor Org,Against Votes,Valid Votes Counted,Unit Size,Number of Eligible Voters,Certified Rep\n01-RC-1,Acme,Region 1,Tampa,FL,A,03/01/2024,Local 1,20,10,30,35,34,None\n"
        XCTAssertEqual(
            try NlrbDataConnector.detectVariant(inCSV: electionAltHeader, operation: "t"),
            .officialRecentElectionResults
        )

        // A filings export using the bare "Case" column (also a caseRecord
        // alias) must be recognized, not rejected.
        let filingsBareCase = "Case,Case Name,Case Type,Region Assigned,Date Filed,Status,Employer,Union\n01-CA-1,Acme,CA,Region 1,03/01/2024,Open,Acme,Local 1\n"
        XCTAssertEqual(
            try NlrbDataConnector.detectVariant(inCSV: filingsBareCase, operation: "t"),
            .officialRecentFilings
        )

        // The canonical filings export (no vote columns) is still filings, not
        // misclassified as election.
        XCTAssertEqual(
            try NlrbDataConnector.detectVariant(inCSV: try fixtureText("recent-filings", ext: "csv"), operation: "t"),
            .officialRecentFilings
        )
    }

    func testCSVParserHandlesQuotedCommasAndCRLF() {
        let csv = "a,b,c\r\n\"one, two\",\"say \"\"hi\"\"\",\r\nplain,,\"multi\nline\"\n"
        let rows = NlrbCSVImporter.parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["one, two", "say \"hi\"", ""])
        XCTAssertEqual(rows[2], ["plain", "", "multi\nline"])

        let mapped = NlrbCSVImporter.headerMappedRows(csv)
        XCTAssertEqual(mapped[0]["a"], "one, two")
        XCTAssertEqual(NlrbCSVImporter.value(in: mapped[0], aliases: ["B"]), "say \"hi\"")
    }

    func testRecentFilingsNormalizeCoreCaseFields() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, run) = try await importFilings(store: store)

        XCTAssertEqual(run.recordCount, 4)
        XCTAssertEqual(run.normalizedRecordCount, 3, "the row with no case number is skipped")
        XCTAssertTrue(run.warnings.contains { $0.contains("no case number") })

        let cases = await store.allCases()
        XCTAssertEqual(cases.count, 3)
        let riverside = try XCTUnwrap(cases.first { $0.caseNumber == "01-CA-345678" })
        XCTAssertEqual(riverside.caseName, "Riverside Logistics, Inc.")
        XCTAssertEqual(riverside.employer, "Riverside Logistics, Inc.")
        XCTAssertEqual(riverside.union, "Teamsters Local 25")
        XCTAssertEqual(riverside.region, "Region 01, Boston")
        XCTAssertEqual(riverside.dateFiled, "03/11/2024")
        XCTAssertEqual(riverside.allegations, "8(a)(1) Coercive Statements; 8(a)(3) Discharge")
        XCTAssertNil(riverside.reasonClosed, "blank cells normalize to nil")
        XCTAssertEqual(riverside.sourceUrl, "https://www.nlrb.gov/case/01-CA-345678")
        XCTAssertEqual(riverside.sourceVariant, .officialRecentFilings)
        // Raw row preserved, header text intact.
        XCTAssertEqual(riverside.raw["Case Number"]?.stringValue, "01-CA-345678")
    }

    func testElectionResultsNormalizeVoteFields() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [
            .success(Data(try fixtureText("recent-election-results", ext: "csv").utf8))
        ])
        let sut = connector(stub: stub, store: store)
        let source = NlrbDatasetSource(
            name: "Recent election results",
            sourceVariant: .officialRecentElectionResults,
            status: .available,
            downloadUrl: "https://www.nlrb.gov/reports/graphs-data/recent-election-results/export.csv",
            pageUrl: nil, note: nil, discoveredAt: Date()
        )
        let run = try await sut.importDataset(source)
        XCTAssertEqual(run.importedRecordCount, 2)

        let elections = try await sut.getElectionResults()
        XCTAssertEqual(elections.count, 2)
        let harbor = try XCTUnwrap(elections.first { $0.caseNumber == "01-RC-389901" })
        XCTAssertEqual(harbor.votesFor, 34)
        XCTAssertEqual(harbor.votesAgainst, 21)
        XCTAssertEqual(harbor.totalBallotsCounted, 55)
        XCTAssertEqual(harbor.eligibleVoters, 58)
        XCTAssertEqual(harbor.unitId, "A")
        XCTAssertNil(harbor.certifiedRepresentative, "the connector never infers outcomes")
        XCTAssertEqual(harbor.caseTypeCategory, .representation)
        let evergreen = try XCTUnwrap(elections.first { $0.caseNumber == "19-RD-556677" })
        XCTAssertEqual(evergreen.votesAgainst, 30, "quoted numeric cells still parse")
        XCTAssertEqual(evergreen.certifiedRepresentative, "None (decertified)")
    }

    func testCaseTypeClassifierMapsKnownTypes() {
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "CA"), .unfairLaborPractice)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "cb"), .unfairLaborPractice)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "CP"), .unfairLaborPractice)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "RC"), .representation)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "RM"), .representation)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "UC"), .unitClarification)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "UD"), .unionDeauthorization)
        XCTAssertEqual(NlrbCaseClassifier.category(forCode: "AC"), .amendmentOfCertification)
        XCTAssertEqual(NlrbCaseClassifier.code(fromCaseNumber: "01-RC-389901"), "RC")
        XCTAssertNil(NlrbCaseClassifier.code(fromCaseNumber: "nonsense"))
    }

    func testCaseTypeClassifierPreservesUnknownTypes() {
        let (code, category) = NlrbCaseClassifier.classify(caseNumber: "01-ZZ-000001", explicitCaseType: nil)
        XCTAssertEqual(code, "ZZ", "unknown codes survive verbatim")
        XCTAssertEqual(category, .unknown)
        // A recognized explicit source field wins over the case number.
        let (explicit, explicitCategory) = NlrbCaseClassifier.classify(caseNumber: "01-RC-389901", explicitCaseType: " CA ")
        XCTAssertEqual(explicit, "CA")
        XCTAssertEqual(explicitCategory, .unfairLaborPractice)
        // An UNRECOGNIZED explicit value must not block the case-number fallback.
        let (fallback, fallbackCategory) = NlrbCaseClassifier.classify(caseNumber: "01-CA-345678", explicitCaseType: "Charge")
        XCTAssertEqual(fallback, "CA")
        XCTAssertEqual(fallbackCategory, .unfairLaborPractice)
        // Neither recognized: the explicit value survives verbatim.
        let (verbatim, verbatimCategory) = NlrbCaseClassifier.classify(caseNumber: "nonsense", explicitCaseType: "XQ")
        XCTAssertEqual(verbatim, "XQ")
        XCTAssertEqual(verbatimCategory, .unknown)
    }

    func testCaseNumberSearchUsesNormalizedKey() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, _) = try await importFilings(store: store)
        let found = try await sut.getCaseByNumber("  01-ca-345678 ")
        XCTAssertEqual(found?.caseNumber, "01-CA-345678", "case-number keys uppercase and preserve dashes")
        let missing = try await sut.getCaseByNumber("99-CA-000000")
        XCTAssertNil(missing)
    }

    func testImportRejectsOffHostDownloadUrl() async throws {
        // Dataset sources are plain Codable values — a hand-built or tampered
        // one must not be able to point the importer at another allow-listed
        // host and launder its payload as an official NLRB export.
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [])
        let sut = connector(stub: stub, store: store)
        let tampered = NlrbDatasetSource(
            name: "Recent filings",
            sourceVariant: .officialRecentFilings,
            status: .available,
            downloadUrl: "https://api.regulations.gov/v4/documents",
            pageUrl: nil, note: nil, discoveredAt: Date()
        )
        do {
            _ = try await sut.importDataset(tampered)
            XCTFail("expected validation error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .validation)
        }
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0, "the off-host URL must never be fetched")
    }

    func testEmployerUnionAndPartySearch() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, _) = try await importFilings(store: store)

        let byEmployer = try await sut.searchByEmployer("riverside logistics")
        XCTAssertEqual(byEmployer.map(\.caseNumber), ["01-CA-345678"])

        let byUnion = try await sut.searchByUnion("Teamsters")
        XCTAssertEqual(byUnion.map(\.caseNumber), ["01-CA-345678"])

        let byParty = try await sut.searchByPartyName("Harbor Coffee")
        XCTAssertEqual(byParty.map(\.caseNumber), ["01-RC-389901"])

        let ulp = try await sut.searchUnfairLaborPracticeCases(filters: .init())
        XCTAssertEqual(Set(ulp.map(\.caseNumber)), ["01-CA-345678", "19-CB-112233"])

        let representation = try await sut.searchRepresentationCases(filters: .init())
        XCTAssertEqual(representation.map(\.caseNumber), ["01-RC-389901"])

        // partyName and caseType filters actually narrow (regression: they
        // were silently ignored).
        var partyFilters = NlrbCaseFilters()
        partyFilters.partyName = "Teamsters Local 25"
        let byPartyFilter = try await sut.searchUnfairLaborPracticeCases(filters: partyFilters)
        XCTAssertEqual(byPartyFilter.map(\.caseNumber), ["01-CA-345678"])
        var typeFilters = NlrbCaseFilters()
        typeFilters.caseType = "cb"
        let byType = try await sut.searchUnfairLaborPracticeCases(filters: typeFilters)
        XCTAssertEqual(byType.map(\.caseNumber), ["19-CB-112233"])
    }

    func testDateRangeAndRegionFiltering() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, _) = try await importFilings(store: store)

        let january = try await sut.searchByDateRange(startDate: "2024-01-01", endDate: "2024-01-31")
        XCTAssertEqual(january.map(\.caseNumber), ["19-CB-112233"], "MM/dd/yyyy source dates parse for comparison")

        let boston = try await sut.searchByRegion("Region 01")
        XCTAssertEqual(Set(boston.map(\.caseNumber)), ["01-CA-345678", "01-RC-389901"])

        do {
            _ = try await sut.searchByDateRange(startDate: "bogus", endDate: "2024-01-31")
            XCTFail("expected validation error for an unparseable date")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .validation)
        }
    }

    func testElectionRAGTextOmitsMissingFields() async throws {
        let record = NlrbElectionResultRecord(
            sourceVariant: .officialRecentElectionResults,
            caseNumber: "01-RC-389901",
            caseTypeCategory: .representation,
            unitId: nil,
            tallyDate: "03/20/2024",
            union: "Harbor Coffee Workers United",
            votesFor: 34,
            votesAgainst: 21,
            sourceUrl: NlrbSources.casePageURLString(caseNumber: "01-RC-389901"),
            retrievedAt: Date(timeIntervalSince1970: 1_750_000_000),
            raw: .object([:])
        )
        let text = NlrbNormalizer.ragText(for: record)
        XCTAssertTrue(text.contains("Tally: 34 for, 21 against."))
        XCTAssertFalse(text.contains("Certified representative"), "absent fields are omitted")
        XCTAssertFalse(text.lowercased().contains("n/a"))
        XCTAssertFalse(text.lowercased().contains("nil"))
        XCTAssertFalse(text.contains("unknown"), "the only allowed 'unknown' is the caseTypeCategory data value")
    }

    func testCaseRAGTextIsNeutral() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, _) = try await importFilings(store: store)
        let cases = try await sut.searchUnfairLaborPracticeCases(filters: .init())
        let records = try sut.toIngestionRecords(cases.map { .case($0) })
        let riverside = try XCTUnwrap(records.first { $0.sourceRecordId.contains("01-CA-345678") })
        XCTAssertTrue(riverside.ragText.contains("Allegations as categorized in the filing:"))
        XCTAssertTrue(riverside.ragText.contains("https://www.nlrb.gov/case/01-CA-345678"))
        for forbidden in ["violated", "violation", "guilty", "unlawful conduct occurred", "found to have"] {
            XCTAssertFalse(riverside.ragText.lowercased().contains(forbidden), forbidden)
        }
    }

    func testPartyHistorySummaryUsesNeutralLanguage() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, _) = try await importFilings(store: store)
        let summary = try await sut.summarizePartyNlrbHistory(partyName: "Riverside Logistics")
        XCTAssertEqual(summary.totalMatchingCaseRecords, 1)
        XCTAssertEqual(summary.countsByCaseTypeCategory["unfair_labor_practice"], 1)
        XCTAssertTrue(summary.summaryText.contains("matching case records"))
        XCTAssertFalse(summary.summaryText.lowercased().contains("violation"), summary.summaryText)
        XCTAssertTrue(summary.summaryText.contains("not findings or adjudications"))
        XCTAssertTrue(summary.limitations.contains { $0.contains("not findings") })
    }

    func testSourceProvenanceIsPreserved() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sut, run) = try await importFilings(store: store)
        XCTAssertEqual(run.sourceVariant, .officialRecentFilings)
        XCTAssertEqual(run.rawPayloadHash.count, 64)
        XCTAssertNotNil(run.rawFileRelativePath)

        let cases = await store.allCases()
        XCTAssertTrue(cases.allSatisfy { $0.sourceVariant == .officialRecentFilings })
        XCTAssertTrue(cases.allSatisfy { $0.datasetUrl?.contains("nlrb.gov") == true })
        let ingestion = try sut.toIngestionRecords([.case(cases[0])])
        XCTAssertEqual(ingestion.first?.sourceVariant, "official_recent_filings")
        XCTAssertEqual(ingestion.first?.source, "nlrb")
    }

    func testDuplicateImportIsIdempotent() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await importFilings(store: store)
        // Second import of the SAME CSV through a fresh connector.
        let (_, secondRun) = try await importFilings(store: store)
        XCTAssertEqual(secondRun.importedRecordCount, 0)
        XCTAssertEqual(secondRun.duplicateRecordCount, 3)
        let cases = await store.allCases()
        XCTAssertEqual(cases.count, 3, "re-importing must not double search results")
    }

    func testImportRunLogsWarningsAndErrors() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, run) = try await importFilings(store: store)
        XCTAssertTrue(run.errors.isEmpty)
        XCTAssertFalse(run.warnings.isEmpty)
        let persisted = await store.importRuns()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.warnings, run.warnings)

        // Discovery-only sources refuse import with a typed validation error.
        let stub = ScriptedHTTPStub(script: [])
        let sut = connector(stub: stub, store: store)
        let cats = NlrbSources.discoveryOnlySources(now: Date())[0]
        do {
            _ = try await sut.importDataset(cats)
            XCTFail("expected validation error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .validation)
        }
    }
}

/// Opt-in (SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=1): discovery against
/// the real official pages — proves the Download CSV links still exist without
/// importing anything.
final class NlrbLiveTests: XCTestCase {
    func testLiveDatasetDiscoveryProbe() async throws {
        let configuration = LegalDataConnectorConfiguration.fromEnvironment()
        try XCTSkipUnless(configuration.liveTestsEnabled, "live tests are opt-in")
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlrb-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let connector = NlrbDataConnector(
            httpClient: LivePolicyHTTPClient(),
            configuration: configuration,
            cache: NoopConnectorCache(),
            localStore: NlrbLocalRecordStore(directory: storeDir)
        )
        let sources = try await connector.refreshAvailableDatasets()
        let filings = try XCTUnwrap(sources.first { $0.sourceVariant == .officialRecentFilings })
        switch filings.status {
        case .available:
            XCTAssertTrue(filings.downloadUrl?.hasPrefix("https://www.nlrb.gov/") == true)
        case .unsupported:
            // Observed 2026-07-04: the official pages serve their CSV through a
            // cookie-token download tray, which this connector refuses to
            // automate — unsupported WITH a note is the honest outcome.
            XCTAssertNotNil(filings.note)
        case .discoveredButNotImported:
            XCTFail("recent filings should never be discovery-only")
        }
    }
}
