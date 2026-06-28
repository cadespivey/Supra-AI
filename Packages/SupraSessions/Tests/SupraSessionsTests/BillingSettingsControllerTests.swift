import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingSettingsControllerTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BillingSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    func testDefaultsWhenNothingStored() throws {
        let controller = BillingSettingsController(store: try makeStore())
        // A fresh install seeds the starter billing-narrative hygiene instructions.
        XCTAssertEqual(controller.globalInstructions, BillingSettings.defaultGlobalInstructions)
        XCTAssertFalse(controller.globalInstructions.isEmpty)
        XCTAssertEqual(controller.narrativeTerminal, .asWritten)
        XCTAssertTrue(controller.autoTimestamp)
        XCTAssertTrue(controller.utbmsAutoCoding)
        XCTAssertEqual(controller.roundingIncrement, 0.1, accuracy: 0.0001)
        XCTAssertEqual(controller.timekeeperRate, 0)
    }

    func testEditsPersistAndReloadAcrossLaunch() throws {
        let store = try makeStore()
        let controller = BillingSettingsController(store: store)
        controller.globalInstructions = "No block billing."
        controller.autoTimestamp = false
        controller.sensitivity = 0.8
        controller.roundingIncrement = 0.25
        controller.utbmsAutoCoding = false
        controller.timekeeperID = "TK-77"
        controller.timekeeperName = "J. Smith"
        controller.timekeeperClassification = "PARTNER"
        controller.timekeeperRate = 525
        controller.lawFirmID = "98-7654321"

        // A fresh controller (relaunch) reads the persisted blob.
        let reloaded = BillingSettingsController(store: store)
        XCTAssertEqual(reloaded.globalInstructions, "No block billing.")
        XCTAssertFalse(reloaded.autoTimestamp)
        XCTAssertEqual(reloaded.sensitivity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.roundingIncrement, 0.25, accuracy: 0.0001)
        XCTAssertFalse(reloaded.utbmsAutoCoding)
        XCTAssertEqual(reloaded.timekeeper.id, "TK-77")
        XCTAssertEqual(reloaded.timekeeper.defaultRate, 525, accuracy: 0.0001)
        XCTAssertEqual(reloaded.timekeeper.lawFirmID, "98-7654321")
    }

    func testTimekeeperTrimsWhitespaceAndFloorsRate() throws {
        let controller = BillingSettingsController(store: try makeStore())
        controller.timekeeperName = "  J. Smith  "
        controller.timekeeperRate = -10
        XCTAssertEqual(controller.timekeeper.name, "J. Smith")
        XCTAssertEqual(controller.timekeeper.defaultRate, 0)
    }

    func testStoredUnderScratchPadBillingKey() throws {
        let store = try makeStore()
        let controller = BillingSettingsController(store: store)
        controller.globalInstructions = "x"
        let stored = try store.appSettings.getSetting(BillingSettingsController.storageKey, as: BillingSettings.self)
        XCTAssertEqual(stored?.globalInstructions, "x")
        XCTAssertEqual(BillingSettingsController.storageKey, "scratchpad.billing")
    }
}
