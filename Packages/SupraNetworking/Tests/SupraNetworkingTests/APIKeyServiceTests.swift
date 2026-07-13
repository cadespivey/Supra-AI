import Foundation
import SupraStore
@testable import SupraNetworking
import XCTest

final class APIKeyServiceTests: XCTestCase {

    func testACRKEY001ProductionCompositionIgnoresEnvironmentSecrets() throws {
        let variable = "SUPRA_OPENSTATES_API_KEY"
        let original = ProcessInfo.processInfo.environment[variable]
        setenv(variable, "must-not-be-loaded", 1)
        defer {
            if let original {
                setenv(variable, original, 1)
            } else {
                unsetenv(variable)
            }
        }

        let store = APIKeyStoreComposition.production(primary: MultiKeyStore())

        XCTAssertNil(try store.loadAPIKey(for: .openStates))
        XCTAssertFalse(try store.hasAPIKey(for: .openStates))
    }

    func testACRKEY002DebugCompositionRequiresExplicitEnvironmentInjection() throws {
        let store = APIKeyStoreComposition.development(
            primary: MultiKeyStore(),
            environment: ["SUPRA_GOVINFO_API_KEY": "debug-only-key"]
        )

        XCTAssertEqual(try store.loadAPIKey(for: .govInfo), "debug-only-key")
    }

    func testServicesHaveDistinctAccountsAndEnvVars() {
        XCTAssertNotEqual(APIKeyService.openStates.keychainAccount, APIKeyService.govInfo.keychainAccount)
        XCTAssertEqual(APIKeyService.govInfo.environmentVariable, "SUPRA_GOVINFO_API_KEY")
        XCTAssertEqual(APIKeyService.regulationsGov.keychainAccount, "supra.apikey.regulationsGov")
    }

    func testEnvironmentBackedStoreReturnsEnvKeyAndReportsEnvSource() throws {
        let store = EnvironmentBackedTokenStore(
            primary: MultiKeyStore(),
            environment: ["SUPRA_OPENSTATES_API_KEY": "env-key"]
        )
        XCTAssertEqual(try store.loadAPIKey(for: .openStates), "env-key")
        XCTAssertTrue(try store.hasAPIKey(for: .openStates))
        XCTAssertTrue(store.hasEnvironmentAPIKey(for: .openStates))
        XCTAssertFalse(store.hasEnvironmentAPIKey(for: .regulationsGov))
    }

    func testEnvironmentBackedStorePrefersEnvKeyOverPrimaryKey() throws {
        let primary = MultiKeyStore()
        try primary.saveAPIKey("stored-key", for: .govInfo)
        let store = EnvironmentBackedTokenStore(
            primary: primary,
            environment: ["SUPRA_GOVINFO_API_KEY": "env-key"]
        )

        XCTAssertEqual(try store.loadAPIKey(for: .govInfo), "env-key")
        XCTAssertTrue(store.hasEnvironmentAPIKey(for: .govInfo))
    }

    func testEnvironmentBackedStoreDelegatesToPrimaryWhenNoEnvKey() throws {
        let store = EnvironmentBackedTokenStore(primary: MultiKeyStore(), environment: [:])
        XCTAssertNil(try store.loadAPIKey(for: .govInfo))
        try store.saveAPIKey("kc-key", for: .govInfo)
        XCTAssertEqual(try store.loadAPIKey(for: .govInfo), "kc-key")
        XCTAssertTrue(try store.hasAPIKey(for: .govInfo))
        try store.deleteAPIKey(for: .govInfo)
        XCTAssertFalse(try store.hasAPIKey(for: .govInfo))
    }

    func testKeysAreIsolatedPerService() throws {
        let store = MultiKeyStore()
        try store.saveAPIKey("a", for: .openStates)
        try store.saveAPIKey("b", for: .govInfo)
        XCTAssertEqual(try store.loadAPIKey(for: .openStates), "a")
        XCTAssertEqual(try store.loadAPIKey(for: .govInfo), "b")
        XCTAssertNil(try store.loadAPIKey(for: .regulationsGov))
    }

    func testACRKEY003MissingCourtListenerKeyIsTypedAndNeverReachesTransport() async throws {
        let store = try SupraStore.inMemory()
        let transport = TransportCallSpy()
        let client = AuthorizedHTTPClient(
            keyStore: MultiKeyStore(),
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            transport: { request in
                transport.recordCall()
                return (
                    Data(),
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://www.courtlistener.com/api/rest/v4/search/"))
        )

        do {
            _ = try await client.send(request)
            XCTFail("Expected a typed setup error")
        } catch {
            XCTAssertEqual(error as? AuthorizedHTTPClientError, .missingToken)
        }
        XCTAssertFalse(transport.wasCalled)
    }
}

private final class TransportCallSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    func recordCall() {
        lock.lock()
        called = true
        lock.unlock()
    }
}

/// An in-memory `APIKeyStoreProtocol` implementing the generic keyed API (a reference type so
/// saves persist across calls).
final class MultiKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var courtListener: String?
    private var keys: [APIKeyService: String] = [:]

    func saveCourtListenerToken(_ token: String) throws { courtListener = token }
    func loadCourtListenerToken() throws -> String? { courtListener }
    func deleteCourtListenerToken() throws { courtListener = nil }
    func hasCourtListenerToken() throws -> Bool { courtListener != nil }

    func saveAPIKey(_ key: String, for service: APIKeyService) throws { keys[service] = key }
    func loadAPIKey(for service: APIKeyService) throws -> String? { keys[service] }
    func deleteAPIKey(for service: APIKeyService) throws { keys[service] = nil }
    func hasAPIKey(for service: APIKeyService) throws -> Bool { keys[service] != nil }
}
