import SupraCore
import SupraNetworking
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
