import Foundation
import SupraNetworking
import XCTest
@testable import SupraResearch

/// CFPB complaint connector: documented parameter mapping, repeated array
/// query items, bounded pagination, complaint-by-ID validation, tolerant
/// normalization, neutral RAG/profile wording, trends bucketing, caching,
/// retry, and pacing. Deterministic fixtures only.
final class CfpbComplaintConnectorTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/CFPB"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    private func configuration() -> LegalDataConnectorConfiguration {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfpb-tests-\(UUID().uuidString)", isDirectory: true)
        return LegalDataConnectorConfiguration(
            cacheDirectory: tmp, nlrbLocalDataDirectory: tmp, cfpbRateLimitPerSecond: 10
        )
    }

    private func connector(
        stub: ScriptedHTTPStub,
        cache: any LegalDataConnectorCache = NoopConnectorCache()
    ) -> CfpbComplaintConnector {
        CfpbComplaintConnector(
            httpClient: stub,
            configuration: configuration(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            retrySleeper: { _ in }
        )
    }

    // MARK: - Required tests

    func testSearchRequestConstructionUsesDocumentedParameters() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        _ = try await sut.searchComplaints(CfpbComplaintQuery(
            searchTerm: "escrow analysis",
            field: .complaintWhatHappened,
            filters: .init(
                company: ["EXAMPLE BANK, N.A."],
                dateReceivedMin: "2023-01-01",
                dateReceivedMax: "2024-12-31",
                hasNarrative: true
            ),
            options: .init(size: 50, maxPages: 1)
        ))
        let requests = await stub.requests
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertTrue(url.absoluteString.hasPrefix(
            "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/?"
        ), url.absoluteString)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("search_term"), "escrow analysis")
        XCTAssertEqual(value("field"), "complaint_what_happened")
        XCTAssertEqual(value("frm"), "0")
        XCTAssertEqual(value("size"), "50")
        XCTAssertEqual(value("sort"), "created_date_desc")
        XCTAssertEqual(value("no_highlight"), "true")
        XCTAssertEqual(value("company"), "EXAMPLE BANK, N.A.")
        XCTAssertEqual(value("date_received_min"), "2023-01-01")
        XCTAssertEqual(value("date_received_max"), "2024-12-31")
        XCTAssertEqual(value("has_narrative"), "true")
        // Unconfirmed parameters are never sent.
        XCTAssertNil(value("sub_product"))
        XCTAssertNil(value("sub_issue"))
        XCTAssertNil(value("consumer_disputed"))
        let sendCalls = await stub.authenticatedSendCount
        XCTAssertEqual(sendCalls, 0)
    }

    func testArrayFiltersUseRepeatedQueryItems() {
        let url = CfpbComplaintEndpoint.search(
            query: CfpbComplaintQuery(filters: .init(
                product: ["Mortgage", "Credit card"],
                state: ["FL", "GA"]
            )),
            frm: 0,
            size: 100
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "product" }.map(\.value), ["Mortgage", "Credit card"])
        XCTAssertEqual(items.filter { $0.name == "state" }.map(\.value), ["FL", "GA"])
    }

    func testPaginationStopsAtMaxPages() async throws {
        // Every page returns a full page (size == count), so only maxPages
        // stops the loop.
        let full = try fixture("search-complaints-small")
        let stub = ScriptedHTTPStub(script: [.success(full), .success(full), .success(full)])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(
            options: .init(size: 5, maxPages: 2)
        ))
        XCTAssertEqual(result.pagesFetched, 2)
        let calls = await stub.callCount
        XCTAssertEqual(calls, 2)
        let requests = await stub.requests
        let frms = requests.compactMap { request -> String? in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "frm" }?.value
        }
        XCTAssertEqual(frms, ["0", "5"], "frm advances by page size")
        XCTAssertTrue(result.sourceLimitations.contains { $0.contains("page bound") } == (result.totalCount ?? 0 > result.complaints.count))
    }

    func testComplaintByIDValidatesInput() async throws {
        for bad in ["", "-5", "12.5", "abc", "7001001?x=1"] {
            let stub = ScriptedHTTPStub(script: [])
            let sut = connector(stub: stub)
            do {
                _ = try await sut.getComplaintById(bad)
                XCTFail("expected validation error for \(bad)")
            } catch let error as LegalDataConnectorError {
                XCTAssertEqual(error.kind, .validation, bad)
            }
            let calls = await stub.callCount
            XCTAssertEqual(calls, 0, "no network for invalid ID \(bad)")
        }

        let stub = ScriptedHTTPStub(script: [.success(try fixture("complaint-detail"))])
        let sut = connector(stub: stub)
        let record = try await sut.getComplaintById("7001001")
        XCTAssertEqual(record.complaintId, "7001001")
        let requests = await stub.requests
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/7001001"
        )
    }

    func testComplaintNormalizationPreservesRawPayload() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        XCTAssertEqual(result.complaints.count, 5)
        XCTAssertEqual(result.totalCount, 5)

        let first = try XCTUnwrap(result.complaints.first)
        XCTAssertEqual(first.complaintId, "7001001")
        XCTAssertEqual(first.company, "EXAMPLE BANK, N.A.")
        XCTAssertEqual(first.subProduct, "Checking account")
        XCTAssertEqual(first.subIssue, "Deposits and withdrawals")
        XCTAssertEqual(first.dateReceived, "2024-03-11", "timestamps normalize to the day")
        XCTAssertEqual(first.tags, ["Servicemember"])
        XCTAssertEqual(
            first.sourceUrl,
            "https://www.consumerfinance.gov/data-research/consumer-complaints/search/detail/7001001"
        )
        // Raw preservation: the record's raw is the source _source object.
        XCTAssertEqual(first.raw["zip_code"]?.stringValue, "331XX")
        XCTAssertEqual(first.raw["complaint_id"]?.stringValue, "7001001")
    }

    func testMissingOptionalFieldsDoNotFail() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-missing-optional-fields"))])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        XCTAssertEqual(result.complaints.count, 2)
        let sparse = result.complaints[0]
        XCTAssertNil(sparse.company)
        XCTAssertNil(sparse.issue)
        XCTAssertNil(sparse.dateReceived)
        XCTAssertTrue(sparse.tags.isEmpty)
        // Numeric complaint IDs coerce to strings; empty strings become nil.
        XCTAssertEqual(result.complaints[1].complaintId, "8001002")
        XCTAssertNil(result.complaints[1].product)
        XCTAssertNil(result.complaints[1].timely)
    }

    func testRAGTextOmitsMissingNarrativeSections() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        let records = try sut.toIngestionRecords(result.complaints)

        let withNarrative = try XCTUnwrap(records.first { $0.sourceRecordId.hasSuffix("7001001") })
        XCTAssertTrue(withNarrative.ragText.contains("Consumer narrative (as submitted, an allegation):"))
        XCTAssertTrue(withNarrative.ragText.contains("hold notice"))

        let withoutNarrative = try XCTUnwrap(records.first { $0.sourceRecordId.hasSuffix("7001002") })
        XCTAssertFalse(withoutNarrative.ragText.contains("Consumer narrative"), withoutNarrative.ragText)
        XCTAssertFalse(withoutNarrative.ragText.contains("Company public response"), withoutNarrative.ragText)
        XCTAssertFalse(withoutNarrative.ragText.lowercased().contains("n/a"), withoutNarrative.ragText)
        XCTAssertTrue(withoutNarrative.ragText.contains("search/detail/7001002"))
    }

    func testCompanyProfileAggregatesNeutralFacts() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        let profile = try await sut.getCompanyComplaintProfile(
            company: "EXAMPLE BANK, N.A.",
            options: .init(queryOptions: .init(maxPages: 1))
        )
        XCTAssertEqual(profile.totalMatchingComplaints, 5)
        XCTAssertEqual(profile.countsByProduct["Checking or savings account"], 3)
        XCTAssertEqual(profile.countsByState["FL"], 3)
        XCTAssertEqual(profile.countsBySubmittedVia["Web"], 3)
        XCTAssertEqual(profile.timelyResponseRate ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(profile.narrativeCount, 2)
        XCTAssertEqual(profile.sampleNarratives.count, 2)
        XCTAssertFalse(profile.trend.isEmpty)
        XCTAssertTrue(profile.limitations.contains { $0.contains("does not adjudicate") })
    }

    func testTrendsBucketsByMonthQuarterYear() async throws {
        func run(_ interval: CfpbTrendInterval) async throws -> [CfpbComplaintTrendBucket] {
            let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
            let sut = connector(stub: stub)
            return try await sut.getComplaintTrends(
                filters: .init(company: ["EXAMPLE BANK, N.A."]),
                interval: interval,
                options: .init(maxPages: 1)
            )
        }
        let monthly = try await run(.month)
        XCTAssertEqual(monthly.map(\.intervalStart), ["2023-10-01", "2023-11-01", "2024-02-01", "2024-03-01"])
        XCTAssertEqual(monthly.last?.count, 2)
        XCTAssertEqual(monthly.last?.intervalEnd, "2024-03-31")
        // Company filter present → no per-bucket company breakdown.
        XCTAssertTrue(monthly.allSatisfy { $0.topCompanies.isEmpty })

        let quarterly = try await run(.quarter)
        XCTAssertEqual(quarterly.map(\.intervalStart), ["2023-10-01", "2024-01-01"])
        XCTAssertEqual(quarterly.first?.intervalEnd, "2023-12-31")
        XCTAssertEqual(quarterly.last?.count, 3)

        let yearly = try await run(.year)
        XCTAssertEqual(yearly.map(\.intervalStart), ["2023-01-01", "2024-01-01"])
        XCTAssertEqual(yearly.map(\.count), [2, 3])

        // The documented /trends response parses as a counts-only cross-check.
        let counts = CfpbComplaintAggregations.parseTrendCounts(
            try JSONValue.fromData(fixture("trends-month"))
        )
        XCTAssertEqual(counts.map(\.count), [42, 35, 51])
        XCTAssertEqual(counts.first?.day, "2024-01-01")
    }

    func testCacheHitSkipsNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfpb-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub, cache: FileLegalDataConnectorCache(directory: dir))
        _ = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        let second = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        XCTAssertEqual(second.complaints.count, 5)
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1)
    }

    func testTransientFailureRetries() async throws {
        let stub = ScriptedHTTPStub(script: [
            .status(429, headers: ["Retry-After": "0"]),
            .success(try fixture("search-complaints-small"))
        ])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(options: .init(maxPages: 1)))
        XCTAssertEqual(result.complaints.count, 5)
        let calls = await stub.callCount
        XCTAssertEqual(calls, 2)
    }

    func testRatePacerRunsBeforeRequests() async {
        let recorder = SleepRecorder()
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let config = configuration()
        let pacer = ConnectorPacer(
            requestsPerSecond: config.cfpbRateLimitPerSecond,
            now: { clock.now() },
            sleeper: { await recorder.record($0) }
        )
        await pacer.pace()
        await pacer.pace()
        let sleeps = await recorder.sleeps
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0], 1.0 / config.cfpbRateLimitPerSecond, accuracy: 0.001)
    }

    func testNeutralSummaryDoesNotUseLegalConclusionWords() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        let profile = try await sut.getCompanyComplaintProfile(
            company: "EXAMPLE BANK, N.A.",
            options: .init(queryOptions: .init(maxPages: 1))
        )
        let summary = CfpbComplaintNormalizer.summaryText(for: profile)
        XCTAssertTrue(summary.contains("database contains"), summary)
        XCTAssertTrue(summary.contains("complaints matching"), summary)
        for forbidden in ["violated", "liable", "proven", "adjudicated", "meritorious"] {
            XCTAssertFalse(summary.lowercased().contains(forbidden), "\(forbidden) in: \(summary)")
        }
    }

    func testClientSideFiltersRecordLimitations() async throws {
        let stub = ScriptedHTTPStub(script: [.success(try fixture("search-complaints-small"))])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(
            filters: .init(subProduct: ["Checking account"]),
            options: .init(maxPages: 1)
        ))
        XCTAssertEqual(result.complaints.count, 2)
        XCTAssertTrue(result.complaints.allSatisfy { $0.subProduct == "Checking account" })
        XCTAssertTrue(result.sourceLimitations.contains { $0.contains("sub_product") })
    }

    func testSuggestCompaniesResolvesCanonicalNames() async throws {
        let stub = ScriptedHTTPStub(script: [
            .success(Data(#"["BANK OF AMERICA, NATIONAL ASSOCIATION","BANK OF AMERICA CORPORATION"]"#.utf8))
        ])
        let sut = connector(stub: stub)
        let names = try await sut.suggestCompanies("bank of america")
        XCTAssertEqual(names, ["BANK OF AMERICA, NATIONAL ASSOCIATION", "BANK OF AMERICA CORPORATION"])
        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("_suggest_company"), url)
        XCTAssertTrue(url.contains("text=bank%20of%20america"), url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
    }

    func testSuggestCompaniesBlankInputSkipsNetwork() async throws {
        let stub = ScriptedHTTPStub(script: [])
        let sut = connector(stub: stub)
        let names = try await sut.suggestCompanies("   ")
        XCTAssertEqual(names, [])
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0)
    }

    func testDroppedRecordDoesNotEndPaginationEarly() async throws {
        // Page 1 is FULL (2 raw hits) but one hit has no complaint_id and is
        // dropped — pagination must continue on the RAW count and disclose
        // the omission. Page 2 is short, ending the walk.
        let page1 = Data(#"{"hits":{"total":{"value":3,"relation":"eq"},"hits":[{"_source":{"complaint_id":"9001001","product":"Debt collection","state":"FL","date_received":"2024-01-05T12:00:00-05:00"}},{"_source":{"product":"Mortgage"}}]}}"#.utf8)
        let page2 = Data(#"{"hits":{"total":{"value":3,"relation":"eq"},"hits":[{"_source":{"complaint_id":"9001003","product":"Mortgage","state":"FL","date_received":"2024-01-07T12:00:00-05:00"}}]}}"#.utf8)
        let stub = ScriptedHTTPStub(script: [.success(page1), .success(page2)])
        let sut = connector(stub: stub)
        let result = try await sut.searchComplaints(CfpbComplaintQuery(
            options: .init(size: 2, maxPages: 5)
        ))
        XCTAssertEqual(result.pagesFetched, 2)
        XCTAssertEqual(result.complaints.map(\.complaintId), ["9001001", "9001003"])
        XCTAssertTrue(result.sourceLimitations.contains { $0.contains("could not be normalized") })
        let calls = await stub.callCount
        XCTAssertEqual(calls, 2)
    }
}

/// OPT-IN live probe — narrow query, tiny page. Skipped by default.
final class CfpbComplaintLiveTests: XCTestCase {
    func testLiveNarrowSearchProbe() async throws {
        let configuration = LegalDataConnectorConfiguration.fromEnvironment()
        try XCTSkipUnless(configuration.liveTestsEnabled, "live tests are opt-in")
        let connector = CfpbComplaintConnector(
            httpClient: LivePolicyHTTPClient(),
            configuration: configuration,
            cache: NoopConnectorCache()
        )
        let result = try await connector.searchComplaints(CfpbComplaintQuery(
            filters: .init(state: ["FL"]),
            options: .init(size: 5, maxPages: 1)
        ))
        XCTAssertFalse(result.complaints.isEmpty)
    }
}
