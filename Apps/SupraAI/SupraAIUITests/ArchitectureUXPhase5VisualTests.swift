import XCTest

@MainActor
final class ArchitectureUXPhase5VisualTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTaskOrientedPrimarySurfacesAtOrdinaryWidth() {
        let app = launch(width: 1_100)

        let chats = app.descendants(matching: .any)["sidebar.route.globalChats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        chats.click()
        let newChat = app.descendants(matching: .any)["chat.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.click()
        for id in [
            "starter-legal-question", "starter-research-memo", "starter-draft",
            "starter-review-draft", "starter-check-citations",
        ] {
            XCTAssertTrue(app.descendants(matching: .any)["chat.starter.\(id)"].waitForExistence(timeout: 10), id)
        }
        attachScreenshot(named: "Phase5-Chats-1100", app: app)

        app.descendants(matching: .any)["sidebar.route.settings"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.categories"].waitForExistence(timeout: 10))
        attachScreenshot(named: "Phase5-Settings-1100", app: app)

        app.descendants(matching: .any)["sidebar.route.diagnostics"].click()
        XCTAssertTrue(app.descendants(matching: .any)["systemStatus.advanced"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Document Chunker"].exists)
        attachScreenshot(named: "Phase5-System-Status-1100", app: app)
    }

    func testMatterTabsUseReachableMoreAtMinimumWidth() {
        let app = launch(width: 880, selectFirstMatter: true)
        XCTAssertTrue(app.descendants(matching: .any)["matterTab.more"].waitForExistence(timeout: 20))
        for rawID in ["Chat", "Documents", "Research", "Authorities", "Outputs"] {
            XCTAssertTrue(app.descendants(matching: .any)["matterTab.\(rawID)"].isHittable, rawID)
        }
        XCTAssertFalse(app.descendants(matching: .any)["matterTab.Billing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["matterTab.Audit"].exists)
        attachScreenshot(named: "Phase5-Matter-880", app: app)
    }

    private func launch(width: Int, selectFirstMatter: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestWindowWidth", String(width),
        ]
        if selectFirstMatter { app.launchArguments.append("-uiTestSelectFirstMatter") }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
