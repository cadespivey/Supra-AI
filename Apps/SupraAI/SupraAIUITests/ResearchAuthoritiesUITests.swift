import XCTest

/// End-to-end UI test driving the Research and Authorities tabs with mouse-style
/// clicks and keyboard input — fully offline (no model or network). The app is
/// launched with `-uiTestMode`, which opens a hermetic throwaway store seeded with
/// a single "UITest Matter" (see AppEnvironment.isUITestMode).
final class ResearchAuthoritiesUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestMode"]
        app.launch()
        return app
    }

    func testResearchPlannerAndAuthoritiesFlow() {
        let app = launchApp()

        // Open the seeded matter from the far-left sidebar.
        let matter = app.staticTexts["UITest Matter"]
        XCTAssertTrue(matter.waitForExistence(timeout: 20), "Seeded matter did not appear in the sidebar")
        matter.click()

        // --- Research tab ---
        let researchTab = app.buttons["matterTab.Research"]
        XCTAssertTrue(researchTab.waitForExistence(timeout: 10), "Research tab not found")
        researchTab.click()

        // Open the planner sheet.
        let newSession = app.buttons["research.newSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10), "New Research Session button not found")
        newSession.click()

        // Fill the issue. (Jurisdiction is pre-filled from the matter.)
        let title = app.textFields["planner.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Planner sheet did not open")
        title.click()
        title.typeText("Trade secret misappropriation")

        let issue = app.textFields["planner.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5), "Issue field not found")
        issue.click()
        issue.typeText("Whether the NDA covers post-termination use of source code.")

        // Generate with no model loaded — this reveals the manual query editor.
        app.buttons["planner.generate"].click()

        // Add an approved query (Add Query defaults to approved = true) and type it.
        let addQuery = app.buttons["planner.addQuery"]
        XCTAssertTrue(addQuery.waitForExistence(timeout: 10), "Query editor did not appear after Generate")
        addQuery.click()

        let query = app.textFields["planner.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "Query field not found")
        query.click()
        query.typeText("trade secret nda source code")

        // Save the plan → creates a research session.
        let save = app.buttons["planner.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Save Plan should enable once an approved query has text")
        save.click()

        // The new session appears in the Research list.
        XCTAssertTrue(
            app.staticTexts["Trade secret misappropriation"].waitForExistence(timeout: 10),
            "The saved research session did not appear in the Research list"
        )

        // --- Authorities tab ---
        app.buttons["matterTab.Authorities"].click()
        XCTAssertTrue(
            app.staticTexts["No Authorities Saved"].waitForExistence(timeout: 10),
            "Authorities empty state not shown"
        )

        // Its "New Research Session" action routes back to the Research tab.
        app.buttons["authorities.newResearch"].click()
        XCTAssertTrue(
            app.buttons["research.newSession"].waitForExistence(timeout: 10),
            "Authorities empty-state action should switch back to the Research tab"
        )
    }
}
