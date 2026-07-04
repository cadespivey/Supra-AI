import SupraNetworking
import XCTest
@testable import SupraResearch

/// Shared government-data connector infrastructure: configuration parsing,
/// the file cache, the pacer, and the canonical-JSON hashing seam.
final class LegalDataConnectorInfrastructureTests: XCTestCase {

    // MARK: - Configuration

    func testConfigurationDefaults() {
        let config = LegalDataConnectorConfiguration.fromEnvironment([:])
        XCTAssertFalse(config.cacheDirectory.path.isEmpty)
        XCTAssertTrue(config.cacheDirectory.path.contains("LegalDataConnectors"))
        XCTAssertFalse(config.liveTestsEnabled)
        XCTAssertNil(config.secEdgarUserAgent)
        XCTAssertEqual(config.secEdgarRateLimitPerSecond, 2)
        XCTAssertEqual(config.cfpbRateLimitPerSecond, 2)
        XCTAssertEqual(config.nlrbRateLimitPerSecond, 1)
    }

    func testConfigurationEnvironmentOverridesAndClamps() {
        let config = LegalDataConnectorConfiguration.fromEnvironment([
            "SUPRA_SEC_EDGAR_USER_AGENT": "  Firm Name dev@example.com  ",
            "SUPRA_SEC_EDGAR_RATE_LIMIT_PER_SECOND": "50",
            "SUPRA_CFPB_RATE_LIMIT_PER_SECOND": "0.01",
            "SUPRA_NLRB_RATE_LIMIT_PER_SECOND": "not-a-number",
            "SUPRA_LEGAL_DATA_CACHE_DIR": "/tmp/supra-connector-tests",
            "SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS": "YES"
        ])
        XCTAssertEqual(config.secEdgarUserAgent, "Firm Name dev@example.com")
        XCTAssertEqual(config.secEdgarRateLimitPerSecond, 10, "SEC rate clamps at 10 rps")
        XCTAssertEqual(config.cfpbRateLimitPerSecond, 0.1, "CFPB rate clamps to the floor")
        XCTAssertEqual(config.nlrbRateLimitPerSecond, 1, "garbage falls back to the default")
        XCTAssertEqual(config.cacheDirectory.path, "/tmp/supra-connector-tests")
        XCTAssertTrue(config.liveTestsEnabled)
    }

    func testInvalidBooleanFallsBackWithoutCrashing() {
        let config = LegalDataConnectorConfiguration.fromEnvironment([
            "SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS": "maybe"
        ])
        XCTAssertFalse(config.liveTestsEnabled)
    }

    func testRequireSecUserAgentFailsFastWithoutEchoingValue() {
        let config = LegalDataConnectorConfiguration.fromEnvironment([:])
        XCTAssertThrowsError(
            try config.requireSecEdgarUserAgent(connectorName: "sec_edgar", operation: "getCompanySubmissions")
        ) { error in
            guard let error = error as? LegalDataConnectorError else { return XCTFail("wrong error type") }
            XCTAssertEqual(error.kind, .config)
            XCTAssertFalse(error.retryable)
        }
    }

    // MARK: - JSONValue

