import XCTest

@MainActor
final class ArchitectureUXPhase5VisualTests: XCTestCase {
    private enum Appearance: String, CaseIterable {
        case light = "Light"
        case dark = "Dark"

        var attachmentSuffix: String { rawValue }
    }

    private let supportedWidths = [880, 1_100, 1_420]

    override func setUp() {
        continueAfterFailure = false
    }

    func testTaskOrientedPrimarySurfacesAcrossSupportedWidthsAndAppearances() {
        for appearance in Appearance.allCases {
            for width in supportedWidths {
                let app = launch(width: width, appearance: appearance)

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
                    XCTAssertTrue(
                        app.descendants(matching: .any)["chat.starter.\(id)"]
                            .waitForExistence(timeout: 10),
                        "\(id) at \(width) points in \(appearance.rawValue) appearance"
                    )
                }
                attachScreenshot(
                    named: "Phase5-Chats-\(width)-\(appearance.attachmentSuffix)",
                    app: app
                )

                app.descendants(matching: .any)["sidebar.route.settings"].click()
                XCTAssertTrue(
                    app.descendants(matching: .any)["settings.categories"]
                        .waitForExistence(timeout: 10)
                )
                attachScreenshot(
                    named: "Phase5-Settings-\(width)-\(appearance.attachmentSuffix)",
                    app: app
                )

                app.descendants(matching: .any)["sidebar.route.diagnostics"].click()
                XCTAssertTrue(
                    app.descendants(matching: .any)["systemStatus.advanced"]
                        .waitForExistence(timeout: 10)
                )
                XCTAssertFalse(app.staticTexts["Document Chunker"].exists)
                attachScreenshot(
                    named: "Phase5-System-Status-\(width)-\(appearance.attachmentSuffix)",
                    app: app
                )
                app.terminate()
            }
        }
    }

    func testMatterTabsReflowAcrossSupportedWidthsAndAppearances() {
        for appearance in Appearance.allCases {
            for width in supportedWidths {
                let app = launch(width: width, appearance: appearance, selectFirstMatter: true)
                let compact = width == 880
                let primary = ["Chat", "Documents", "Research", "Authorities", "Outputs"]
                let expected = compact ? primary : primary + ["Billing", "Audit"]

                for rawID in expected {
                    let tab = app.descendants(matching: .any)["matterTab.\(rawID)"]
                    XCTAssertTrue(
                        tab.waitForExistence(timeout: 20),
                        "Missing \(rawID) at \(width) points in \(appearance.rawValue) appearance"
                    )
                    XCTAssertTrue(
                        tab.isHittable,
                        "Clipped \(rawID) at \(width) points in \(appearance.rawValue) appearance"
                    )
                }

                let more = app.descendants(matching: .any)["matterTab.more"]
                XCTAssertEqual(more.exists, compact)
                if compact {
                    XCTAssertTrue(more.isHittable)
                    XCTAssertFalse(app.descendants(matching: .any)["matterTab.Billing"].exists)
                    XCTAssertFalse(app.descendants(matching: .any)["matterTab.Audit"].exists)
                }
                XCTAssertFalse(app.descendants(matching: .any)["matterTab.Review"].exists)
                attachScreenshot(
                    named: "Phase5-Matter-\(width)-\(appearance.attachmentSuffix)",
                    app: app
                )
                app.terminate()
            }
        }
    }

    func testOversizedVisualFixtureKeepsLeadingNavigationHittable() {
        let app = launch(width: 4_000, appearance: .light)
        let chats = app.descendants(matching: .any)["sidebar.route.globalChats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        XCTAssertTrue(chats.isHittable)
        chats.click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.new"].waitForExistence(timeout: 10))
        app.terminate()
    }

    private func launch(
        width: Int,
        appearance: Appearance,
        selectFirstMatter: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestAppearance", appearance.rawValue.lowercased(),
            "-uiTestWindowWidth", String(width),
        ]
        if selectFirstMatter { app.launchArguments.append("-uiTestSelectFirstMatter") }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))
        let appearanceProbe = app.descendants(matching: .any)["uiTest.appearance"]
        XCTAssertTrue(appearanceProbe.waitForExistence(timeout: 10))
        XCTAssertEqual(appearanceProbe.label, appearance.rawValue)
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
