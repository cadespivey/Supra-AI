import AppKit
import CoreGraphics
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
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tabCommandURL)
        }
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

        // --- Research tab --- (ghost segments surface as buttons, not radioButtons)
        let researchTab = app.buttons["matterTab.Research"]
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
        pasteText("Trade secret misappropriation", into: title, app: app)

        // The issue field is now a bordered, auto-growing MultilineField (TextEditor),
        // so it surfaces as a textView rather than a textField.
        let issue = app.textViews["planner.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5), "Issue field not found")
        pasteText("Whether the NDA covers post-termination use of source code.", into: issue, app: app)

        // With no model assigned the manual query editor is shown automatically
        // (no separate Generate step). Add an approved query and type it.
        let addQuery = app.buttons["planner.addQuery"]
        XCTAssertTrue(addQuery.waitForExistence(timeout: 10), "Manual query editor did not appear when no model is assigned")
        addQuery.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let query = app.textFields["planner.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "Query field not found")
        app.sheets.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -420)
        pasteText("trade secret nda source code", into: query, app: app)

        // Save the plan → creates a research session. With no model the primary action
        // reads "Save" (it becomes "Generate + Save" once a model is assigned).
        let save = app.buttons["planner.generateSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Save should enable once an approved query has text")
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // The new session appears in the Research list.
        XCTAssertTrue(
            app.descendants(matching: .any)["research.session.Trade secret misappropriation"].waitForExistence(timeout: 10),
            "The saved research session did not appear in the Research list"
        )

        // --- Authorities tab ---
        XCTAssertTrue(app.buttons["matterTab.Authorities"].waitForExistence(timeout: 10))
        selectMatterTab("Authorities")
        XCTAssertTrue(
            app.staticTexts["No Authorities Saved"].waitForExistence(timeout: 10),
            "Authorities empty state not shown"
        )

        // Its "New Research Session" action switches to the Research tab AND opens the
        // planner sheet directly (rather than just leaving the user on the tab).
        let authoritiesNewResearch = app.buttons["authorities.newResearch"]
        XCTAssertTrue(authoritiesNewResearch.waitForExistence(timeout: 5), "Authorities New Research action not found")
        authoritiesNewResearch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            app.textFields["planner.title"].waitForExistence(timeout: 10),
            "Authorities 'New Research Session' should open the research planner sheet"
        )
    }

    func testResearchPlannerTabOrderIsTopToBottom() {
        let app = launchApp()

        let matter = seededMatterRow(in: app)
        XCTAssertTrue(matter.waitForExistence(timeout: 20), "Seeded matter did not appear in the sidebar")
        matter.click()

        selectMatterTab("Research+planner")
        let title = app.textFields["planner.title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "Research+planner command should open the research planner sheet"
        )
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Jurisdiction is now a segmented picker and the court-scope control a plain
        // toggle — neither joins the text-field focus chain, so Tab runs
        // title → issue → preferred → excluded → date range.
        waitForPlannerFocus("planner.title", in: app)
        pressTab(in: app)
        waitForPlannerFocus("planner.issue", in: app)
        pressTab(in: app)
        waitForPlannerFocus("planner.preferredCourts", in: app)
        pressTab(in: app)
        waitForPlannerFocus("planner.excludedCourts", in: app)
        pressTab(in: app)
        waitForPlannerFocus("planner.dateRange", in: app)
        pressTab(in: app, shift: true)
        waitForPlannerFocus("planner.excludedCourts", in: app)
    }

    private func seededMatterRow(in app: XCUIApplication) -> XCUIElement {
        let identifier = "matter.row.\(seededMatterName)"
        return app.descendants(matching: .any)[identifier]
    }

    private func selectMatterTab(_ rawValue: String) {
        guard let tabCommandURL else { return }
        try? rawValue.write(to: tabCommandURL, atomically: true, encoding: .utf8)
    }

    private func pasteText(
        _ text: String,
        into element: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Element to receive pasted text did not exist", file: file, line: line)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(text, forType: .string), "Could not seed pasteboard", file: file, line: line)
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func waitForPlannerFocus(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let marker = app.staticTexts["planner.focused.\(identifier)"]
        XCTAssertTrue(
            marker.waitForExistence(timeout: timeout),
            "Expected planner focus to be \(identifier)",
            file: file,
            line: line
        )
    }

    private func pressTab(in app: XCUIApplication, shift: Bool = false) {
        app.activate()
        let flags: XCUIElement.KeyModifierFlags = shift ? .shift : []
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: flags)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

}

/// End-to-end UI test for the chat citation + export features, driven against the
/// `-uiTestMode` "Citations Demo" global chat seeded with an assistant answer that
/// carries clickable `[A1]` (authority) and `[S1]` (document) citations. Fully
/// offline — no model or network (see AppEnvironment.seedUITestCitationsChatIfNeeded).
@MainActor
final class ChatCitationsAndExportUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-uiTestMode"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        }
        return app
    }

    func testSourcesLinkOpensPreviewAndExportIsAvailable() {
        let app = launchApp()

        // The seeded global chat appears in the chat-history sidebar; open it.
        let chatRow = app.buttons["chat.row.Citations Demo"]
        XCTAssertTrue(chatRow.waitForExistence(timeout: 20), "Seeded 'Citations Demo' chat not found")
        chatRow.click()

        // The subtle sources list beneath the answer names both citations and links
        // each to its source.
        let authorityRow = app.descendants(matching: .any)["message.source.A1"]
        let sourceRow = app.descendants(matching: .any)["message.source.S1"]
        XCTAssertTrue(authorityRow.waitForExistence(timeout: 10), "Authority [A1] source row not shown")
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), "Document [S1] source row not shown")

        // Clicking the [S1] document source opens the preview (a trailing slideover).
        sourceRow.click()
        let preview = app.descendants(matching: .any)["documentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Document preview did not open for [S1]")
        XCTAssertTrue(app.staticTexts["agreement.pdf"].waitForExistence(timeout: 5), "Preview did not show the document name")
        app.buttons["Done"].click()

        // Export Chat is reachable from the chat's actions menu. (SwiftUI's Menu
        // surfaces as a menu/pop-up control rather than a plain button, so match any
        // element type by identifier.)
        let menu = app.descendants(matching: .any)["chat.menu.Citations Demo"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Chat actions menu not found")
        menu.click()
        XCTAssertTrue(
            app.menuItems["Export Chat"].waitForExistence(timeout: 10),
            "Export Chat action not found in the chat menu"
        )
    }
}
