import AppKit
import XCTest

/// T-UI-RST-01...04 exercise restore through the hosted Settings/recovery
/// surfaces while `-uiTestMode` keeps every database and candidate synthetic.
@MainActor
final class RestoreSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // T-UI-RST-01/T-RST-33 expected RED: the hosted Settings route has no
    // restore candidate controls, so the blocked snapshot facts never appear.
    func testInvalidSnapshotShowsFactsAndCannotBeSelected() {
        let app = launchSettingsScenario("mixed")
        let inspect = reveal("restore.inspect", in: app)
        XCTAssertTrue(inspect.isEnabled)
        inspect.click()

        let invalid = reveal("restore.select.SupraAI-20260730-081500-000", in: app)
        XCTAssertTrue(invalid.exists)
        XCTAssertFalse(invalid.isEnabled)
        XCTAssertTrue(invalid.label.contains("2.3.2"))
        XCTAssertTrue(invalid.label.contains("391"))
        let reason = app.staticTexts["restore.reason.SupraAI-20260730-081500-000"]
        XCTAssertTrue(reason.exists)
        XCTAssertTrue(renderedText(of: reason).localizedCaseInsensitiveContains("integrity"))

        XCTAssertFalse(app.buttons["restore.review"].isEnabled)
    }

    // T-UI-RST-02/T-RST-34...35 expected RED: Settings has no restore
    // confirmation naming replacement and next-launch activation to cancel.
    func testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel() {
        let app = launchSettingsScenario("mixed")
        reveal("restore.inspect", in: app).click()
        let valid = reveal("restore.select.SupraAI-20260731-090000-000", in: app)
        XCTAssertTrue(valid.isEnabled)
        valid.click()
        let review = reveal("restore.review", in: app)
        XCTAssertTrue(review.isEnabled)
        review.click()

        let dialog = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let message = app.descendants(matching: .any)["restore.confirmation.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let dialogText = renderedText(of: message)
        XCTAssertTrue(dialogText.contains("SupraAI-20260731-090000-000"))
        XCTAssertTrue(dialogText.localizedCaseInsensitiveContains("replace"))
        XCTAssertTrue(dialogText.localizedCaseInsensitiveContains("quit"))
        XCTAssertTrue(dialogText.localizedCaseInsensitiveContains("next launch"))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["restore.terminal.shell"].exists)
    }

    // T-UI-RST-03/T-RST-36/R-06 expected RED: successful staging leaves the
    // app running with restart controls instead of a terminal shell and exit.
    func testSuccessfulStageShowsTerminalSurfaceAndQuits() {
        let app = launchSettingsScenario("mixed")
        reveal("restore.inspect", in: app).click()
        reveal("restore.select.SupraAI-20260731-090000-000", in: app).click()
        reveal("restore.review", in: app).click()

        let confirm = app.buttons["restore.confirm"].exists
            ? app.buttons["restore.confirm"]
            : app.buttons["Schedule Restore and Quit"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Schedule Restore and Quit")
        confirm.click()

        let terminal = app.descendants(matching: .any)["restore.terminal.shell"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let status = app.staticTexts["restore.terminal.status"]
        XCTAssertTrue(status.exists)
        XCTAssertTrue(renderedText(of: status).localizedCaseInsensitiveContains("quit automatically"))
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    // T-UI-RST-04 expected RED: the hosted double-failure launch exposes no
    // accessible recovery shell, preservation instructions, or safe quit action.
    // T-RST-H08 expected RED: recovery offers only the database snapshot instead
    // of the complete safety folder that also contains managed-document blobs.
    func testRecoveryRequiredShellProvidesPreservationAndQuitInstructions() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode", "YES",
            "-uiTestRestoreRecoveryRequired", "YES",
            "-uiTestEnsureFreshWindow", "YES",
        ]
        app.launch()

        let shell = app.descendants(matching: .any)["restore.recovery.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Restore recovery required"].exists)
        let instructions = app.staticTexts["restore.recovery.instructions"]
        XCTAssertTrue(instructions.exists)
        XCTAssertTrue(renderedText(of: instructions).localizedCaseInsensitiveContains("preserve"))
        let instructionText = renderedText(of: instructions)
        XCTAssertTrue(instructionText.localizedCaseInsensitiveContains("entire safety folder"))
        XCTAssertTrue(instructionText.localizedCaseInsensitiveContains("managed-document blobs"))
        XCTAssertTrue(app.buttons["Show Recovery Folder"].exists)
        XCTAssertFalse(app.buttons["Show Recovery Snapshot"].exists)
        XCTAssertTrue(app.buttons["Quit Without Changes"].exists)
    }

    private func launchSettingsScenario(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode", "YES",
            "-uiTestInitialRoute", "settings",
            "-uiTestRestoreScenario", scenario,
            "-uiTestEnsureFreshWindow", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20))
        let dataAndBackup = app.staticTexts["Data & Backup"].firstMatch
        XCTAssertTrue(dataAndBackup.waitForExistence(timeout: 10))
        dataAndBackup.click()
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

    private func renderedText(of element: XCUIElement) -> String {
        [element.label, element.value as? String].compactMap { $0 }.joined(separator: " ")
    }
}
