import Foundation
import Network
@testable import SupraNetworking
import SupraStore
import XCTest

final class RedirectPolicyTests: XCTestCase {
    /// ACR-NET-01. Expected RED: `URLSession.shared` follows the redirect and the
    /// second loopback server receives one request instead of zero.
    func testAuthorizedClientRejectsRedirectToDifferentOriginBeforeSecondRequest() async throws {
        let secondServer = try LoopbackHTTPServer { _ in
            .ok(body: "unsafe second origin")
        }
        try await secondServer.start()

        let secondURL = try XCTUnwrap(secondServer.url(path: "/private?q=client-canary"))
        let firstServer = try LoopbackHTTPServer { _ in
            .redirect(to: secondURL)
        }
        try await firstServer.start()

        let store = try makeStore()
        let client = AuthorizedHTTPClient(
            keyStore: EmptyKeyStore(),
            policy: LoopbackInitialPolicy(),
            logger: NetworkRequestLogger(repository: store.networkRequests)
        )
        let initialURL = try XCTUnwrap(firstServer.url(path: "/start?q=initial-canary"))

        do {
            _ = try await client.sendUnauthenticated(URLRequest(url: initialURL))
            XCTFail("ACR-NET-01: a redirect to a different origin must throw a typed policy error")
        } catch {
            XCTAssertTrue(error is NetworkPolicyError, "redirect rejection must be a typed NetworkPolicyError")
            XCTAssertTrue(
                String(describing: error).contains("redirectRejected"),
                "the typed error must identify redirect rejection"
            )
        }

        XCTAssertEqual(
            secondServer.requestCount,
            0,
            "the disallowed second origin must receive zero requests"
        )

        let records = try store.networkRequests.fetchRecent(limit: 10)
        let blocked = records.filter { !$0.approved }
        XCTAssertEqual(blocked.count, 1, "one rejected hop must produce one blocked audit row")
        XCTAssertEqual(blocked.first?.domain, "127.0.0.1")
        XCTAssertEqual(blocked.first?.endpoint, "/private")
        XCTAssertFalse(
            blocked.first?.requestMetadataJSON?.contains("client-canary") ?? false,
            "blocked-hop audit metadata must redact query values"
        )
        XCTAssertFalse(
            records.contains { $0.approved && $0.statusCode == 200 },
            "a rejected redirect must not create a successful completion row"
        )
    }

    /// ACR-NET-01 status matrix. Expected RED at the test-only commit: the new policy type is
    /// absent; on the original runtime path, Foundation follows each redirect to server two.
    func testAllRedirectStatusVariantsRejectBeforeCrossOriginEgress() async throws {
        let statuses = [
            (301, "301 Moved Permanently"),
            (302, "302 Found"),
            (303, "303 See Other"),
            (307, "307 Temporary Redirect"),
            (308, "308 Permanent Redirect")
        ]

        for (code, status) in statuses {
            let secondServer = try LoopbackHTTPServer { _ in .ok(body: "must not arrive") }
            try await secondServer.start()
            let secondURL = try XCTUnwrap(secondServer.url(path: "/status-\(code)"))
            let firstServer = try LoopbackHTTPServer { _ in .redirect(to: secondURL, status: status) }
            try await firstServer.start()
            let initialURL = try XCTUnwrap(firstServer.url(path: "/start-\(code)"))
            let store = try makeStore()
            let client = AuthorizedHTTPClient(
                keyStore: EmptyKeyStore(),
                policy: LoopbackInitialPolicy(),
                logger: NetworkRequestLogger(repository: store.networkRequests)
            )

            do {
                _ = try await client.sendUnauthenticated(URLRequest(url: initialURL))
                XCTFail("ACR-NET-01: HTTP \(code) cross-origin redirect must be rejected")
            } catch NetworkPolicyError.redirectRejected {
                // Expected typed rejection.
            } catch {
                XCTFail("ACR-NET-01: HTTP \(code) returned wrong error type: \(error)")
            }
            XCTAssertEqual(
                secondServer.requestCount,
                0,
                "HTTP \(code) redirect destination must receive zero requests"
            )
        }
    }

