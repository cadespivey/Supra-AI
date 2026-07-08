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

    // T-PARSE-09 — the review-pane preview is deterministic and reflects the candidate sheet.
    // Determinism is pinned at the WML-content level (the renderer's documentXML): the .docx
    // container's zip entry timestamps come from ZIPFoundation and are not part of the trust
    // contract. The contains/absent pair is a WIRE-PROOF that the preview renders the
    // EFFECTIVE sheet, not .defaultFL. RED: undefined previewDocumentXML()/previewDocx().
    @MainActor
    func testPreviewIsDeterministic() throws {
        var p = FirmStyleProfile()
        p.captionCaseNumberLabel = "CASE NUMBER: "
        let controller = FirmStyleProfileController(initialProfile: p, write: { _ in })

        let first = try controller.previewDocumentXML()
        let second = try controller.previewDocumentXML()
        XCTAssertEqual(first, second, "same candidate ⇒ identical preview content")
        XCTAssertTrue(first.contains("CASE NUMBER: "))    // candidate reached the preview
        XCTAssertFalse(first.contains("CASE NO.: "))      // not the default sheet

        let docx = try controller.previewDocx()
        XCTAssertEqual(Array(docx.prefix(2)), [0x50, 0x4B], "preview must be a valid OPC zip")
    }

    // The preview must never leak a below-floor sheet. This is a real wire-proof of the clamp:
    // CourtFLRenderer.documentXML calls StyleSheetCompiler.validateFloor, which THROWS on a
    // 10 pt sheet — so if the preview skipped clampedToFloor(), this test fails with the thrown
    // styleFloorViolation rather than silently passing. (Font size itself lives in styles.xml,
    // outside previewDocumentXML's document.xml output, so no-throw IS the observable proof.)
    @MainActor
    func testPreviewClampsBelowFloorProfile() {
        var p = FirmStyleProfile()
        p.pageFontHalfPoints = 20   // 10 pt — below the 2.520(a) floor
        let controller = FirmStyleProfileController(initialProfile: p, write: { _ in })
        XCTAssertNoThrow(try controller.previewDocumentXML())
    }
}
