import AppKit
import XCTest

/// T-UI-RST-01...04 exercise restore through the hosted Settings/recovery
/// surfaces while `-uiTestMode` keeps every database and candidate synthetic.
@MainActor
final class RestoreSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // T-UI-RST-01/T-RST-33: blocked facts and reason are announced, but selection is disabled.
    func testInvalidSnapshotShowsFactsAndCannotBeSelected() {
        let app = launchSettingsScenario("mixed")
        let inspect = reveal("restore.inspect", in: app)
        XCTAssertTrue(inspect.isEnabled)
        inspect.click()

        let invalid = reveal("restore.select.supra-20260730-081500-000", in: app)
        XCTAssertTrue(invalid.exists)
        XCTAssertFalse(invalid.isEnabled)
        XCTAssertTrue(invalid.label.contains("2.3.2"))
        XCTAssertTrue(invalid.label.contains("391"))
        let reason = app.staticTexts["restore.reason.supra-20260730-081500-000"]
        XCTAssertTrue(reason.exists)
        XCTAssertTrue(reason.label.localizedCaseInsensitiveContains("integrity"))

        XCTAssertFalse(app.buttons["restore.review"].isEnabled)
    }

    // T-UI-RST-02/T-RST-34...35: confirmation identifies replacement/restart and Escape cancels it.
    func testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel() {
        let app = launchSettingsScenario("mixed")
        reveal("restore.inspect", in: app).click()
        let valid = reveal("restore.select.supra-20260731-090000-000", in: app)
        XCTAssertTrue(valid.isEnabled)
        valid.click()
        let review = reveal("restore.review", in: app)
        XCTAssertTrue(review.isEnabled)
        review.click()

        let dialog = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let dialogText = dialog.descendants(matching: .staticText).allElementsBoundByIndex
            .map(\.label).joined(separator: " ")
        XCTAssertTrue(dialogText.contains("supra-20260731-090000-000"))
        XCTAssertTrue(dialogText.localizedCaseInsensitiveContains("replace"))
        XCTAssertTrue(dialogText.localizedCaseInsensitiveContains("relaunch"))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["restore.restart"].exists)
    }

    // T-UI-RST-03/T-RST-36: staging returns to Settings with restart as the only activation action.
    func testSuccessfulStageOffersColdRestartWithoutLiveSwap() {
        let app = launchSettingsScenario("mixed")
        reveal("restore.inspect", in: app).click()
        reveal("restore.select.supra-20260731-090000-000", in: app).click()
        reveal("restore.review", in: app).click()

        let confirm = app.buttons["restore.confirm"].exists
            ? app.buttons["restore.confirm"]
            : app.buttons["Stage Restore"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let restart = reveal("restore.restart", in: app)
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        XCTAssertEqual(restart.label, "Quit and Restore on Next Launch")
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
        XCTAssertTrue(app.staticTexts["Settings"].exists, "staging must not swap the live writer or shell")
    }

    // T-UI-RST-04: double-failure replaces the work surface with an accessible recovery shell.
    func testRecoveryRequiredShellProvidesPreservationAndQuitInstructions() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestRestoreRecoveryRequired",
        ]
        app.launch()
        app.activate()

        let shell = app.descendants(matching: .any)["restore.recovery.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Restore recovery required"].exists)
        let instructions = app.staticTexts["restore.recovery.instructions"]
        XCTAssertTrue(instructions.exists)
        XCTAssertTrue(instructions.label.localizedCaseInsensitiveContains("preserve"))
        XCTAssertTrue(app.buttons["Show Recovery Snapshot"].exists)
        XCTAssertTrue(app.buttons["Quit Without Changes"].exists)
    }

    private func launchSettingsScenario(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestInitialRoute", "settings",
            "-uiTestRestoreScenario", scenario,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20))
        return app
    }

    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if !element.waitForExistence(timeout: 2) {
            for _ in 0..<8 where !element.exists {
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -380)
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing restore control: \(identifier)")
        return element
    }
}
