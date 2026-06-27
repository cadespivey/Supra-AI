import Foundation
import SupraNetworking
import SupraResearch
import XCTest

final class OpenLegalCodesClientTests: XCTestCase {

    // MARK: - Success paths (JSON modeled from live OLC responses)

    func testSearchCodeDecodesResultsAndTargetsTheCodeEndpoint() async throws {
        let json = """
        {"data":{"jurisdiction":"fl-statutes","jurisdictionName":"Florida Statutes","codeId":"_default","query":"statute of frauds","results":[{"path":"title-xxxix/chapter-672/section-672.201","num":"§ 672.201","heading":"Formal requirements; statute of frauds","snippet":"...a contract for the sale of goods for the price of $500 or more...","url":"https://openlegalcodes.org/fl/statutes/672.201"}]},"meta":{"timestamp":"2026-06-27T00:00:00Z","poweredBy":"TIDY"}}
        """
        let stub = StubUnauthClient(statusCode: 200, json: json)
        let client = OpenLegalCodesClient(httpClient: stub)

        let results = try await client.searchCode(jurisdictionID: "fl-statutes", query: "statute of frauds")

        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results.first?.num, "§ 672.201")
        let url = await stub.lastURL()
        XCTAssertTrue(url?.absoluteString.contains("/jurisdictions/fl-statutes/search") ?? false, "must target the code's search endpoint")
        XCTAssertTrue(url?.query?.contains("q=") ?? false)
    }

    func testFetchSectionDecodesFullText() async throws {
        let json = """
        {"data":{"jurisdiction":"us-cfr-title-1","jurisdictionName":"CFR Title 1","codeId":"_default","path":"chapter-i/subchapter-a/part-1/section-1.1","num":"§ 1.1","heading":"Definitions","level":"section","text":"§ 1.1 Definitions. As used in this chapter...","url":"https://openlegalcodes.org/federal/cfr-title-1/section-1.1"},"meta":{}}
        """
        let stub = StubUnauthClient(statusCode: 200, json: json)
        let client = OpenLegalCodesClient(httpClient: stub)

        let section = try await client.fetchSection(jurisdictionID: "us-cfr-title-1", path: "chapter-i/subchapter-a/part-1/section-1.1")

        XCTAssertEqual(section.num, "§ 1.1")
        XCTAssertTrue(section.text.contains("Definitions"))
        let url = await stub.lastURL()
        XCTAssertTrue(url?.absoluteString.hasSuffix("/code/chapter-i/subchapter-a/part-1/section-1.1") ?? false, "section path segments must be preserved")
    }

    func testJurisdictionReportsMissingFreshnessAndNotCached() async throws {
        // The exact fl-statutes detail shape observed live: empty freshness stamps, status "available".
        let json = """
        {"data":{"id":"fl-statutes","name":"Florida Statutes","type":"state","state":"FL","parentId":null,"sourceUrl":"http://www.leg.state.fl.us/statutes/","lastCrawled":"","lastUpdated":"","lastScanned":"","status":"available","publisher":{"name":"fl-statutes","sourceId":"FL","url":"http://www.leg.state.fl.us/statutes/"}},"meta":{}}
        """
        let stub = StubUnauthClient(statusCode: 200, json: json)
        let client = OpenLegalCodesClient(httpClient: stub)

        let j = try await client.jurisdiction(id: "fl-statutes")
        XCTAssertFalse(j.isCached, "status 'available' is not cached")
        XCTAssertFalse(j.hasFreshnessStamp, "OLC exposes no usable currency stamp for fl-statutes")
        XCTAssertEqual(j.sourceUrl, "http://www.leg.state.fl.us/statutes/")
    }

    // MARK: - Crawl states (the reliability surface)

    func testCrawlInProgressThrowsTransientWithRetryAfter() async throws {
        let json = """
        {"status":"CRAWL_IN_PROGRESS","message":"Data for 'fl-statutes' is being fetched.","progress":{"phase":"toc","total":0,"completed":0},"startedAt":"2026-06-27T00:00:00Z","retryAfter":30}
        """
        let client = OpenLegalCodesClient(httpClient: StubUnauthClient(statusCode: 202, json: json))
        do {
            _ = try await client.searchCode(jurisdictionID: "fl-statutes", query: "x")
            XCTFail("expected crawlInProgress")
        } catch let error as OpenLegalCodesError {
            guard case let .crawlInProgress(retryAfter) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(retryAfter, 30)
            XCTAssertTrue(error.isTransient)
        }
    }

    func testCrawlFailedCarriesReason() async throws {
        let json = """
        {"status":"CRAWL_FAILED","message":"Data fetch for 'fl-statutes' failed. Will retry automatically.","error":"database or disk is full","retryAfter":549}
        """
        let client = OpenLegalCodesClient(httpClient: StubUnauthClient(statusCode: 503, json: json))
        do {
            _ = try await client.fetchSection(jurisdictionID: "fl-statutes", path: "x")
            XCTFail("expected crawlFailed")
        } catch let error as OpenLegalCodesError {
            guard case let .crawlFailed(reason, _) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(reason.contains("disk is full"))
            XCTAssertTrue(error.isTransient)
        }
    }

    func testBadRequestSurfacesDetail() async throws {
        let client = OpenLegalCodesClient(httpClient: StubUnauthClient(statusCode: 400, json: "missing required parameter: q"))
        do {
            _ = try await client.searchAcross(query: "", state: "FL", limit: nil, relatedResearchSessionID: nil)
            XCTFail("expected badRequest")
        } catch let error as OpenLegalCodesError {
            guard case .badRequest = error else { return XCTFail("got \(error)") }
            XCTAssertFalse(error.isTransient)
        }
    }
}

/// Records request URLs and returns a fixed status + body over the unauthenticated path
/// (OLC never receives the CourtListener token).
private actor StubUnauthClient: AuthorizedHTTPClientProtocol {
    private let statusCode: Int
    private let data: Data
    private var urls: [URL] = []

    init(statusCode: Int, json: String) {
        self.statusCode = statusCode
        self.data = Data(json.utf8)
    }

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        // OLC must never use the authenticated path; fail loudly if it does.
        throw AuthorizedHTTPClientError.invalidResponse
    }

    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        urls.append(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func lastURL() -> URL? { urls.last }
}
