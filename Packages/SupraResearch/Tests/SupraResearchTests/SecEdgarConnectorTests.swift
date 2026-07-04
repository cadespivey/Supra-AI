import Foundation
import SupraNetworking
import XCTest
@testable import SupraResearch

/// SEC EDGAR connector: CIK normalization, request construction, columnar
/// zipping, historical continuation, XBRL raw preservation, URL building,
/// neutral RAG text, caching, retry, and pacing. Deterministic fixtures only;
/// live probes live in `SecEdgarLiveTests`.
final class SecEdgarConnectorTests: XCTestCase {

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SEC"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    private func configuration(userAgent: String? = "Supra Tests dev@example.com") -> LegalDataConnectorConfiguration {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec-tests-\(UUID().uuidString)", isDirectory: true)
        return LegalDataConnectorConfiguration(
            cacheDirectory: tmp,
            nlrbLocalDataDirectory: tmp,
            secEdgarUserAgent: userAgent,
            secEdgarRateLimitPerSecond: 10
        )
    }

    private func connector(
        stub: ScriptedHTTPStub,
        userAgent: String? = "Supra Tests dev@example.com",
        cache: any LegalDataConnectorCache = NoopConnectorCache()
    ) -> SecEdgarConnector {
        SecEdgarConnector(
            httpClient: stub,
            configuration: configuration(userAgent: userAgent),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            retrySleeper: { _ in }
        )
    }

    // MARK: - Required tests

    func testNormalizeCikAcceptsCommonForms() throws {
        XCTAssertEqual(try SecEdgarConnector.normalizeCik(320193), "0000320193")
        XCTAssertEqual(try SecEdgarConnector.normalizeCik("320193"), "0000320193")
        XCTAssertEqual(try SecEdgarConnector.normalizeCik("0000320193"), "0000320193")
        XCTAssertEqual(try SecEdgarConnector.normalizeCik(" 320193 "), "0000320193")
        XCTAssertEqual(try SecEdgarConnector.normalizeCik("000-0320193"), "0000320193")
    }

    func testNormalizeCikRejectsUnsafeInput() {
        for bad in ["", "CIK320193", "320193?x=1", "12345678901", "-5", "320.193"] {
            XCTAssertThrowsError(try SecEdgarConnector.normalizeCik(bad), bad) { error in
                XCTAssertEqual((error as? LegalDataConnectorError)?.kind, .validation)
            }
        }
        XCTAssertThrowsError(try SecEdgarConnector.normalizeCik(0))
        XCTAssertThrowsError(try SecEdgarConnector.normalizeCik(-7))
    }

    func testMissingUserAgentFailsBeforeNetwork() async {
        let stub = ScriptedHTTPStub(script: [.success(Data("{}".utf8))])
        let sut = connector(stub: stub, userAgent: nil)
        do {
            _ = try await sut.getCompanySubmissions("320193")
            XCTFail("expected config error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .config)
            XCTAssertFalse(error.message.contains("dev@example.com"), "the UA value must never be echoed")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0, "no network attempt without a User-Agent")
    }

    func testCompanySubmissionsRequestUsesTenDigitCikAndUserAgent() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut = connector(stub: stub)
        _ = try await sut.getCompanySubmissions("320193")
        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://data.sec.gov/submissions/CIK0000320193.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Supra Tests dev@example.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let sendCalls = await stub.authenticatedSendCount
        XCTAssertEqual(sendCalls, 0, "connectors must never use the CourtListener-token send path")
    }

    func testRecentFilingsZipColumnarArrays() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut = connector(stub: stub)
        let submissions = try await sut.getCompanySubmissions("320193")

        XCTAssertEqual(submissions.recentFilings.count, 4)
        let tenK = try XCTUnwrap(submissions.recentFilings.first)
        XCTAssertEqual(tenK.form, "10-K")
        XCTAssertEqual(tenK.accessionNumber, "0000320193-23-000106")
        XCTAssertEqual(tenK.filingDate, "2023-11-03")
        XCTAssertEqual(tenK.primaryDocument, "aapl-20230930.htm")
        XCTAssertEqual(tenK.entityName, "Apple Inc.")
        XCTAssertEqual(tenK.tickers, ["AAPL"])
        XCTAssertEqual(tenK.isXbrl, true)
        XCTAssertEqual(
            tenK.filingUrl,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019323000106/"
        )
        XCTAssertEqual(
            tenK.primaryDocumentUrl,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019323000106/aapl-20230930.htm"
        )
        // Empty-string source values normalize to nil, not placeholders.
        let eightK = submissions.recentFilings[3]
        XCTAssertEqual(eightK.form, "8-K")
        XCTAssertNil(eightK.reportDate)
        XCTAssertEqual(eightK.items, "2.02,9.01")

        // Ragged columns: rows normalize to the longest column with a warning;
        // rows without an accession are skipped, not crashed on.
        let ragged = try JSONValue.fromData(Data("""
        {"accessionNumber": ["0000000000-24-000001", ""], "form": ["10-K"], "filingDate": []}
        """.utf8))
        var warnings: [String] = []
        let rows = SecEdgarNormalizer.zipColumnarFilings(
            ragged,
            company: submissions.company,
            sourceUrl: "https://data.sec.gov/submissions/CIK0000320193.json",
            retrievedAt: Date(),
            warnings: &warnings
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].form, "10-K")
        XCTAssertNil(rows[0].filingDate)
        XCTAssertEqual(warnings.count, 2, "ragged-length warning + skipped-row warning: \(warnings)")
    }

    func testHistoricalContinuationIsLoadedForAccessionLookup() async throws {
        let stub = ScriptedHTTPStub(script: [
            .success(try fixture("company-submissions-apple")),
            .success(try fixture("company-submissions-historical-page"))
        ])
        let sut = connector(stub: stub)
        let filing = try await sut.getFilingByAccession(cik: "320193", accessionNumber: "0000912057-01-544436")
        XCTAssertEqual(filing?.form, "10-K")
        XCTAssertEqual(filing?.filingDate, "2001-12-21")
        let calls = await stub.callCount
        XCTAssertEqual(calls, 2, "submissions + one continuation file")
        let requests = await stub.requests
        XCTAssertEqual(
            requests.last?.url?.absoluteString,
            "https://data.sec.gov/submissions/CIK0000320193-submissions-001.json"
        )
    }

    func testCompanyFactsRequestAndRawPreservation() async throws {
        let data = try fixture("company-facts-apple-minimal")
        let stub = ScriptedHTTPStub(script: [.success(data)])
        let sut = connector(stub: stub)
        let facts = try await sut.getCompanyFacts("320193")

        XCTAssertEqual(facts.cik, "0000320193")
        XCTAssertEqual(facts.entityName, "Apple Inc.")
        XCTAssertEqual(facts.factSummaries.count, 3)
        XCTAssertFalse(facts.isFactSummaryTruncated)
        // Raw preservation: the model's raw payload is exactly the source JSON.
        XCTAssertEqual(facts.raw, try JSONValue.fromData(data))
        let payable = try XCTUnwrap(facts.factSummaries.first { $0.concept == "AccountsPayableCurrent" && $0.period == "2023-09-30" })
        XCTAssertEqual(payable.unit, "USD")
        XCTAssertEqual(payable.value?.numberValue, 62_611_000_000)
        XCTAssertEqual(payable.form, "10-K")
        XCTAssertEqual(payable.sourceRecordType, "company_fact")
    }

    func testCompanyConceptRequestAndFlattenedSummary() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-concept-revenues"))])
        let sut = connector(stub: stub)
        let concept = try await sut.getCompanyConcept(
            cik: "320193", taxonomy: "us-gaap", concept: "RevenueFromContractWithCustomerExcludingAssessedTax"
        )
        let requests = await stub.requests
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://data.sec.gov/api/xbrl/companyconcept/CIK0000320193/us-gaap/RevenueFromContractWithCustomerExcludingAssessedTax.json"
        )
        XCTAssertEqual(concept.factSummaries.count, 2)
        XCTAssertEqual(concept.factSummaries.first?.period, "2021-09-26/2022-09-24")
        XCTAssertEqual(concept.factSummaries.first?.sourceRecordType, "company_concept")

        // Path-component validation blocks traversal and embedded URLs.
        do {
            _ = try await sut.getCompanyConcept(cik: "320193", taxonomy: "us-gaap/../evil", concept: "X")
            XCTFail("expected validation error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .validation)
        }
    }

    func testFrameRequestAndSummary() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("frame-revenues"))])
        let sut = connector(stub: stub)
        let frame = try await sut.getFrame(
            taxonomy: "us-gaap", concept: "RevenueFromContractWithCustomerExcludingAssessedTax",
            unit: "USD", frame: "CY2023"
        )
        let requests = await stub.requests
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://data.sec.gov/api/xbrl/frames/us-gaap/RevenueFromContractWithCustomerExcludingAssessedTax/USD/CY2023.json"
        )
        XCTAssertEqual(frame.factSummaries.count, 3)
        let microsoft = try XCTUnwrap(frame.factSummaries.first { $0.entityName == "MICROSOFT CORPORATION" })
        XCTAssertEqual(microsoft.cik, "789019")
        XCTAssertEqual(microsoft.sourceRecordType, "frame")
        XCTAssertEqual(microsoft.unit, "USD")
    }

    func testFilingURLConstructionWithAndWithoutDashes() throws {
        let dashed = try SecEdgarConnector.buildFilingUrl(
            cik: "320193", accessionNumber: "0000320193-23-000106", primaryDocument: "aapl-20230930.htm"
        )
        XCTAssertEqual(dashed.filingUrl, "https://www.sec.gov/Archives/edgar/data/320193/000032019323000106/")
        XCTAssertEqual(dashed.primaryDocumentUrl, dashed.filingUrl + "aapl-20230930.htm")

        let undashed = try SecEdgarConnector.buildFilingUrl(
            cik: "0000320193", accessionNumber: "000032019323000106", primaryDocument: nil
        )
        XCTAssertEqual(undashed.filingUrl, dashed.filingUrl)
        XCTAssertNil(undashed.primaryDocumentUrl)

        // Rendered-form paths keep their internal directory, encoded per segment.
        let rendered = try SecEdgarConnector.buildFilingUrl(
            cik: "320193", accessionNumber: "0000320193-23-000106", primaryDocument: "xslF345X05/wf-form4.xml"
        )
        XCTAssertEqual(rendered.primaryDocumentUrl, dashed.filingUrl + "xslF345X05/wf-form4.xml")

        XCTAssertThrowsError(try SecEdgarConnector.buildFilingUrl(
            cik: "320193", accessionNumber: "not-an-accession", primaryDocument: nil
        ))
        XCTAssertThrowsError(try SecEdgarConnector.buildFilingUrl(
            cik: "320193", accessionNumber: "0000320193-23-000106", primaryDocument: "../escape.htm"
        ))
    }

    func testRAGTextIsNeutralAndSourceAttributed() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut = connector(stub: stub)
        let filings = try await sut.getRecentFilings(cik: "320193")
        let records = try sut.toIngestionRecords(filings)
        let tenK = try XCTUnwrap(records.first)

        for expected in [
            "Apple Inc.", "CIK 0000320193", "Form: 10-K", "2023-11-03",
            "0000320193-23-000106", "aapl-20230930.htm",
            "https://data.sec.gov/submissions/CIK0000320193.json"
        ] {
            XCTAssertTrue(tenK.ragText.contains(expected), "missing \(expected) in: \(tenK.ragText)")
        }
        // The 10-K has no items — the line is omitted, no placeholders.
        XCTAssertFalse(tenK.ragText.contains("Items:"), tenK.ragText)
        XCTAssertFalse(tenK.ragText.lowercased().contains("n/a"))
        // Neutrality: the template never introduces legal conclusions.
        for forbidden in ["violated", "fraud", "material breach", "investment advice", "liable"] {
            XCTAssertFalse(tenK.ragText.lowercased().contains(forbidden), forbidden)
        }
        XCTAssertEqual(tenK.sourceRecordId, "sec_edgar:filing:0000320193:0000320193-23-000106")
        XCTAssertEqual(tenK.rawPayload, filings[0].raw)
    }

    func testCacheHitSkipsNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut = connector(stub: stub, cache: FileLegalDataConnectorCache(directory: dir))

        _ = try await sut.getCompanySubmissions("320193")
        let again = try await sut.getCompanySubmissions("320193")
        XCTAssertEqual(again.recentFilings.count, 4)
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1, "the second fetch must come from cache")
    }

    func testTransientFailureRetries() async throws {
        let stub = ScriptedHTTPStub(script: [
            .status(503, headers: ["Retry-After": "0"]),
            .success(try fixture("company-submissions-apple"))
        ])
        let sut = connector(stub: stub)
        let submissions = try await sut.getCompanySubmissions("320193")
        XCTAssertEqual(submissions.company.entityName, "Apple Inc.")
        let calls = await stub.callCount
        XCTAssertEqual(calls, 2)
    }

    func testRatePacerRunsBeforeRequests() async {
        // The connector derives its pacer window from configuration; prove the
        // config value produces the expected pacing (the executor paces before
        // every attempt — covered structurally in the shared infra tests).
        let recorder = SleepRecorder()
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let config = configuration()
        let pacer = ConnectorPacer(
            requestsPerSecond: config.secEdgarRateLimitPerSecond,
            now: { clock.now() },
            sleeper: { await recorder.record($0) }
        )
        await pacer.pace()
        await pacer.pace()   // immediately after → must sleep the full window
        let sleeps = await recorder.sleeps
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0], 1.0 / config.secEdgarRateLimitPerSecond, accuracy: 0.001)
    }

    func testMissingOptionalFieldsDoNotFailNormalization() throws {
        let sparse = try JSONValue.fromData(Data("""
        {
          "cik": "0000000123",
          "name": "Sparse Co.",
          "filings": {"recent": {"accessionNumber": ["0000000123-24-000001"]}}
        }
        """.utf8))
        let submissions = try SecEdgarNormalizer.submissions(
            from: sparse, cik: "0000000123",
            sourceUrl: "https://data.sec.gov/submissions/CIK0000000123.json",
            retrievedAt: Date(), operation: "test"
        )
        XCTAssertEqual(submissions.recentFilings.count, 1)
        let filing = submissions.recentFilings[0]
        XCTAssertNil(filing.form)
        XCTAssertNil(filing.filingDate)
        XCTAssertNil(filing.primaryDocument)
        XCTAssertNil(filing.primaryDocumentUrl)
        XCTAssertEqual(filing.accessionNumber, "0000000123-24-000001")
        XCTAssertTrue(submissions.company.tickers.isEmpty)

        // Filters over sparse records behave: date filters exclude undated rows.
        let filtered = try SecEdgarConnector.apply(
            SecFilingFilters(startDate: "2024-01-01"), to: submissions.recentFilings, operation: "test"
        )
        XCTAssertTrue(filtered.isEmpty)
        XCTAssertThrowsError(try SecEdgarConnector.apply(
            SecFilingFilters(startDate: "01/01/2024"), to: submissions.recentFilings, operation: "test"
        ))
    }

    func testFormFilterSemanticsIncludingAmendments() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut = connector(stub: stub)
        let quarterlies = try await sut.getQuarterlyReports(cik: "320193")
        XCTAssertEqual(quarterlies.map(\.form), ["10-Q", "10-Q"])

        let stub2 = ScriptedHTTPStub(script: [.success(try fixture("company-submissions-apple"))])
        let sut2 = connector(stub: stub2)
        let material = try await sut2.getMaterialEventFilings(cik: "320193", item: "2.02")
        XCTAssertEqual(material.count, 1)
        XCTAssertEqual(material.first?.form, "8-K")
    }

    func testIncludeAmendmentsFalseExcludesAmendedForms() throws {
        func record(_ form: String) -> SecFilingRecord {
            SecFilingRecord(
                cik: "0000320193", accessionNumber: "0000320193-24-00000\(form.count)",
                form: form, filingUrl: "https://www.sec.gov/x", sourceUrl: "https://www.sec.gov/x",
                retrievedAt: Date(timeIntervalSince1970: 1_750_000_000), raw: .object([:])
            )
        }
        let filings = [record("10-K"), record("10-K/A"), record("8-K")]

        // No explicit forms: /A excluded when includeAmendments is false.
        var filters = SecFilingFilters()
        filters.includeAmendments = false
        let withoutAmendments = try SecEdgarConnector.apply(filters, to: filings, operation: "test")
        XCTAssertEqual(withoutAmendments.map(\.form), ["10-K", "8-K"])

        // Explicitly requested amended forms win over includeAmendments=false.
        var explicit = SecFilingFilters()
        explicit.includeAmendments = false
        explicit.formTypes = ["10-K/A"]
        let explicitAmendment = try SecEdgarConnector.apply(explicit, to: filings, operation: "test")
        XCTAssertEqual(explicitAmendment.map(\.form), ["10-K/A"])
    }
}
