import Foundation
@testable import SupraNetworking
import XCTest

final class APIKeyServiceTests: XCTestCase {

    func testServicesHaveDistinctAccountsAndEnvVars() {
        XCTAssertNotEqual(APIKeyService.openStates.keychainAccount, APIKeyService.legiScan.keychainAccount)
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
        XCTAssertFalse(store.hasEnvironmentAPIKey(for: .legiScan))
    }

    func testEnvironmentBackedStoreDelegatesToPrimaryWhenNoEnvKey() throws {
        let store = EnvironmentBackedTokenStore(primary: MultiKeyStore(), environment: [:])
        XCTAssertNil(try store.loadAPIKey(for: .legiScan))
        try store.saveAPIKey("kc-key", for: .legiScan)
        XCTAssertEqual(try store.loadAPIKey(for: .legiScan), "kc-key")
        XCTAssertTrue(try store.hasAPIKey(for: .legiScan))
        try store.deleteAPIKey(for: .legiScan)
        XCTAssertFalse(try store.hasAPIKey(for: .legiScan))
    }

    func testKeysAreIsolatedPerService() throws {
        let store = MultiKeyStore()
        try store.saveAPIKey("a", for: .openStates)
        try store.saveAPIKey("b", for: .legiScan)
        XCTAssertEqual(try store.loadAPIKey(for: .openStates), "a")
        XCTAssertEqual(try store.loadAPIKey(for: .legiScan), "b")
        XCTAssertNil(try store.loadAPIKey(for: .regulationsGov))
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
