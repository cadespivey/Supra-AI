import SupraCore
@testable import SupraNetworking
import SupraStore
import XCTest

final class SupraNetworkingTests: XCTestCase {
    func testModuleExposesCourtListenerKeychainConstants() {
        XCTAssertEqual(SupraNetworkingModule.courtListenerService, "com.supraai.courtlistener")
        XCTAssertEqual(SupraNetworkingModule.courtListenerTokenAccount, "api-token")
    }

    func testNetworkPolicyAllowsOnlyHTTPSCourtListenerWithoutCredentials() throws {
        let policy = NetworkPolicyService()

        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/"))))
        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://courtlistener.com/api/rest/v4/search/"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "http://www.courtlistener.com/api/rest/v4/search/"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://example.com/api/rest/v4/search/"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://user:pass@www.courtlistener.com/api/rest/v4/search/"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://www.courtlistener.com:8443/api/rest/v4/search/"))))

        let explicitlyPorted = NetworkPolicyService(
            allowedHosts: ["api.synthetic.test"],
            allowedPortsByHost: ["api.synthetic.test": [8443]]
        )
        XCTAssertNoThrow(
            try explicitlyPorted.validate(
                try XCTUnwrap(URL(string: "https://api.synthetic.test:8443/data"))
            )
        )
        XCTAssertThrowsError(
            try explicitlyPorted.validate(
                try XCTUnwrap(URL(string: "https://api.synthetic.test:9443/data"))
            )
        )
    }

    func testNetworkPolicyAllowsCourtListenerStorageCDNButNotOtherHosts() throws {
        let policy = NetworkPolicyService()
        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://storage.courtlistener.com/pdf/2009/file.pdf"))))
        // A look-alike / arbitrary storage host is still blocked.
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://storage.example.com/x.pdf"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "http://storage.courtlistener.com/x.pdf"))))
    }

    func testRateLimitTrackerBlocksAtConfiguredLimit() async throws {
        let tracker = RateLimitTracker(limits: .init(perMinute: 2, perHour: 10, perDay: 10))
        let now = Date()

        _ = try await tracker.reserveSlot(now: now)
        let snapshot = try await tracker.reserveSlot(now: now.addingTimeInterval(1))

        XCTAssertEqual(snapshot.requestsLastMinute, 2)
        do {
            _ = try await tracker.reserveSlot(now: now.addingTimeInterval(2))
            XCTFail("Expected rate limit to block the third request.")
        } catch NetworkPolicyError.localRateLimitExceeded(let snapshot) {
            XCTAssertEqual(snapshot.requestsLastMinute, 2)
        }
    }

