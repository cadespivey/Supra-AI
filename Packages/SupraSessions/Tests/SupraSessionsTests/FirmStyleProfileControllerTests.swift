import Foundation
import SupraDraftingCore
@testable import SupraSessions
import SupraStore
import XCTest

/// M2-T1 — FirmStyleProfileController autosave/load/persist (SPEC §4.4).
/// RED-first: undefined type `FirmStyleProfileController` until the controller lands.
final class FirmStyleProfileControllerTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirmStyleStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    private enum PersistTestError: Error { case boom }

    // T-PERSIST-01 — a fresh store yields the default profile, which resolves to .defaultFL.
    @MainActor
    func testAbsentProfileLoadsDefaultResolvingToDefaultFL() throws {
        let store = try makeStore()
        let controller = FirmStyleProfileController(store: store)
        XCTAssertEqual(controller.profile, FirmStyleProfile())
        XCTAssertEqual(controller.profile.resolved(), HouseStyleSheet.defaultFL)
    }

    // T-PERSIST-02 — an edit autosaves (didSet → persist); a fresh controller on the SAME store
    // reloads it. WIRE-PROOF: a non-default judge label survives the round-trip.
    @MainActor
    func testEditAutosavesAndReloads() throws {
        let store = try makeStore()
        let controller = FirmStyleProfileController(store: store)
        controller.profile.captionJudgeLabel = "J: "
        XCTAssertNil(controller.message, "a successful save leaves no error message")

        let reloaded = FirmStyleProfileController(store: store)
        XCTAssertEqual(reloaded.profile.captionJudgeLabel, "J: ")   // persisted + reloaded
        XCTAssertNotEqual(reloaded.profile.captionJudgeLabel, nil)  // not the default (nil) value
    }

    // T-PERSIST-03 — `message` is set ONLY when the write fails, never on success.
    @MainActor
    func testMessageSetOnlyOnWriteFailure() {
        let failing = FirmStyleProfileController(
            initialProfile: FirmStyleProfile(), write: { _ in throw PersistTestError.boom })
        failing.profile.captionJudgeLabel = "J: "   // didSet → persist → throws
        XCTAssertNotNil(failing.message)

        let succeeding = FirmStyleProfileController(
            initialProfile: FirmStyleProfile(), write: { _ in })
        succeeding.profile.captionJudgeLabel = "J: "   // didSet → persist → ok
        XCTAssertNil(succeeding.message)
    }
}