    func testJSONValueRoundTripAndCanonicalForm() throws {
        let data = Data(#"{"b": 2, "a": [1, "x", true, null], "c": {"nested": 1.5}}"#.utf8)
        let value = try JSONValue.fromData(data)
        XCTAssertEqual(
            value.canonicalJSONString(),
            #"{"a":[1,"x",true,null],"b":2,"c":{"nested":1.5}}"#
        )
        // Canonical form is stable across key order.
        let reordered = try JSONValue.fromData(Data(#"{"c": {"nested": 1.5}, "a": [1, "x", true, null], "b": 2}"#.utf8))
        XCTAssertEqual(value.canonicalJSONString(), reordered.canonicalJSONString())
    }

    // MARK: - Cache

    private func makeTemporaryCache() -> (FileLegalDataConnectorCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connector-cache-tests-\(UUID().uuidString)", isDirectory: true)
        return (FileLegalDataConnectorCache(directory: dir), dir)
    }

    private func makeEntry(expiresAt: Date?, payload: String = "payload") -> LegalDataCacheEntry {
        LegalDataCacheEntry(
            connectorName: "test_connector",
            operation: "op",
            requestURL: "https://example.gov/x",
            requestParams: .object(["q": .string("v")]),
            retrievedAt: Date(),
            expiresAt: expiresAt,
            httpStatus: 200,
            rawPayload: Data(payload.utf8)
        )
    }

    func testCacheHitMissAndExpiry() async throws {
        let (cache, dir) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = FileLegalDataConnectorCache.cacheKey(
            method: "GET",
            url: URL(string: "https://example.gov/x?a=1")!,
            params: .object([:])
        )
        let now = Date()

        let miss = try await cache.get(key: key, now: now)
        XCTAssertNil(miss)

        try await cache.put(makeEntry(expiresAt: now.addingTimeInterval(60)), key: key)
        let hit = try await cache.get(key: key, now: now)
        XCTAssertEqual(hit?.rawPayload, Data("payload".utf8))

        let expired = try await cache.get(key: key, now: now.addingTimeInterval(120))
        XCTAssertNil(expired, "expired entries read as misses")
    }

    func testCorruptAndTamperedEntriesReadAsMisses() async throws {
        let (cache, dir) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = FileLegalDataConnectorCache.cacheKey(
            method: "GET",
            url: URL(string: "https://example.gov/y")!,
            params: .object([:])
        )
        try await cache.put(makeEntry(expiresAt: nil), key: key)

        // Tamper: flip the payload without updating the hash.
        let file = dir.appendingPathComponent(key + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["rawPayloadBase64"] = Data("tampered".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let tampered = try await cache.get(key: key, now: Date())
        XCTAssertNil(tampered, "hash mismatch reads as a miss")

        // Corrupt: unreadable JSON.
        try Data("not json".utf8).write(to: file)
        let corrupt = try await cache.get(key: key, now: Date())
        XCTAssertNil(corrupt)
    }

    func testRemoveExpiredDeletesOnlyExpiredFiles() async throws {
        let (cache, dir) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try await cache.put(makeEntry(expiresAt: now.addingTimeInterval(-10)), key: String(repeating: "a", count: 64))
        try await cache.put(makeEntry(expiresAt: now.addingTimeInterval(600)), key: String(repeating: "b", count: 64))
        try await cache.removeExpired(now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 1)
    }

    func testCacheKeyIgnoresNothingButChangesWithInputs() {
        let url = URL(string: "https://example.gov/api?x=1")!
        let a = FileLegalDataConnectorCache.cacheKey(method: "GET", url: url, params: .object([:]))
        let b = FileLegalDataConnectorCache.cacheKey(method: "POST", url: url, params: .object([:]))
        let c = FileLegalDataConnectorCache.cacheKey(method: "GET", url: url, params: .object(["p": .number(1)]))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, FileLegalDataConnectorCache.cacheKey(method: "GET", url: url, params: .object([:])))
    }

    // MARK: - Pacer

    func testPacerSleepsOnlyWithinWindow() async {
        // Deterministic clock + recorded sleeps: second call inside the window
        // sleeps the remainder; a call after the window doesn't sleep.
        let recorder = SleepRecorder()
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let pacer = ConnectorPacer(
            requestsPerSecond: 2,   // 0.5s window
            now: { clock.now() },
            sleeper: { await recorder.record($0) }
        )
        await pacer.pace()                    // first: no sleep
        clock.advance(0.1)
        await pacer.pace()                    // 0.1s elapsed → sleep ~0.4s
        clock.advance(5)
        await pacer.pace()                    // window long passed → no sleep
        let sleeps = await recorder.sleeps
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0], 0.4, accuracy: 0.01)
    }

    func testPacerSerializesConcurrentCallersUnderReentrancy() async {
        // While the first caller is suspended in the sleeper the actor can
        // admit a second — slot reservation must hand it the NEXT slot, not a
        // stale read of `lastAttempt` that lets both fire simultaneously.
        let recorder = SleepRecorder()
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let pacer = ConnectorPacer(
            requestsPerSecond: 2,   // 0.5s window
            now: { clock.now() },
            sleeper: { await recorder.record($0) }
        )
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pacer.pace() }
            group.addTask { await pacer.pace() }
        }
        let sleeps = await recorder.sleeps
        XCTAssertEqual(sleeps.count, 1, "exactly one of the two concurrent callers must wait")
        XCTAssertEqual(sleeps[0], 0.5, accuracy: 0.01)
    }

    func testExecutorReportsLocalRateBudgetAsRateLimit() async {
        // Local budget exhaustion is a retryable rate limit, not a
        // non-retryable "blocked by network policy".
        let snapshot = RateLimitTracker.Snapshot(
            requestsLastMinute: 5, requestsLastHour: 5, requestsLastDay: 5,
            limits: RateLimitTracker.Limits()
        )
        let stub = ScriptedHTTPStub(script: [
            .failure(NetworkPolicyError.localRateLimitExceeded(snapshot))
        ])
        let executor = makeExecutor(stub: stub)
        do {
            _ = try await executor.execute(
                operation: "op",
                request: URLRequest(url: URL(string: "https://example.gov/limited")!),
                cacheTTL: nil
            )
            XCTFail("expected a rate-limit error")
        } catch let error as LegalDataConnectorError {
            XCTAssertEqual(error.kind, .rateLimit)
            XCTAssertTrue(error.retryable)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1, "budget exhaustion must not burn retry attempts")
    }

    // MARK: - Executor retry + no-`send` guarantee

