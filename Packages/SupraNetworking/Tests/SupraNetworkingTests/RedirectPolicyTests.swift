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
    func testCredentialHeadersRemainOnlyForExplicitSameOwnerRoute() throws {
        let first = try XCTUnwrap(URL(string: "https://api.example.test/start"))
        let sameOwner = try XCTUnwrap(URL(string: "https://api-alt.example.test/next"))
        let tokenFree = try XCTUnwrap(URL(string: "https://cdn.example.test/file"))
        let policy = try RedirectPolicy(
            initialURL: first,
            service: "synthetic-service",
            credentialOwner: "synthetic-token",
            additionalOrigins: [
                .init(url: sameOwner, service: "synthetic-service", credentialOwner: "synthetic-token"),
                .init(url: tokenFree, service: "synthetic-cdn", credentialOwner: nil)
            ],
            crossOriginRules: [
                .init(from: first, to: sameOwner, service: "synthetic-service", preservesCredentials: true),
                .init(from: first, to: tokenFree, service: "synthetic-cdn", preservesCredentials: false)
            ]
        )
        var original = URLRequest(url: first)
        original.setValue("Token secret-canary", forHTTPHeaderField: "Authorization")
        original.setValue("key-canary", forHTTPHeaderField: "X-Api-Key")
        original.setValue("session-canary", forHTTPHeaderField: "Cookie")

        let credentialed = try policy.requestForRedirect(
            from: original,
            response: redirectResponse(from: first, to: sameOwner, statusCode: 307),
            proposedRequest: URLRequest(url: sameOwner),
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

    var requestCount: Int {
        stateQueue.sync { storedRequestCount }
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

            stateQueue.sync { storedRequestCount += 1 }
            let request = String(data: requestData, encoding: .utf8) ?? ""
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
