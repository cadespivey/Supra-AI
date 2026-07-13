import Foundation
import Network
import SupraNetworking
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