    func testExecutorRetriesTransientAndHonorsRetryAfter() async throws {
        let stub = ScriptedHTTPStub(script: [
            .status(503, headers: ["Retry-After": "0"]),
            .status(429, headers: [:]),
            .success(Data(#"{"ok": true}"#.utf8))
        ])
        let executor = makeExecutor(stub: stub)
        let response = try await executor.execute(
            operation: "op",
            request: URLRequest(url: URL(string: "https://example.gov/retry")!),
            cacheTTL: nil
        )
        XCTAssertEqual(response.httpStatus, 200)
        let calls = await stub.callCount
        XCTAssertEqual(calls, 3)
        let sendCalls = await stub.authenticatedSendCount
        XCTAssertEqual(sendCalls, 0, "connectors must never use the CourtListener-token `send` path")
    }

    func testExecutorRetriesHTTP500Family() async throws {
        // HTTP 500 (and other 5xx beyond 502/503/504) are taxonomy-retryable
        // and must actually be retried, not thrown after one attempt.
        for status in [500, 520] {
            let stub = ScriptedHTTPStub(script: [
                .status(status, headers: [:]),
                .status(status, headers: [:]),
                .success(Data(#"{"ok": true}"#.utf8))
            ])
            let executor = makeExecutor(stub: stub)
            let response = try await executor.execute(
                operation: "op",
                request: URLRequest(url: URL(string: "https://example.gov/five-hundred")!),
                cacheTTL: nil
            )
            XCTAssertEqual(response.httpStatus, 200, "status \(status) should retry to success")
            let calls = await stub.callCount
            XCTAssertEqual(calls, 3, "status \(status) should be retried up to maxAttempts")
        }
    }

    func testExecutorDoesNotRetryValidationOrNotFound() async {
        for status in [400, 404] {
            let stub = ScriptedHTTPStub(script: [.status(status, headers: [:]), .success(Data())])
            let executor = makeExecutor(stub: stub)
            do {
                _ = try await executor.execute(
                    operation: "op",
                    request: URLRequest(url: URL(string: "https://example.gov/no-retry")!),
                    cacheTTL: nil
                )
                XCTFail("expected error for status \(status)")
            } catch let error as LegalDataConnectorError {
                XCTAssertFalse(error.retryable)
                let calls = await stub.callCount
                XCTAssertEqual(calls, 1, "no retry for status \(status)")
            } catch {
                XCTFail("wrong error type: \(error)")
            }
        }
    }

    func testExecutorCacheHitSkipsNetwork() async throws {
        let (cache, dir) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = ScriptedHTTPStub(script: [.success(Data("fresh".utf8))])
        let executor = ConnectorHTTPExecutor(
            connectorName: "test_connector",
            httpClient: stub,
            pacer: ConnectorPacer(requestsPerSecond: 1_000),
            cache: cache,
            now: Date.init,
            retrySleeper: { _ in }
        )
        let request = URLRequest(url: URL(string: "https://example.gov/cached")!)
        let first = try await executor.execute(operation: "op", request: request, cacheTTL: 3_600)
        XCTAssertFalse(first.fromCache)
        let second = try await executor.execute(operation: "op", request: request, cacheTTL: 3_600)
        XCTAssertTrue(second.fromCache)
        XCTAssertEqual(second.data, Data("fresh".utf8))
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1, "second call must come from cache, not the network")
    }

    private func makeExecutor(stub: ScriptedHTTPStub) -> ConnectorHTTPExecutor {
        ConnectorHTTPExecutor(
            connectorName: "test_connector",
            httpClient: stub,
            pacer: ConnectorPacer(requestsPerSecond: 1_000),
            cache: NoopConnectorCache(),
            now: Date.init,
            retrySleeper: { _ in }
        )
    }
}

// MARK: - Test doubles

actor SleepRecorder {
    private(set) var sleeps: [TimeInterval] = []
    func record(_ interval: TimeInterval) { sleeps.append(interval) }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct NoopConnectorCache: LegalDataConnectorCache {
    func get(key: String, now: Date) async throws -> LegalDataCacheEntry? { nil }
    func put(_ entry: LegalDataCacheEntry, key: String) async throws {}
    func removeExpired(now: Date) async throws {}
}

/// Scripted `AuthorizedHTTPClientProtocol` stub: plays back a fixed sequence
/// of responses and counts calls, including any (forbidden) authenticated
/// `send` calls.
actor ScriptedHTTPStub: AuthorizedHTTPClientProtocol {
    enum Step {
        case success(Data)
        case status(Int, headers: [String: String])
        case failure(Error)
    }

    private var script: [Step]
    private(set) var callCount = 0
    private(set) var authenticatedSendCount = 0
    private(set) var requests: [URLRequest] = []

    init(script: [Step]) {
        self.script = script
    }

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        authenticatedSendCount += 1
        throw LegalDataConnectorError(
            kind: .config, connectorName: "stub", operation: "send",
            message: "connectors must not use the authenticated send path"
        )
    }

    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        requests.append(request)
        guard !script.isEmpty else {
            throw URLError(.cannotConnectToHost)
        }
        let step = script.removeFirst()
        let url = request.url ?? URL(string: "https://example.gov")!
        switch step {
        case .success(let data):
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .status(let code, let headers):
            return (Data(), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
        case .failure(let error):
            throw error
        }
    }
}