    /// ACR-NET-04 real-session hop proof. Expected RED at the test-only commit: the new policy
    /// type is absent; on the original runtime path, Foundation continues beyond five hops.
    func testSixthSameOriginHopIsRejectedBeforeItsRequest() async throws {
        let address = LoopbackAddressBox()
        let server = try LoopbackHTTPServer { request in
            let requestLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/hop/0"
            let current = Int(path.split(separator: "/").last ?? "0") ?? 0
            return .redirect(to: address.url(path: "/hop/\(current + 1)"))
        }
        try await server.start()
        address.baseURL = try XCTUnwrap(server.url(path: ""))
        let initialURL = try XCTUnwrap(server.url(path: "/hop/0"))
        let store = try makeStore()
        let client = AuthorizedHTTPClient(
            keyStore: EmptyKeyStore(),
            policy: LoopbackInitialPolicy(),
            logger: NetworkRequestLogger(repository: store.networkRequests)
        )

        do {
            _ = try await client.sendUnauthenticated(URLRequest(url: initialURL))
            XCTFail("ACR-NET-04: sixth redirect must be rejected")
        } catch NetworkPolicyError.redirectRejected(let rejection) {
            XCTAssertEqual(rejection.reason, .hopLimitExceeded(maximum: 5))
            XCTAssertEqual(rejection.hopCount, 6)
        } catch {
            XCTFail("ACR-NET-04: wrong error type: \(error)")
        }

        XCTAssertEqual(server.requestCount, 6, "only the initial request and five allowed hops may arrive")
        XCTAssertFalse(
            server.receivedRequestLines.contains { $0.contains(" /hop/6 ") },
            "the sixth redirect destination must never be requested"
        )
    }

    /// ACR-NET-02. Expected RED: `RedirectPolicy` does not exist yet.
    func testRedirectPolicyRejectsDowngradeUserinfoAlternatePortAndUnnamedOrigin() throws {
        let initial = try XCTUnwrap(URL(string: "https://api.example.test/start"))
        let policy = try RedirectPolicy(initialURL: initial, service: "synthetic-service")

        let rejectedDestinations = [
            "http://api.example.test/downgrade",
            "https://user:password@api.example.test/embedded",
            "https://api.example.test:8443/alternate-port",
            "https://other.example.test/cross-origin"
        ]

        for destination in rejectedDestinations {
            let proposedURL = try XCTUnwrap(URL(string: destination))
            XCTAssertThrowsError(
                try policy.requestForRedirect(
                    from: URLRequest(url: initial),
                    response: redirectResponse(from: initial, to: proposedURL, statusCode: 302),
                    proposedRequest: URLRequest(url: proposedURL),
                    hopCount: 1
                ),
                "ACR-NET-02 must reject \(destination)"
            ) { error in
                XCTAssertTrue(error is NetworkPolicyError)
                XCTAssertTrue(String(describing: error).contains("redirectRejected"))
            }
        }
    }

