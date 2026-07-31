import Foundation
import XCTest

@testable import SupraNetworking

/// Transport-level download contract: byte-progress forwarding, redirect policy
/// enforcement on the download path, the returned temporary file, and the
/// cancellation error shape. Served hermetically through a URLProtocol stub.
///
/// T-DL-01 is the gating test for restoring byte-progress reports. Expected RED
/// reason: the async `URLSession.download(for:delegate:)` convenience never
/// delivers `URLSessionDownloadDelegate.urlSession(_:downloadTask:didWriteData:...)`
/// to the per-task delegate (observed live and under URLProtocol on macOS 27
/// beta, 2026-07-24, while `task.countOfBytesReceived` kept growing), so the
/// transport never invokes `onBytes` and the collected reports stay empty —
/// `XCTAssertFalse(reports.isEmpty)` fails. The download UI symptom is this
/// exact hole: percent frozen and MB/s decaying to 0 while multi-gigabyte
/// weights transfer normally.
final class PolicyTransportDownloadTests: XCTestCase {
    private static let bodySize = 8_000_000
    private static let bodyByte: UInt8 = 0xA7

    override func tearDown() {
        StubRoutes.reset()
        super.tearDown()
    }

    private func makeTransport() -> PolicyEnforcingURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubProtocol.self]
        return PolicyEnforcingURLSessionTransport(session: URLSession(configuration: configuration))
    }

    private func directPolicy(for url: URL) throws -> RedirectPolicy {
        try RedirectPolicy(initialURL: url, service: "synthetic-service")
    }

    /// Origin serving an 8 MB body directly (no redirect).
    private static let directURL = URL(string: "https://origin.example/large.bin")!
    /// Origin issuing a 302 to the allowed CDN origin.
    private static let redirectingURL = URL(string: "https://origin.example/redirected.bin")!
    private static let allowedCDNURL = URL(string: "https://cdn.example/large.bin")!
    private static let disallowedCDNURL = URL(string: "https://evil.example/large.bin")!
    /// Origin serving one small chunk and then stalling until cancellation.
    private static let stallingURL = URL(string: "https://origin.example/stalling.bin")!

    // MARK: - T-DL-01 (gating)

    /// GATE: `download(for:policy:onBytes:)` must forward cumulative byte
    /// reports while the body streams. Expected RED: onBytes is never called
    /// (async-convenience delegate hole described in the header), so `reports`
    /// is empty.
    func testDownloadForwardsByteProgressReports() async throws {
        StubRoutes.set(route: .body(size: Self.bodySize, byte: Self.bodyByte), for: Self.directURL)
        let transport = makeTransport()
        let collector = ByteReportCollector()

        let result = try await transport.download(
            for: URLRequest(url: Self.directURL),
            policy: directPolicy(for: Self.directURL),
            onBytes: { collector.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

        let reports = collector.snapshot()
        // Outer proof the closure fired at all (§3.3): everything below is
        // vacuous if no report ever arrived.
        XCTAssertFalse(
            reports.isEmpty,
            "transport forwarded no byte reports for an \(Self.bodySize)-byte download"
        )
        // Reports are cumulative bytes for this transfer: positive, never above
        // the body size, and the transport's 2 MB forwarding stride means the
        // first forwarded report is at least 2 MB.
        for bytes in reports {
            XCTAssertGreaterThan(bytes, 0)
            XCTAssertLessThanOrEqual(bytes, Int64(Self.bodySize))
        }
        let maximum = try XCTUnwrap(reports.max())
        XCTAssertGreaterThanOrEqual(maximum, 2_000_000)
        // Cumulative reports never regress in arrival order on a single transfer.
        XCTAssertEqual(reports, reports.sorted())
    }

    // MARK: - T-DL-02 (standing guard)

    /// Standing guard (green before and after the transport rewrite this file
    /// gates): the caller-visible contract is a readable temporary file holding
    /// exactly the transferred body. The rewrite moves temp-file handling from
    /// the async convenience into our own delegate, and this test pins that the
    /// handoff neither truncates nor loses the file.
    func testDownloadReturnsTemporaryFileWithFullBody() async throws {
        StubRoutes.set(route: .body(size: Self.bodySize, byte: Self.bodyByte), for: Self.directURL)
        let transport = makeTransport()

        let result = try await transport.download(
            for: URLRequest(url: Self.directURL),
            policy: directPolicy(for: Self.directURL)
        )
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

        let http = try XCTUnwrap(result.response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(result.redirects.isEmpty)

        let data = try Data(contentsOf: result.temporaryURL)
        XCTAssertEqual(data.count, Self.bodySize)
        XCTAssertEqual(data.first, Self.bodyByte)
        XCTAssertEqual(data.last, Self.bodyByte)
        XCTAssertTrue(data.allSatisfy { $0 == Self.bodyByte })
    }

    // MARK: - T-DL-03 (standing guard)

    /// GATE: a redirect hop to an origin the policy does not list must surface
    /// as `NetworkPolicyError.redirectRejected` from the download path. This is
    /// the app's fail-closed network posture. Expected RED reason (observed
    /// 2026-07-24): the async `download(for:delegate:)` convenience CRASHES the
    /// process (EXC_BREAKPOINT inside Foundation's completion closure) when the
    /// per-task delegate rejects the redirect via `completionHandler(nil)` —
    /// the wrapper cannot represent a download that finished with neither a
    /// file nor an error.
    func testDownloadRejectsDisallowedRedirectHop() async throws {
        StubRoutes.set(route: .redirect(to: Self.disallowedCDNURL), for: Self.redirectingURL)
        StubRoutes.set(route: .body(size: 64, byte: Self.bodyByte), for: Self.disallowedCDNURL)
        let transport = makeTransport()

        do {
            let result = try await transport.download(
                for: URLRequest(url: Self.redirectingURL),
                policy: directPolicy(for: Self.redirectingURL)
            )
            try? FileManager.default.removeItem(at: result.temporaryURL)
            XCTFail("download followed a redirect to an origin outside the policy")
        } catch let NetworkPolicyError.redirectRejected(rejection) {
            // The destination origin is absent from the policy's allowlist, so
            // the origin gate rejects it before cross-origin route matching.
            XCTAssertEqual(rejection.reason, .originNotAllowed)
            XCTAssertEqual(rejection.hopCount, 1)
        }
        // The disallowed origin must never have been contacted.
        XCTAssertEqual(StubRoutes.requestCount(for: Self.disallowedCDNURL), 0)
    }

    // MARK: - T-DL-04 (standing guard)

    /// Standing guard: an allowed cross-origin hop is followed, audited, and
    /// the body from the destination origin lands in the temporary file.
    func testDownloadFollowsAllowedRedirectAndRecordsHop() async throws {
        StubRoutes.set(route: .redirect(to: Self.allowedCDNURL), for: Self.redirectingURL)
        StubRoutes.set(route: .body(size: Self.bodySize, byte: Self.bodyByte), for: Self.allowedCDNURL)
        let transport = makeTransport()
        let policy = try RedirectPolicy(
            initialURL: Self.redirectingURL,
            service: "synthetic-service",
            credentialOwner: nil,
            additionalOrigins: [
                RedirectPolicy.AllowedOrigin(
                    url: Self.allowedCDNURL,
                    service: "synthetic-download",
                    credentialOwner: nil
                )
            ],
            crossOriginRules: [
                RedirectPolicy.CrossOriginRule(
                    from: Self.redirectingURL,
                    to: Self.allowedCDNURL,
                    service: "synthetic-download"
                )
            ]
        )

        let result = try await transport.download(
            for: URLRequest(url: Self.redirectingURL),
            policy: policy
        )
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

        XCTAssertEqual(result.redirects.count, 1)
        let hop = try XCTUnwrap(result.redirects.first)
        XCTAssertEqual(hop.sourceURL.host, "origin.example")
        XCTAssertEqual(hop.destinationURL.host, "cdn.example")
        XCTAssertEqual(hop.statusCode, 302)

        let data = try Data(contentsOf: result.temporaryURL)
        XCTAssertEqual(data.count, Self.bodySize)
    }

    // MARK: - T-DL-05 (standing guard)

    /// Standing guard: cancelling the surrounding task surfaces as
    /// `CancellationError`/`URLError.cancelled`. `ModelDownloadController`
    /// maps exactly those to a clean `.idle`; any other error shape would
    /// misreport a user cancel as a failure.
    func testDownloadCancellationSurfacesAsCancellation() async throws {
        StubRoutes.set(route: .stall(prefixSize: 500_000, byte: Self.bodyByte), for: Self.stallingURL)
        let transport = makeTransport()
        let policy = try directPolicy(for: Self.stallingURL)

        // Explicitly typed @Sendable operation: the beta compiler's region
        // checker cannot analyze an inline `Task {}` closure here and fails
        // the build with "pattern that the region-based isolation checker
        // does not understand".
        let operation: @Sendable () async throws -> PolicyHTTPDownload = {
            try await transport.download(
                for: URLRequest(url: Self.stallingURL),
                policy: policy
            )
        }
        let downloadTask = Task(operation: operation)
        // Deterministic ordering: the stub signals after serving its prefix,
        // so cancellation always lands mid-transfer, never before start.
        await StubRoutes.stallReached()
        downloadTask.cancel()

        do {
            let result = try await downloadTask.value
            try? FileManager.default.removeItem(at: result.temporaryURL)
            XCTFail("cancelled download returned a result")
        } catch is CancellationError {
            // Accepted cancellation shape.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }
}

// MARK: - Collector

/// Thread-safe accumulator for onBytes reports (delivered on URLSession's
/// delegate queue).
private final class ByteReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Int64] = []

    func append(_ bytes: Int64) {
        lock.lock()
        reports.append(bytes)
        lock.unlock()
    }

    func snapshot() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}

// MARK: - URLProtocol stub

private enum StubRoute {
    case body(size: Int, byte: UInt8)
    case redirect(to: URL)
    case stall(prefixSize: Int, byte: UInt8)
}

/// Static route table keyed by absolute URL, plus a request counter and a
/// stall-started signal for deterministic cancellation ordering.
private enum StubRoutes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [URL: StubRoute] = [:]
    nonisolated(unsafe) private static var requestCounts: [URL: Int] = [:]
    nonisolated(unsafe) private static var stallContinuations: [CheckedContinuation<Void, Never>] = []
    nonisolated(unsafe) private static var stallCount = 0

    static func set(route: StubRoute, for url: URL) {
        lock.lock()
        routes[url] = route
        lock.unlock()
    }

    static func route(for url: URL) -> StubRoute? {
        lock.lock()
        defer { lock.unlock() }
        requestCounts[url, default: 0] += 1
        return routes[url]
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[url] ?? 0
    }

    static func markStallReached() {
        lock.lock()
        stallCount += 1
        let waiters = stallContinuations
        stallContinuations = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until a stall route has served its prefix at least once.
    static func stallReached() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stallCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                stallContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    static func reset() {
        lock.lock()
        routes = [:]
        requestCounts = [:]
        let waiters = stallContinuations
        stallContinuations = []
        stallCount = 0
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

private final class DownloadStubProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = StubRoutes.route(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch route {
        case let .body(size, byte):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(size)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var remaining = size
            let chunk = Data(repeating: byte, count: min(500_000, size))
            while remaining > 0 {
                let slice = remaining >= chunk.count ? chunk : Data(repeating: byte, count: remaining)
                client?.urlProtocol(self, didLoad: slice)
                remaining -= slice.count
            }
            client?.urlProtocolDidFinishLoading(self)

        case let .redirect(to: destination):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destination),
                redirectResponse: response
            )
            // If the delegate rejects the hop, the session finalizes the task
            // with this response; if it approves, a fresh protocol instance
            // loads the destination and this finish is ignored.
            client?.urlProtocolDidFinishLoading(self)

        case let .stall(prefixSize, byte):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(prefixSize * 4)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: byte, count: prefixSize))
            // Never finishes; the session tears the load down on cancel via
            // stopLoading. Signal so the test can cancel deterministically.
            StubRoutes.markStallReached()
        }
    }

    override func stopLoading() {}
}
