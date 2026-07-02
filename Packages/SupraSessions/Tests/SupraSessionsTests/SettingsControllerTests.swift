import Foundation
import SupraCore
import SupraNetworking
@testable import SupraSessions
import SupraStore
import XCTest

private struct SettingsTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    var token: String?
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { token }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { token != nil }
}

private struct LoadFailingTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? {
        XCTFail("Environment token state should not load the primary token")
        return nil
    }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool {
        XCTFail("Environment token state should not query the primary token")
        return false
    }
}

private final class MultiKeySettingsStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var keys: [APIKeyService: String] = [:]
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }
    func saveAPIKey(_ key: String, for service: APIKeyService) throws { keys[service] = key }
    func loadAPIKey(for service: APIKeyService) throws -> String? { keys[service] }
    func deleteAPIKey(for service: APIKeyService) throws { keys[service] = nil }
    func hasAPIKey(for service: APIKeyService) throws -> Bool { keys[service] != nil }
}

@MainActor
final class SettingsControllerTests: XCTestCase {

    func testSaveAndClearAPIKeyUpdatesConfiguredState() throws {
        let store = try makeStore()
        let settings = SettingsController(store: store, tokenStore: MultiKeySettingsStore())
        XCTAssertFalse(settings.hasAPIKey(.openStates))

        settings.saveAPIKey("os-key", for: .openStates)
        XCTAssertTrue(settings.hasAPIKey(.openStates))
        XCTAssertTrue(settings.configuredAPIKeys.contains(.openStates))
        XCTAssertFalse(settings.hasAPIKey(.regulationsGov))

        settings.clearAPIKey(for: .openStates)
        XCTAssertFalse(settings.hasAPIKey(.openStates))
    }

    func testEnvironmentAPIKeyIsReportedReadOnly() throws {
        let store = try makeStore()
        let envStore = EnvironmentBackedTokenStore(
            primary: MultiKeySettingsStore(),
            environment: ["SUPRA_GOVINFO_API_KEY": "env"]
        )
        let settings = SettingsController(store: store, tokenStore: envStore)
        XCTAssertTrue(settings.hasAPIKey(.govInfo))
        XCTAssertTrue(settings.isEnvironmentAPIKey(.govInfo))
    }

    func testSelectingPresetSnapsSamplingParametersAndPersists() throws {
        let store = try makeStore()
        let settings = SettingsController(store: store)

        settings.preset = .drafting

        let expected = GenerationPreset.drafting.samplingParameters
        XCTAssertEqual(settings.temperature, expected.temperature, accuracy: 0.0001)
        XCTAssertEqual(settings.currentOptions.topP, expected.topP, accuracy: 0.0001)

        // Persisted under the shared key so the chat flow and next launch use it.
        let stored = try store.appSettings.getSetting(
            SettingsController.generationDefaultsKey,
            as: GenerationOptions.self
        )
        XCTAssertEqual(stored?.preset, .drafting)
        XCTAssertEqual(stored?.temperature ?? -1, expected.temperature, accuracy: 0.0001)
        XCTAssertEqual(stored?.topP ?? -1, expected.topP, accuracy: 0.0001)
    }

    func testManualTemperatureIsPreservedAcrossReload() throws {
        let store = try makeStore()
        let settings = SettingsController(store: store)

        settings.preset = .drafting   // snaps temperature to 0.7
        settings.temperature = 0.33   // user override afterwards

        // A fresh controller (app relaunch) must keep the custom temperature,
        // not re-snap it to the preset's value.
        let reloaded = SettingsController(store: store)
        XCTAssertEqual(reloaded.preset, .drafting)
        XCTAssertEqual(reloaded.temperature, 0.33, accuracy: 0.0001)
    }

    func testCourtListenerTokenSourceDistinguishesEnvironment() throws {
        let store = try makeStore()
        let envStore = EnvironmentBackedTokenStore(
            primary: LoadFailingTokenStore(),
            environment: ["SUPRA_COURTLISTENER_API_KEY": "env-token"]
        )
        let settings = SettingsController(store: store, tokenStore: envStore)

        XCTAssertTrue(settings.hasCourtListenerToken)
        XCTAssertEqual(settings.courtListenerTokenSource, .environment)
    }

    func testCourtListenerTokenSourceFallsBackToKeychainStore() throws {
        let store = try makeStore()
        let settings = SettingsController(store: store, tokenStore: SettingsTokenStore(token: "stored-token"))

        XCTAssertTrue(settings.hasCourtListenerToken)
        XCTAssertEqual(settings.courtListenerTokenSource, .keychain)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