    /// ACR-NET-03. Expected RED: no redirect layer scopes credential headers.
    func testCredentialHeadersRemainOnlyOnSameOriginAndStripFromCrossOriginRoutes() throws {
        let first = try XCTUnwrap(URL(string: "https://api.example.test/start"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://api.example.test/next"))
        let tokenFree = try XCTUnwrap(URL(string: "https://cdn.example.test/file"))
        let wrongOwner = try XCTUnwrap(URL(string: "https://other-api.example.test/next"))
        let policy = try RedirectPolicy(
            initialURL: first,
            service: "synthetic-service",
            credentialOwner: "synthetic-token",
            additionalOrigins: [
                .init(url: tokenFree, service: "synthetic-cdn", credentialOwner: nil),
                .init(url: wrongOwner, service: "other-service", credentialOwner: "other-token")
            ],
            crossOriginRules: [
                .init(from: first, to: tokenFree, service: "synthetic-cdn"),
                .init(from: first, to: wrongOwner, service: "other-service")
            ]
        )
        var original = URLRequest(url: first)
        original.setValue("Token secret-canary", forHTTPHeaderField: "Authorization")
        original.setValue("key-canary", forHTTPHeaderField: "X-Api-Key")
        original.setValue("session-canary", forHTTPHeaderField: "Cookie")

        let credentialed = try policy.requestForRedirect(
            from: original,
            response: redirectResponse(from: first, to: sameOrigin, statusCode: 307),
            proposedRequest: URLRequest(url: sameOrigin),
            hopCount: 1
        )
        XCTAssertEqual(credentialed.value(forHTTPHeaderField: "Authorization"), "Token secret-canary")
        XCTAssertEqual(credentialed.value(forHTTPHeaderField: "X-Api-Key"), "key-canary")
        XCTAssertEqual(credentialed.value(forHTTPHeaderField: "Cookie"), "session-canary")

        let stripped = try policy.requestForRedirect(
            from: original,
            response: redirectResponse(from: first, to: tokenFree, statusCode: 302),
            proposedRequest: URLRequest(url: tokenFree),
            hopCount: 1
        )
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Cookie"))

        let wrongScope = try policy.requestForRedirect(
            from: original,
            response: redirectResponse(from: first, to: wrongOwner, statusCode: 302),
            proposedRequest: URLRequest(url: wrongOwner),
            hopCount: 1
        )
        XCTAssertNil(wrongScope.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(wrongScope.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(wrongScope.value(forHTTPHeaderField: "Cookie"))
    }

    /// ACR-NET-03 contract guard: related CourtListener hostnames are still cross-origin.
    /// The approved compatibility route must be token-free.
    func testCourtListenerCrossOriginCompatibilityRouteStripsToken() throws {
        let first = try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/"))
        let destination = try XCTUnwrap(URL(string: "https://courtlistener.com/api/rest/v4/search/"))
        let policy = try NetworkPolicyService().redirectPolicy(
            for: first,
            credentialOwner: "courtlistener-api"
        )
        var current = URLRequest(url: first)
        current.setValue("Token secret-canary", forHTTPHeaderField: "Authorization")

        let redirected = try policy.requestForRedirect(
            from: current,
            response: redirectResponse(from: first, to: destination, statusCode: 308),
            proposedRequest: URLRequest(url: destination),
            hopCount: 1
        )

        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    }

    /// ACR-NET-04. Expected RED: no redirect layer imposes a five-hop ceiling.
    func testRedirectPolicyAcceptsRedirectStatusVariantsButRejectsSixthHop() throws {
        let initial = try XCTUnwrap(URL(string: "https://api.example.test/start"))
        let policy = try RedirectPolicy(initialURL: initial, service: "synthetic-service", maximumHops: 5)
        let statuses = [301, 302, 303, 307, 308]

        for (index, status) in statuses.enumerated() {
            let destination = try XCTUnwrap(URL(string: "https://api.example.test/hop-\(index + 1)"))
            let redirected = try policy.requestForRedirect(
                from: URLRequest(url: initial),
                response: redirectResponse(from: initial, to: destination, statusCode: status),
                proposedRequest: URLRequest(url: destination),
                hopCount: index + 1
            )
            XCTAssertEqual(redirected.url, destination)
        }

        let sixth = try XCTUnwrap(URL(string: "https://api.example.test/hop-6"))
        XCTAssertThrowsError(
            try policy.requestForRedirect(
                from: URLRequest(url: initial),
                response: redirectResponse(from: initial, to: sixth, statusCode: 302),
                proposedRequest: URLRequest(url: sixth),
                hopCount: 6
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("hopLimitExceeded"))
        }
    }

    /// ACR-NET-05 standing policy guard. Expected RED: Hugging Face has no explicit
    /// shared redirect policy and follows whatever redirects its raw session accepts.
    func testHuggingFacePolicyAllowsOnlyNamedTokenFreeDownloadOrigins() throws {
        let hub = try XCTUnwrap(URL(string: "https://huggingface.co/org/model/resolve/main/model.safetensors"))
        let allowedCDN = try XCTUnwrap(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/object?signed=canary"))
        let unknownCDN = try XCTUnwrap(URL(string: "https://unexpected.hf.co/object"))
        let policy = try RedirectPolicy.huggingFace(initialURL: hub)

        let allowed = try policy.requestForRedirect(
            from: URLRequest(url: hub),
            response: redirectResponse(from: hub, to: allowedCDN, statusCode: 302),
            proposedRequest: URLRequest(url: allowedCDN),
            hopCount: 1
        )
        XCTAssertEqual(allowed.url?.host, "us.aws.cdn.hf.co")
        XCTAssertNil(allowed.value(forHTTPHeaderField: "Authorization"))

        XCTAssertThrowsError(
            try policy.requestForRedirect(
                from: URLRequest(url: hub),
                response: redirectResponse(from: hub, to: unknownCDN, statusCode: 302),
                proposedRequest: URLRequest(url: unknownCDN),
                hopCount: 1
            )
        )
    }

    private func redirectResponse(from source: URL, to destination: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: source,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": destination.absoluteString]
        )!
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedirectPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private struct LoopbackInitialPolicy: NetworkPolicyServiceProtocol {
    func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    func validate(_ url: URL) throws {
        guard url.scheme == "http" else {
            throw NetworkPolicyError.insecureScheme(url.scheme)
        }
        guard url.host == "127.0.0.1" else {
            throw NetworkPolicyError.hostNotAllowed(url.host ?? "")
        }
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.user == nil else {
            throw NetworkPolicyError.embeddedCredentials
        }
    }
}

private final class EmptyKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    func saveCourtListenerToken(_: String) throws {}
    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        let status: String
        let headers: [String: String]
        let body: Data

        static func ok(body: String) -> Response {
            Response(status: "200 OK", headers: ["Content-Type": "text/plain"], body: Data(body.utf8))
        }

        static func redirect(to url: URL, status: String = "302 Found") -> Response {
            Response(status: status, headers: ["Location": url.absoluteString], body: Data())
        }
    }

    enum ServerError: Error {
        case missingPort
        case failed(String)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "RedirectPolicyTests.LoopbackHTTPServer")
    private let stateQueue = DispatchQueue(label: "RedirectPolicyTests.LoopbackHTTPServer.state")
    private let responder: @Sendable (String) -> Response
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var storedRequestCount = 0
    private var storedRequestLines: [String] = []

    var requestCount: Int {
        stateQueue.sync { storedRequestCount }
    }

    var receivedRequestLines: [String] {
        stateQueue.sync { storedRequestLines }
    }

    init(responder: @escaping @Sendable (String) -> Response) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.responder = responder
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync {
                startContinuation = continuation
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finishStart(with: .success(()))
                case let .failed(error):
                    self?.finishStart(with: .failure(ServerError.failed(error.localizedDescription)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func url(path: String) -> URL? {
        guard let port = listener.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
    }

    private func finishStart(with result: Result<Void, Error>) {
        let continuation = stateQueue.sync { () -> CheckedContinuation<Void, Error>? in
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = accumulated
            if let data { requestData.append(data) }
            if requestData.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete, error == nil {
                receiveRequest(on: connection, accumulated: requestData)
                return
            }

            let request = String(data: requestData, encoding: .utf8) ?? ""
            let requestLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            stateQueue.sync {
                storedRequestCount += 1
                storedRequestLines.append(requestLine)
            }
            let response = responder(request)
            var header = "HTTP/1.1 \(response.status)\r\n"
            for (name, value) in response.headers {
                header += "\(name): \(value)\r\n"
            }
            header += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            var bytes = Data(header.utf8)
            bytes.append(response.body)
            connection.send(content: bytes, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    deinit {
        listener.cancel()
    }
}

private final class LoopbackAddressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBaseURL: URL?

    var baseURL: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedBaseURL
        }
        set {
            lock.lock()
            storedBaseURL = newValue
            lock.unlock()
        }
    }

    func url(path: String) -> URL {
        lock.lock()
        defer { lock.unlock() }
        return storedBaseURL!.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
