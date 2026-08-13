import XCTest

/// T-UX-DELETE-02 native proof for irreversible deletion and recovery actions.
///
/// Expected RED: Recycle Bin is tinted and described like a destructive action;
/// permanent row actions lack the exact accessible semantics; database recovery
/// has no Copy Diagnostic Report or separately disclosed Support Details.
@MainActor
final class ArchitectureUXTUxDelete02Tests: XCTestCase {
    private let matterName = "McKernon Motors v. Liberty Rail"

    override func setUp() {
        continueAfterFailure = false
    }

    func testOnlyPermanentDeletionUsesIrreversiblePresentation() {
        let app = launchDeletionFixture()
        let destination = app.buttons["sidebar.recycleBin"]
        XCTAssertTrue(destination.waitForExistence(timeout: 20))
        XCTAssertEqual(destination.value as? String, "Restorable deleted items")
        destination.click()

        let permanent = app.buttons["recycleBin.deletePermanently.matter.\(matterName)"]
        XCTAssertTrue(permanent.waitForExistence(timeout: 10))
        XCTAssertEqual(permanent.label, "Delete Permanently")
        permanent.click()

        let message = app.descendants(matching: .any)["recycleBin.deletePermanently.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let text = [message.label, message.value as? String].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("cannot be undone"))
        XCTAssertFalse(text.contains("DEFAULT-000"))
        XCTAssertEqual(app.buttons["recycleBin.deletePermanently.confirm"].label, "Delete Permanently")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRecoveryLeadsWithPreserveFolderDiagnosticsAndSafeQuit() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestRestoreRecoveryRequired",
        ]
        app.launch()

        let shell = app.descendants(matching: .any)["restore.recovery.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 20))
        let instructions = app.descendants(matching: .any)["restore.recovery.instructions"]
        let text = [instructions.label, instructions.value as? String].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("work is disabled"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("preserve"))
        XCTAssertTrue(app.buttons["Show Recovery Folder"].exists)
        XCTAssertTrue(app.buttons["Copy Diagnostic Report"].exists)
        XCTAssertTrue(app.buttons["Quit Without Changes"].exists)

        let details = app.disclosureTriangles["restore.recovery.supportDetails"]
        XCTAssertTrue(details.exists)
        XCTAssertFalse(app.descendants(matching: .any)["restore.recovery.technicalFacts"].exists)
        details.click()
        XCTAssertTrue(app.descendants(matching: .any)["restore.recovery.technicalFacts"].waitForExistence(timeout: 5))
    }

    private func launchDeletionFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestDeletionSemantics",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let move = app.buttons["matter.moveToRecycleBin"]
        XCTAssertTrue(move.waitForExistence(timeout: 20))
        move.click()
        XCTAssertTrue(app.buttons["matter.moveToRecycleBin.confirm"].waitForExistence(timeout: 5))
        app.buttons["matter.moveToRecycleBin.confirm"].click()
        return app
    }
}