    func testNetworkRequestLoggerPersistsBlockedRequest() async throws {
        let store = try makeStore()
        let logger = NetworkRequestLogger(repository: store.networkRequests)
        let url = try XCTUnwrap(URL(string: "https://example.com/blocked?q=tokenless"))

        let id = try await logger.recordBlockedRequest(
            url: url,
            method: "GET",
            blockedReason: "hostNotAllowed"
        )

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.domain, "example.com")
        XCTAssertEqual(record.endpoint, "/blocked")
        XCTAssertFalse(record.approved)
        XCTAssertEqual(record.blockedReason, "hostNotAllowed")
    }

    func testAuthorizedHTTPClientInjectsHeadersAndRedactsAuthorizationFromLog() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            rateLimitTracker: RateLimitTracker(),
            transport: { request in
                await spy.respond(to: request, statusCode: 200)
            }
        )
        let url = try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/?q=contract&type=o"))

        let (_, response) = try await client.send(URLRequest(url: url), relatedResearchSessionID: nil)

        XCTAssertEqual(response.statusCode, 200)
        let sentRequest = await spy.lastRequest()
        XCTAssertEqual(sentRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sentRequest?.value(forHTTPHeaderField: "Authorization"), "Token secret-token")

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        XCTAssertTrue(record.approved)
        XCTAssertEqual(record.statusCode, 200)
        XCTAssertEqual(record.endpoint, "/api/rest/v4/search")
        XCTAssertFalse(record.requestMetadataJSON?.localizedCaseInsensitiveContains("authorization") ?? true)
    }

    func testAuthorizedHTTPClientRedactsAPIKeyHeadersFromLog() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: nil),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            rateLimitTracker: RateLimitTracker(),
            transport: { request in
                await spy.respond(to: request, statusCode: 200)
            }
        )
        let url = try XCTUnwrap(URL(string: "https://api.govinfo.gov/search"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("govinfo-secret", forHTTPHeaderField: "X-Api-Key")
        request.setValue("probe-1", forHTTPHeaderField: "X-Request-ID")

        _ = try await client.sendUnauthenticated(request, relatedResearchSessionID: nil)

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        let metadata = try XCTUnwrap(record.requestMetadataJSON)
        XCTAssertFalse(metadata.contains("govinfo-secret"), "API keys must never be persisted in request metadata")
        XCTAssertTrue(metadata.contains("\"X-Api-Key\":\"#redacted\""))
        XCTAssertTrue(metadata.contains("\"X-Request-ID\":\"probe-1\""))
    }

    func testAuthenticatedSendToStorageCDNRefusesRatherThanLeakToken() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            rateLimitTracker: RateLimitTracker(),
            transport: { request in await spy.respond(to: request, statusCode: 200) }
        )
        // The CDN host is on the allow-list (for token-free PDF downloads), but the
        // token must never be sent there. An authenticated send must refuse.
        let cdn = try XCTUnwrap(URL(string: "https://storage.courtlistener.com/pdf/2009/04/foo.pdf"))
        do {
            _ = try await client.send(URLRequest(url: cdn), relatedResearchSessionID: nil)
            XCTFail("an authenticated send to the storage CDN must refuse, not attach the token")
        } catch let error as AuthorizedHTTPClientError {
            XCTAssertEqual(error, .tokenHostNotAllowed)
        }
        let sent = await spy.lastRequest()
        XCTAssertNil(sent, "no request (and therefore no token) should reach the CDN")
    }

    func testAuthorizedHTTPClientRedactsPrivilegedQueryTermsFromLogByDefault() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            transport: { request in await spy.respond(to: request, statusCode: 200) }
        )
        let url = try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/?q=trade%20secret%20misappropriation&type=o"))
        _ = try await client.send(URLRequest(url: url))

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        let metadata = record.requestMetadataJSON ?? ""
        XCTAssertFalse(metadata.localizedCaseInsensitiveContains("misappropriation"), "raw privileged query terms must not be persisted")
        XCTAssertFalse(metadata.localizedCaseInsensitiveContains("trade"), "raw privileged query terms must not be persisted")
        XCTAssertTrue(metadata.contains("q="), "the parameter name should still be recorded for auditability")
        // The transport still receives the real, un-redacted query.
        let sent = await spy.lastRequest()
        XCTAssertTrue(sent?.url?.query?.contains("misappropriation") ?? false)
    }

    func testAuthorizedHTTPClientKeepsQueryTermsWhenLoggingExplicitlyEnabled() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            redactsQueryValues: false,
            transport: { request in await spy.respond(to: request, statusCode: 200) }
        )
        let url = try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/?q=noncompete&type=o"))
        _ = try await client.send(URLRequest(url: url))

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        XCTAssertTrue(record.requestMetadataJSON?.localizedCaseInsensitiveContains("noncompete") ?? false)
    }

    func testAuthorizedHTTPClientAlwaysRedactsSensitiveQueryParameters() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: nil),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            redactsQueryValues: false,
            transport: { request in await spy.respond(to: request, statusCode: 200) }
        )
        let url = try XCTUnwrap(URL(string: "https://api.govinfo.gov/search?key=queryparam-secret&op=getSearch&query=noncompete&X-Api-Key=second-secret"))

        _ = try await client.sendUnauthenticated(URLRequest(url: url))

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        let metadata = try XCTUnwrap(record.requestMetadataJSON)
        XCTAssertFalse(metadata.contains("queryparam-secret"), "query-string API keys must never be persisted")
        XCTAssertFalse(metadata.contains("second-secret"), "query-string API keys must never be persisted")
        XCTAssertTrue(metadata.contains("key=#redacted"))
        XCTAssertTrue(metadata.contains("X-Api-Key=#redacted"))
        XCTAssertTrue(metadata.contains("query=noncompete"), "non-sensitive query terms can still be logged when explicitly enabled")
    }

    func testAuthorizedHTTPClientLogsBlockedPolicyRequestWithoutSending() async throws {
        let store = try makeStore()
        let spy = TransportSpy()
        let client = AuthorizedHTTPClient(
            keyStore: InMemoryKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            rateLimitTracker: RateLimitTracker(),
            transport: { request in
                await spy.respond(to: request, statusCode: 200)
            }
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/api/rest/v4/search/"))

        do {
            _ = try await client.send(URLRequest(url: url), relatedResearchSessionID: nil)
            XCTFail("Expected blocked host to throw.")
        } catch NetworkPolicyError.hostNotAllowed(let host) {
            XCTAssertEqual(host, "example.com")
        }

        let requestCount = await spy.requestCount()
        XCTAssertEqual(requestCount, 0)
        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).single)
        XCTAssertFalse(record.approved)
        XCTAssertEqual(record.domain, "example.com")
    }

    func testGovernmentRecordsConnectorHostsAreAllowListedSafely() throws {
        let policy = NetworkPolicyService()
        // Exactly the hosts the connectors FETCH — HTTPS only.
        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://data.sec.gov/submissions/CIK0000320193.json"))))
        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"))))
        XCTAssertTrue(policy.isAllowed(try XCTUnwrap(URL(string: "https://www.nlrb.gov/reports/graphs-data/recent-filings"))))
        // Plain HTTP is rejected.
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "http://data.sec.gov/submissions/CIK0000320193.json"))))
        // Embedded credentials are rejected.
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://user:pass@www.consumerfinance.gov/api/v1/"))))
        // Unlisted subdomains and apex domains stay denied (default-deny).
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://example.nlrb.gov/x"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://sec.gov/x"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://www.sec.gov/Archives/edgar/data/320193/x"))))
        XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://catalog.data.gov/dataset"))))
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraNetworkingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private final class InMemoryKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func saveCourtListenerToken(_ token: String) throws {
        self.token = token
    }

    func loadCourtListenerToken() throws -> String? {
        token
    }

    func deleteCourtListenerToken() throws {
        token = nil
    }

    func hasCourtListenerToken() throws -> Bool {
        token != nil
    }
}

private actor TransportSpy {
    private var recordedRequests: [URLRequest] = []

    func respond(to request: URLRequest, statusCode: Int) -> (Data, URLResponse) {
        recordedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }

    func lastRequest() -> URLRequest? {
        recordedRequests.last
    }

    func requestCount() -> Int {
        recordedRequests.count
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
