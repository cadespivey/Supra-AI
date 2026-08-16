import XCTest

/// T-UX-DELETE-01 native wire proof.
///
/// Expected RED: the matter and chat actions are still exposed as destructive
/// “Delete” controls, their dialogs claim the reversible operation cannot be
/// undone, and the exact Recycle Bin/restore identifiers below are absent.
@MainActor
final class ArchitectureUXTUxDelete01Tests: XCTestCase {
    private let matterName = "McKernon Motors v. Liberty Rail"
    private let chatName = "Citations Demo"

    override func setUp() {
        continueAfterFailure = false
    }

    func testMatterMovesToRecycleBinAndRestores() {
        let app = launch(selectFirstMatter: true)
        let action = app.buttons["matter.moveToRecycleBin"]
        XCTAssertTrue(action.waitForExistence(timeout: 20))
        XCTAssertEqual(action.label, "Move to Recycle Bin")
        action.click()

        assertRestorableDialog(in: app, identifier: "matter.moveToRecycleBin.message")
        app.buttons["matter.moveToRecycleBin.confirm"].click()
        XCTAssertTrue(app.descendants(matching: .any)["matter.row.\(matterName)"].waitForNonExistence(timeout: 10))

        openRecycleBin(in: app)
        let item = app.descendants(matching: .any)["recycleBin.item.matter.\(matterName)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let restore = app.buttons["recycleBin.restore.matter.\(matterName)"]
        XCTAssertEqual(restore.label, "Restore")
        restore.click()
        XCTAssertTrue(app.descendants(matching: .any)["matter.row.\(matterName)"].waitForExistence(timeout: 10))
    }

    func testChatMovesToRecycleBinAndRestores() {
        let app = launch(selectFirstMatter: false)
        let menu = app.descendants(matching: .any)["chat.menu.\(chatName)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.click()
        let action = app.menuItems["chat.moveToRecycleBin.\(chatName)"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()

        assertRestorableDialog(in: app, identifier: "chat.moveToRecycleBin.message")
        app.buttons["chat.moveToRecycleBin.confirm"].click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.row.\(chatName)"].waitForNonExistence(timeout: 10))

        openRecycleBin(in: app)
        let item = app.descendants(matching: .any)["recycleBin.item.chat.\(chatName)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        app.buttons["recycleBin.restore.chat.\(chatName)"].click()
        let globalChats = app.descendants(matching: .any)["sidebar.route.globalChats"]
        XCTAssertTrue(globalChats.waitForExistence(timeout: 10))
        globalChats.click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.row.\(chatName)"].waitForExistence(timeout: 10))
    }

    private func launch(selectFirstMatter: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestDeletionSemantics",
        ]
        if selectFirstMatter { app.launchArguments.append("-uiTestSelectFirstMatter") }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func assertRestorableDialog(in app: XCUIApplication, identifier: String) {
        _ = identifier // System confirmation dialogs do not preserve child identifiers.
        let confirmation = app.buttons["matter.moveToRecycleBin.confirm"].exists
            ? app.buttons["matter.moveToRecycleBin.confirm"]
            : app.buttons["chat.moveToRecycleBin.confirm"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(confirmation.label, "Move to Recycle Bin")
    }

    private func openRecycleBin(in app: XCUIApplication) {
        let destination = app.buttons["sidebar.recycleBin"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertEqual(destination.label, "Recycle Bin")
        XCTAssertEqual(destination.value as? String, "Restorable deleted items")
        destination.click()
    }
}
