import XCTest

/// End-to-end UI test driving the Research and Authorities tabs with mouse-style
/// clicks and keyboard input — fully offline (no model or network). The app is
/// launched with `-uiTestMode`, which opens a hermetic throwaway store seeded with
/// a single "McKernon Motors v. Liberty Rail" matter (see AppEnvironment.isUITestMode).
@MainActor
final class ResearchAuthoritiesUITests: XCTestCase {
    private let seededMatterName = "McKernon Motors v. Liberty Rail"
    private var tabCommandURL: URL?

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-uiTestMode"]
        let tabCommandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraAI-UITest-\(UUID().uuidString)-matter-tab.txt")
        try? "".write(to: tabCommandURL, atomically: true, encoding: .utf8)
        self.tabCommandURL = tabCommandURL
        app.launchEnvironment["SUPRA_UI_TEST_TAB_COMMAND_FILE"] = tabCommandURL.path
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        }
        return app
    }

    func testResearchPlannerAndAuthoritiesFlow() {
        let app = launchApp()

        // Open the seeded matter from the far-left sidebar.
        let matter = seededMatterRow(in: app)
        XCTAssertTrue(matter.waitForExistence(timeout: 20), "Seeded matter did not appear in the sidebar")
        matter.click()

        // --- Research tab ---
        let researchTab = app.radioButtons["matterTab.Research"]
        XCTAssertTrue(researchTab.waitForExistence(timeout: 10), "Research tab not found")
        selectMatterTab("Research")

        // Open the planner sheet.
        let newSession = app.buttons["research.newSession"]
        XCTAssertTrue(
            newSession.waitForExistence(timeout: 10),
            "New Research Session button not found"
        )
        newSession.click()

        // Fill the issue. (Jurisdiction is pre-filled from the matter.)
        let title = app.textFields["planner.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Planner sheet did not open")
        title.click()
        title.typeText("Trade secret misappropriation")

        // The issue field is now a bordered, auto-growing MultilineField (TextEditor),
        // so it surfaces as a textView rather than a textField.
        let issue = app.textViews["planner.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5), "Issue field not found")
        issue.click()
        issue.typeText("Whether the NDA covers post-termination use of source code.")

        // Generate with no model loaded — this reveals the manual query editor.
        app.buttons["planner.generate"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()

        // Add an approved query (Add Query defaults to approved = true) and type it.
        let addQuery = app.buttons["planner.addQuery"]
        XCTAssertTrue(addQuery.waitForExistence(timeout: 10), "Query editor did not appear after Generate")
        addQuery.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let query = app.textFields["planner.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "Query field not found")
        app.sheets.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -420)
        query.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        query.typeText("trade secret nda source code")

        // Save the plan → creates a research session.
        let save = app.buttons["planner.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Save Plan should enable once an approved query has text")
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // The new session appears in the Research list.
        XCTAssertTrue(
            app.descendants(matching: .any)["research.session.Trade secret misappropriation"].waitForExistence(timeout: 10),
            "The saved research session did not appear in the Research list"
        )

        // --- Authorities tab ---
        XCTAssertTrue(app.radioButtons["matterTab.Authorities"].waitForExistence(timeout: 10))
        selectMatterTab("Authorities")
        XCTAssertTrue(
            app.staticTexts["No Authorities Saved"].waitForExistence(timeout: 10),
            "Authorities empty state not shown"
        )

        // Its "New Research Session" action routes back to the Research tab.
        let authoritiesNewResearch = app.buttons["authorities.newResearch"]
        XCTAssertTrue(authoritiesNewResearch.waitForExistence(timeout: 5), "Authorities New Research action not found")
        authoritiesNewResearch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            app.buttons["research.newSession"].waitForExistence(timeout: 10),
            "Authorities empty-state action should switch back to the Research tab"
        )
    }

    private func seededMatterRow(in app: XCUIApplication) -> XCUIElement {
        let identifier = "matter.row.\(seededMatterName)"
        return app.descendants(matching: .any)[identifier]
    }

    private func selectMatterTab(_ rawValue: String) {
        guard let tabCommandURL else { return }
        try? rawValue.write(to: tabCommandURL, atomically: true, encoding: .utf8)
    }
}
