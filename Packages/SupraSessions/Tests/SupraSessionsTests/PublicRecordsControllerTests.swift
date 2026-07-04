import Foundation
import SupraNetworking
import SupraResearch
import XCTest
@testable import SupraSessions

/// Hermetic PublicRecordsController tests: connectors run against a scripted
/// HTTP stub — no network, no keychain, no CourtListener token path.
@MainActor
final class PublicRecordsControllerTests: XCTestCase {

    // MARK: - Doubles

    private actor StubHTTPClient: AuthorizedHTTPClientProtocol {
        enum Step {
            case success(Data)
            case status(Int)
        }
        private var script: [Step]
        private(set) var authenticatedSendCount = 0
        init(script: [Step]) { self.script = script }

        func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
            authenticatedSendCount += 1
            throw URLError(.userAuthenticationRequired)
        }

        func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
            guard !script.isEmpty else { throw URLError(.cannotConnectToHost) }
            let step = script.removeFirst()
            let url = request.url ?? URL(string: "https://example.gov")!
            switch step {
            case .success(let data):
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .status(let code):
                return (Data(), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private struct NoCache: LegalDataConnectorCache {
        func get(key: String, now: Date) async throws -> LegalDataCacheEntry? { nil }
        func put(_ entry: LegalDataCacheEntry, key: String) async throws {}
        func removeExpired(now: Date) async throws {}
    }

    private func makeController(
        secScript: [StubHTTPClient.Step] = [],
        cfpbScript: [StubHTTPClient.Step] = [],
        nlrbScript: [StubHTTPClient.Step] = []
    ) -> (PublicRecordsController, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-records-tests-\(UUID().uuidString)", isDirectory: true)
        let configuration = LegalDataConnectorConfiguration(
            cacheDirectory: dir.appendingPathComponent("cache"),
            nlrbLocalDataDirectory: dir.appendingPathComponent("nlrb"),
            secEdgarUserAgent: "SupraAITests/1.0 (https://supralegal.ai)"
        )
        let controller = PublicRecordsController(
            secConnector: SecEdgarConnector(
                httpClient: StubHTTPClient(script: secScript),
                configuration: configuration,
                cache: NoCache()
            ),
            cfpbConnector: CfpbComplaintConnector(
                httpClient: StubHTTPClient(script: cfpbScript),
                configuration: configuration,
                cache: NoCache()
            ),
            nlrbConnector: NlrbDataConnector(
                httpClient: StubHTTPClient(script: nlrbScript),
                configuration: configuration,
                cache: NoCache(),
                localStore: NlrbLocalRecordStore(directory: configuration.nlrbLocalDataDirectory)
            )
        )
        return (controller, dir)
    }

    // MARK: - SEC

    func testSecSearchPopulatesCompanyAndFilings() async throws {
        let submissions = Data("""
        {"cik":"0000320193","name":"Apple Inc.","tickers":["AAPL"],"exchanges":["Nasdaq"],
         "sic":"3571","sicDescription":"Electronic Computers",
         "filings":{"recent":{
            "accessionNumber":["0000320193-24-000001","0000320193-24-000002"],
            "form":["10-K","8-K"],
            "filingDate":["2024-11-01","2024-08-01"],
            "primaryDocument":["aapl-10k.htm","aapl-8k.htm"],
            "primaryDocDescription":["Annual report","Current report"]
         },"files":[]}}
        """.utf8)
        // Exactly ONE scripted response (no cache): if the controller
        // re-fetched submissions per scope, the second fetch would hit the
        // empty script and fail, so `.loaded` proves a single fetch.
        let (controller, dir) = makeController(secScript: [.success(submissions)])
        defer { try? FileManager.default.removeItem(at: dir) }

        await controller.searchSecFilings(cik: "320193", scope: .all)
        XCTAssertEqual(controller.secPhase, .loaded, "one submissions fetch should satisfy the whole search")
        XCTAssertEqual(controller.secCompany?.entityName, "Apple Inc.")
        XCTAssertEqual(controller.secFilings.map(\.form), ["10-K", "8-K"])
        XCTAssertTrue(controller.secFilings.allSatisfy { $0.filingUrl.hasPrefix("https://www.sec.gov/") })
    }

    func testSecFailureSurfacesSanitizedMessage() async throws {
        let (controller, dir) = makeController(secScript: [.status(404)])
        defer { try? FileManager.default.removeItem(at: dir) }

        await controller.searchSecFilings(cik: "999999999", scope: .all)
        guard case .failed(let message) = controller.secPhase else {
            return XCTFail("expected failure, got \(controller.secPhase)")
        }
        XCTAssertFalse(message.contains("SupraAITests"), "User-Agent must never surface in errors")
        XCTAssertFalse(message.contains("/var/"), "no local paths in user-facing messages")
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - CFPB

    func testCfpbSearchMapsComplaintsAndLimitations() async throws {
        let page = Data("""
        {"hits":{"total":{"value":2,"relation":"eq"},"hits":[
          {"_source":{"complaint_id":"7001001","company":"EXAMPLE BANK, N.A.","product":"Checking or savings account",
           "issue":"Managing an account","state":"FL","date_received":"2024-03-11T12:00:00-05:00",
           "company_response":"Closed with explanation","timely":"Yes"}},
          {"_source":{"complaint_id":"7001002","company":"EXAMPLE BANK, N.A.","product":"Mortgage",
           "issue":"Trouble during payment process","state":"FL","date_received":"2024-02-01T12:00:00-05:00"}}
        ]}}
        """.utf8)
        let suggest = Data(#"["EXAMPLE BANK, N.A."]"#.utf8)
        let (controller, dir) = makeController(cfpbScript: [.success(suggest), .success(page)])
        defer { try? FileManager.default.removeItem(at: dir) }

        await controller.searchCfpbComplaints(company: "Example Bank", state: "fl", product: "")
        XCTAssertEqual(controller.cfpbPhase, .loaded)
        let result = try XCTUnwrap(controller.cfpbResult)
        XCTAssertTrue(result.sourceLimitations.contains { $0.contains("Company matched as: EXAMPLE BANK, N.A.") },
                      "the canonical-name resolution must be disclosed: \(result.sourceLimitations)")
        XCTAssertEqual(result.complaints.map(\.complaintId), ["7001001", "7001002"])
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertTrue(result.complaints.allSatisfy {
            $0.sourceUrl.hasPrefix("https://www.consumerfinance.gov/")
        })
        // Neutral framing survives to the UI layer.
        let text = result.complaints.compactMap(\.narrative).joined()
        XCTAssertFalse(text.lowercased().contains("proven"))
    }

    func testBlankCfpbInputsDoNotSearch() async {
        let (controller, dir) = makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        await controller.searchCfpbComplaints(company: "  ", state: "", product: "")
        XCTAssertEqual(controller.cfpbPhase, .idle, "blank input must not hit the network")
    }

    // MARK: - NLRB

    func testNlrbImportThenPartySearchFlow() async throws {
        let csv = "Case Number,Case Name,Case Type,Region Assigned,Date Filed,Status,Employer,Union\r\n" +
            "01-CA-345678,\"Riverside Logistics, Inc.\",CA,\"Region 01, Boston\",03/11/2024,Open,\"Riverside Logistics, Inc.\",Teamsters Local 25\r\n"
        let (controller, dir) = makeController(nlrbScript: [.success(Data(csv.utf8))])
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = NlrbDatasetSource(
            name: "Recent filings",
            sourceVariant: .officialRecentFilings,
            status: .available,
            downloadUrl: "https://www.nlrb.gov/reports/graphs-data/recent-filings/export?_format=csv",
            pageUrl: nil, note: nil, discoveredAt: Date()
        )
        await controller.importNlrbDataset(source)
        XCTAssertEqual(controller.nlrbImportStatus, "Imported 1 new record(s).")

        await controller.searchNlrbParty("Riverside Logistics")
        XCTAssertEqual(controller.nlrbPhase, .loaded)
        let summary = try XCTUnwrap(controller.nlrbSummary)
        XCTAssertEqual(summary.totalMatchingCaseRecords, 1)
        XCTAssertTrue(summary.summaryText.contains("matching case records"))
        XCTAssertFalse(summary.summaryText.lowercased().contains("violation"))
        XCTAssertEqual(controller.nlrbCaseMatches.map(\.caseNumber), ["01-CA-345678"])
    }

    func testNlrbOffHostImportIsRejected() async {
        let (controller, dir) = makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tampered = NlrbDatasetSource(
            name: "Recent filings",
            sourceVariant: .officialRecentFilings,
            status: .available,
            downloadUrl: "https://api.regulations.gov/v4/documents",
            pageUrl: nil, note: nil, discoveredAt: Date()
        )
        await controller.importNlrbDataset(tampered)
        let status = controller.nlrbImportStatus ?? ""
        XCTAssertTrue(status.contains("www.nlrb.gov"), "rejection reason should name the required host: \(status)")
    }

    // MARK: - Error mapping

    func testNonConnectorErrorsGetGenericMessage() {
        let message = PublicRecordsController.userMessage(for: URLError(.timedOut))
        XCTAssertEqual(message, "The request could not be completed. Check the network log in Diagnostics.")
    }
}
