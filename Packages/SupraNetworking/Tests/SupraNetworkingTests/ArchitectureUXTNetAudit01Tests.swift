import Foundation
import SupraCore
@testable import SupraNetworking
import XCTest

/// T-NET-AUDIT-01 proves that the HTTP boundary owns transport policy while a
/// narrow Core capability owns audit persistence. The Networking package must
/// not regain a Store dependency to satisfy these behavioral checks.
final class ArchitectureUXTNetAudit01Tests: XCTestCase {
    private let recordID = "record-713"
    private let wireID = "T_NET_AUDIT_01_WIRE_731"
    private let queryCanary = "QUERY-CANARY-719"

    func testPackageAndLoggerHaveNoStoreDependency() throws {
        // Expected RED: Package.swift and NetworkRequestLogger currently import
        // and name SupraStore/NetworkRequestRepository directly.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let loggerSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/SupraNetworking/NetworkRequestLogger.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(manifest.contains("../SupraStore"))
        XCTAssertFalse(manifest.contains("package: \"SupraStore\""))
        XCTAssertFalse(loggerSource.contains("import SupraStore"))
        XCTAssertFalse(loggerSource.contains("NetworkRequestRepository"))
        XCTAssertTrue(loggerSource.contains("NetworkRequestAuditWriting"))
    }

    func testAuditFailureBeforeSendProducesZeroTransportAndNoPartialAudit() async throws {
        // Expected RED: NetworkRequestLogger accepts only a Store repository, so
        // the narrow injected writer and exact request identity do not exist.
        let auditWriter = NetworkAuditWriterSpy(recordFailure: .recordRejected)
        let transport = NetworkTransportSpy()
        let client = makeClient(auditWriter: auditWriter, transport: transport)
        let request = try makeRequest()

        do {
            _ = try await client.sendUnauthenticated(request, relatedResearchSessionID: nil)
            XCTFail("the request must not reach transport when its pre-send audit cannot be recorded")
        } catch let error as NetworkAuditWriterSpy.Failure {
            XCTAssertEqual(error, .recordRejected)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(auditWriter.entries, [])
        XCTAssertEqual(auditWriter.completions, [])
    }

    func testSuccessfulResponseSurvivesTerminalAuditFailureWithExactContentMinimizedEntry() async throws {
        // Expected RED: the current Store-coupled logger cannot expose an exact,
        // content-minimized Core audit entry through a test-owned capability.
        let auditWriter = NetworkAuditWriterSpy(completionFailure: .completionRejected)
        let transport = NetworkTransportSpy()
        let client = makeClient(auditWriter: auditWriter, transport: transport)
        let request = try makeRequest()

        let (data, response) = try await client.sendUnauthenticated(
            request,
            relatedResearchSessionID: nil
        )

        XCTAssertEqual(response.statusCode, 207)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), wireID)
        let capturedRequest = await transport.lastRequest
        let sentRequest = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(sentRequest.url?.host, "provider-713.example")
        XCTAssertEqual(sentRequest.url?.query, "q=QUERY-CANARY-719&version=7")
        XCTAssertEqual(sentRequest.httpBody, Data(wireID.utf8))
        XCTAssertFalse(String(decoding: sentRequest.httpBody ?? Data(), as: UTF8.self).contains("DEFAULT-BODY-000"))

        let entry = try XCTUnwrap(auditWriter.entries.single)
        XCTAssertEqual(entry.id, recordID)
        XCTAssertEqual(entry.timestamp, Date(timeIntervalSince1970: 731))
        XCTAssertEqual(entry.domain, "provider-713.example")
        XCTAssertEqual(entry.method, "POST")
        XCTAssertEqual(entry.endpoint, "/v7/search")
        XCTAssertTrue(entry.approved)
        XCTAssertNil(entry.relatedResearchSessionID)
        XCTAssertNil(entry.blockedReason)

