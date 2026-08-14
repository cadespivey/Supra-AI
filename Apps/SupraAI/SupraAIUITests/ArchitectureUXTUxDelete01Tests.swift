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

        assertRestorableDialog(
            in: app,
            message: "This moves the matter and its chats to the Recycle Bin. You can restore them from the Recycle Bin."
        )
        app.buttons["matter.moveToRecycleBin.confirm"].click()
        XCTAssertTrue(app.descendants(matching: .any)["matter.row.\(matterName)"].waitForNonExistence(timeout: 10))

        openRecycleBin(in: app)
        let item = app.descendants(matching: .any)["recycleBin.item.matter.\(matterName)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let restore = app.descendants(matching: .any)[
            "recycleBin.restore.matter.\(matterName)"
        ]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertEqual(restore.label, "Restore")
        restore.click()
        XCTAssertTrue(app.descendants(matching: .any)["matter.row.\(matterName)"].waitForExistence(timeout: 10))
    }

    func testChatMovesToRecycleBinAndRestores() {
        let app = launch(selectFirstMatter: false)
        // SwiftUI exposes `Menu` as a menu-button-like accessibility element on
        // macOS, not consistently as XCUIElementTypeButton. The stable shipping
        // identifier is the contract; do not couple this gate to the host role.
        let menu = app.descendants(matching: .any)["chat.menu.\(chatName)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.click()
        let action = app.menuItems["chat.moveToRecycleBin.\(chatName)"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "Move to Recycle Bin")
        action.click()

        assertRestorableDialog(
            in: app,
            message: "This moves the chat to the Recycle Bin. You can restore it from the Recycle Bin."
        )
        app.buttons["chat.moveToRecycleBin.confirm"].click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.row.\(chatName)"].waitForNonExistence(timeout: 10))

        openRecycleBin(in: app)
        let item = app.descendants(matching: .any)["recycleBin.item.chat.\(chatName)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let restore = app.descendants(matching: .any)[
            "recycleBin.restore.chat.\(chatName)"
        ]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        let globalChats = app.buttons["sidebar.route.globalChats"]
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
        ]
        if selectFirstMatter { app.launchArguments.append("-uiTestSelectFirstMatter") }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func assertRestorableDialog(in app: XCUIApplication, message expected: String) {
        // macOS confirmationDialog flattens the SwiftUI message identifier into
        // the system dialog. Bind to the exact non-default shipping copy rather
        // than pretending that swallowed child identifier is observable.
        let message = app.staticTexts[expected]
        XCTAssertTrue(message.waitForExistence(timeout: 5), expected)
        let text = [message.label, message.value as? String].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(text.contains("Recycle Bin"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("restore"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cannot be undone"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("can't be undone"))
        XCTAssertFalse(text.contains("DEFAULT-000"))
    }

    private func openRecycleBin(in app: XCUIApplication) {
        let destination = app.buttons["sidebar.recycleBin"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertEqual(destination.label, "Recycle Bin")
        XCTAssertEqual(destination.value as? String, "Restorable deleted items")
        destination.click()
    }
}
