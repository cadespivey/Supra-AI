import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class SettingsControllerTests: XCTestCase {

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

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
