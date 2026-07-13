import Foundation
import SupraStore
@testable import SupraNetworking
import XCTest

final class QueryFingerprinterTests: XCTestCase {
    func testACRFP001SameInstallKeyIsStableAndDifferentInstallKeysDoNotCorrelate() throws {
        let first = try HMACQueryFingerprinter(key: Data(repeating: 0x11, count: 32))
        let same = try HMACQueryFingerprinter(key: Data(repeating: 0x11, count: 32))
        let other = try HMACQueryFingerprinter(key: Data(repeating: 0x22, count: 32))

        let value = "noncompete-remedy"
        XCTAssertEqual(first.marker(for: value), same.marker(for: value))
        XCTAssertNotEqual(first.marker(for: value), other.marker(for: value))
        XCTAssertTrue(try XCTUnwrap(first.marker(for: value)).hasPrefix("#h1:"))
    }

    func testACRFP002CommonDictionaryValueNeverEqualsLegacyUnkeyedFNV() throws {
        let fingerprinter = try HMACQueryFingerprinter(key: Data(repeating: 0x33, count: 32))
        let value = "smith"
        XCTAssertNotEqual(fingerprinter.marker(for: value), "#\(legacyFNV(value))")
    }

    func testACRFP003SensitiveNamesStayRedactedAndNeverReachFingerprinter() throws {
        let spy = FingerprinterSpy(marker: "#h1:should-not-be-used")
        let query = AuthorizedHTTPClient.sanitizedQuery(
            "token=secret&client_secret=other&q=ordinary",
            redactsValues: true,
            fingerprinter: spy
        )

        XCTAssertTrue(query.contains("token=#redacted"))
        XCTAssertTrue(query.contains("client_secret=#redacted"))
        XCTAssertTrue(query.contains("q=#h1:should-not-be-used"))
        XCTAssertEqual(spy.values, ["ordinary"])
    }

    func testACRFP004KeychainFailureFallsBackToFullRedactionNotUnkeyedHash() {
        let fingerprinter = KeychainBackedQueryFingerprinter(keyStore: FailingFingerprintKeyStore())
        let query = AuthorizedHTTPClient.sanitizedQuery(
            "q=trade%20secret&type=o",
            redactsValues: true,
            fingerprinter: fingerprinter
        )

        XCTAssertEqual(query, "q=#redacted&type=#redacted")
        XCTAssertFalse(query.contains(legacyFNV("trade%20secret")))
    }

    func testACRFP005PersistedAuditMetadataUsesVersionedKeyedMarkers() async throws {
        let store = try SupraStore.inMemory()
        let client = AuthorizedHTTPClient(
            keyStore: FingerprintAPIKeyStore(token: "secret-token"),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            queryFingerprinter: try HMACQueryFingerprinter(key: Data(repeating: 0x44, count: 32)),
            transport: { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )
        let url = try XCTUnwrap(
            URL(string: "https://www.courtlistener.com/api/rest/v4/search/?q=trade%20secret&type=o")
        )

        _ = try await client.send(URLRequest(url: url))

        let record = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).first)
        let metadata = try XCTUnwrap(record.requestMetadataJSON)
        XCTAssertTrue(metadata.contains("#h1:"))
        XCTAssertFalse(metadata.contains("trade"))
        XCTAssertFalse(metadata.contains("#\(legacyFNV("trade%20secret"))"))
    }

    func testACRFP006CleanupRemovesLegacyQueryMetadataWithoutExposingValues() throws {
        let store = try SupraStore.inMemory()
        _ = try store.networkRequests.createRequest(
            domain: "www.courtlistener.com",
            method: "GET",
            endpoint: "/api/rest/v4/search/",
            approved: true,
            requestMetadataJSON: #"{"query":"q=#deadbeef&type=#cafebabe","headers":{"Accept":"application/json"}}"#
        )
        _ = try store.networkRequests.createRequest(
            domain: "www.courtlistener.com",
            method: "GET",
            endpoint: "/malformed",
            approved: true,
            requestMetadataJSON: "legacy-q=#secret-canary"
        )

        XCTAssertEqual(try store.networkRequests.removeStoredQueryMetadata(), 2)

        let records = try store.networkRequests.fetchRecent(limit: 10)
        let structured = try XCTUnwrap(records.first { $0.endpoint.contains("search") })
        XCTAssertFalse(structured.requestMetadataJSON?.contains("query") ?? false)
        XCTAssertTrue(structured.requestMetadataJSON?.contains("Accept") ?? false)
        let malformed = try XCTUnwrap(records.first { $0.endpoint == "/malformed" })
        XCTAssertNil(malformed.requestMetadataJSON)
    }

    private func legacyFNV(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private final class FingerprinterSpy: QueryFingerprinting, @unchecked Sendable {
    private let markerValue: String?
    private let lock = NSLock()
    private var storedValues: [String] = []

    init(marker: String?) {
        self.markerValue = marker
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func marker(for value: String) -> String? {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
        return markerValue
    }
}

private struct FailingFingerprintKeyStore: QueryFingerprintKeyStore {
    func loadOrCreateKey() throws -> Data {
        throw FingerprintTestError.unavailable
    }
}

private enum FingerprintTestError: Error {
    case unavailable
}

private final class FingerprintAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let token: String?

    init(token: String?) {
        self.token = token
    }

    func saveCourtListenerToken(_: String) throws {}
    func loadCourtListenerToken() throws -> String? { token }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { token != nil }
}