        let metadata = try XCTUnwrap(entry.requestMetadataJSON)
        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
        )
        XCTAssertEqual(metadataObject["query"] as? String, "q=#wire:719&version=#wire:7")
        let headers = try XCTUnwrap(metadataObject["headers"] as? [String: String])
        XCTAssertEqual(headers, [
            "X-API-Key": "#redacted",
            "X-Supra-Grant-Version": "7",
        ])
        XCTAssertFalse(metadata.contains(queryCanary))
        XCTAssertFalse(metadata.contains(wireID))
        XCTAssertFalse(metadata.contains("DEFAULT-BODY-000"))
        XCTAssertFalse(metadata.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(metadata.contains("provider-token-713"))

        XCTAssertEqual(auditWriter.completions.count, 0)
        XCTAssertEqual(auditWriter.completionAttempts.map(\.requestID), [recordID])
        XCTAssertEqual(auditWriter.completionAttempts.map(\.statusCode), [207])
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    private func makeClient(
        auditWriter: NetworkAuditWriterSpy,
        transport: NetworkTransportSpy
    ) -> AuthorizedHTTPClient {
        let logger = NetworkRequestLogger(
            writer: auditWriter,
            requestID: { "record-713" },
            now: { Date(timeIntervalSince1970: 731) }
        )
        return AuthorizedHTTPClient(
            keyStore: NetworkAuditKeyStore(),
            policy: NetworkPolicyService(allowedHosts: ["provider-713.example"]),
            logger: logger,
            rateLimitTracker: RateLimitTracker(),
            queryFingerprinter: NetworkAuditFingerprinter(),
            transport: { request in
                try await transport.respond(to: request)
            }
        )
    }

    private func makeRequest() throws -> URLRequest {
        let url = try XCTUnwrap(
            URL(string: "https://provider-713.example/v7/search?q=QUERY-CANARY-719&version=7")
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(wireID.utf8)
        request.setValue("7", forHTTPHeaderField: "X-Supra-Grant-Version")
        request.setValue("provider-token-713", forHTTPHeaderField: "X-API-Key")
        return request
    }
}

private final class NetworkAuditWriterSpy: NetworkRequestAuditWriting, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case recordRejected
        case completionRejected
    }

    private let lock = NSLock()
    private let recordFailure: Failure?
    private let completionFailure: Failure?
    private var storedEntries: [NetworkRequestAuditEntry] = []
    private var storedCompletionAttempts: [NetworkRequestAuditCompletion] = []
    private var storedCompletions: [NetworkRequestAuditCompletion] = []

    init(recordFailure: Failure? = nil, completionFailure: Failure? = nil) {
        self.recordFailure = recordFailure
        self.completionFailure = completionFailure
    }

    var entries: [NetworkRequestAuditEntry] {
        lock.withLock { storedEntries }
    }

    var completionAttempts: [NetworkRequestAuditCompletion] {
        lock.withLock { storedCompletionAttempts }
    }

    var completions: [NetworkRequestAuditCompletion] {
        lock.withLock { storedCompletions }
    }

    @discardableResult
    func recordRequest(_ entry: NetworkRequestAuditEntry) throws -> String {
        if let recordFailure {
            throw recordFailure
        }
        lock.withLock {
            storedEntries.append(entry)
        }
        return entry.id
    }

    func finishRequest(_ completion: NetworkRequestAuditCompletion) throws {
        lock.withLock {
            storedCompletionAttempts.append(completion)
        }
        if let completionFailure {
            throw completionFailure
        }
        lock.withLock {
            storedCompletions.append(completion)
        }
    }
}

private actor NetworkTransportSpy {
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        lastRequest = request
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 207,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data("T_NET_AUDIT_01_WIRE_731".utf8), response)
    }
}

private struct NetworkAuditFingerprinter: QueryFingerprinting {
    func marker(for value: String) -> String? {
        switch value {
        case "QUERY-CANARY-719": "#wire:719"
        case "7": "#wire:7"
        default: nil
        }
    }
}

private struct NetworkAuditKeyStore: APIKeyStoreProtocol {
    func saveCourtListenerToken(_: String) throws {}
    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
