import AppKit
import CoreGraphics
import XCTest

/// D-06 proves the internal rollback control drives the same complete rollout
/// coordinator used by the one-time approved promotion. UI-test mode uses a
/// hermetic store with no user documents.
@MainActor
final class DocumentChunkerRolloutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testD06DiagnosticsFlipsToV1AndRestoresV2() {
        // D-06 expected RED: Diagnostics has no chunker version/readiness surface
        // or accessible rollback control, so the required live flip/revert drill
        // cannot be performed through the signed app.
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let diagnosticsRoute = app.staticTexts["Diagnostics"].firstMatch
        XCTAssertTrue(diagnosticsRoute.waitForExistence(timeout: 20))
        diagnosticsRoute.click()

        func assertVersion(_ expected: String, timeout: TimeInterval = 20) {
            let version = app.staticTexts["diagnostics.chunker.version"]
            XCTAssertTrue(version.waitForExistence(timeout: timeout))
            let predicate = NSPredicate(format: "value == %@", expected)
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: version)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
        }

        assertVersion("v2")
        let switcher = app.buttons["diagnostics.chunker.switch"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        // D-06 expected RED: the Form button currently exposes only its
        // text-sized hit target, so assistive automation that resolves the
        // containing row cannot activate the rollback control.
        XCTAssertGreaterThanOrEqual(
            switcher.frame.width,
            app.windows.firstMatch.frame.width * 0.5,
            "The destructive-safe chunker switch must expose a full-row hit target"
        )
        switcher.click()
        assertVersion("v1")
        XCTAssertEqual(app.buttons["diagnostics.chunker.switch"].label, "Restore Chunker v2")
        app.buttons["diagnostics.chunker.switch"].click()
        assertVersion("v2")
    }

    /// Standing guard for the routing-degradation surface added by the review
    /// follow-up. It was green at introduction because the row already existed;
    /// the guard makes deleting it or drifting its user-facing state observable in
    /// the protected UI smoke suite.
    func testDiagnosticsShowsPromptClassifierAvailability() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let diagnosticsRoute = app.staticTexts["Diagnostics"].firstMatch
        XCTAssertTrue(diagnosticsRoute.waitForExistence(timeout: 20))
        diagnosticsRoute.click()

        let availability = app.descendants(matching: .any)[
            "diagnostics.routing.classifierAvailability"
        ]
        XCTAssertTrue(
            availability.waitForExistence(timeout: 20),
            "Diagnostics must expose whether semantic prompt routing is available"
        )
        let renderedState = availability.value as? String ?? availability.label
        XCTAssertTrue(
            [
                "Available",
                "Unavailable — non-marker prompts all use the gated legal route",
            ].contains(renderedState),
            "Unexpected prompt-routing availability state: \(renderedState)"
        )
    }
}

/// T-OPS-02 drives the hermetic interrupted-import fixture through both user
/// decisions. The production app seeds this state only under the explicit UI
/// test launch flag, so real stores are never modified by the fixture.
@MainActor
final class DocumentImportRecoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testInterruptedImportBannerExposesExactCopyAndDiscard() {
        // T-OPS-02 expected RED: no seeded interrupted import or documents.resumeBanner exists.
        let app = launchInterruptedImportApp()
        let banner = app.descendants(matching: .any)["documents.resumeBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "Interrupted import banner did not appear")
        XCTAssertEqual(banner.label, "Import interrupted")
        let message = app.staticTexts["documents.resumeMessage"]
        XCTAssertTrue(message.exists)
        XCTAssertEqual(message.value as? String, "Import interrupted — 2 of 5 files not yet imported")
        XCTAssertTrue(app.buttons["documents.resumeAction"].exists)
        let discard = app.buttons["documents.discardAction"]
        XCTAssertTrue(discard.exists)
        discard.click()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Discard must remove the resume banner")
    }

    func testInterruptedImportResumeDispatchesOnceAndFinishesBothFiles() {
        // T-OPS-02 expected RED: the Documents tab has no persisted-source Resume action.
        let app = launchInterruptedImportApp()
        let banner = app.descendants(matching: .any)["documents.resumeBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "Interrupted import banner did not appear")
        let resume = app.buttons["documents.resumeAction"]
        XCTAssertTrue(resume.exists)
        resume.click()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Resume must dispatch and remove the paused banner")
        XCTAssertTrue(app.staticTexts["Resume Fixture 4.txt"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Resume Fixture 5.txt"].waitForExistence(timeout: 20))
    }

    private func launchInterruptedImportApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestInterruptedImport",
            "-uiTestInitialMatterTab", "Documents",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }
}

/// T-OPS-07 proves a completed policy rejection remains actionable in the
/// Documents surface instead of being reduced to an aggregate Audit event.
@MainActor
final class DocumentImportFailureDetailUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTOPS07LockedSourceShowsFilenameCodeAndRecoveryGuidance() {
        // T-OPS-07 expected RED: the queue drops per-file metadata and the banner
        // exposes only "1 need attention — see the Audit tab".
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestImportFailure",
            "-uiTestInitialMatterTab", "Documents",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let warning = app.descendants(matching: .any)["documents.importFailureWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "Import failure warning did not appear")

        let detail = app.descendants(matching: .any)["documents.importFailureDetail.privileged-locked.pdf"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Rejected filename and guidance were not rendered")
        XCTAssertEqual(detail.label, "privileged-locked.pdf")
        XCTAssertTrue(
            (detail.value as? String)?.contains("encrypted_source") == true,
            "Stable rejection code is missing: \(detail.debugDescription)"
        )
        XCTAssertTrue(
            (detail.value as? String)?.contains("Remove encryption from a copy and try again.") == true,
            "Recovery guidance is missing: \(detail.debugDescription)"
        )
    }
}

/// T-UX-07 exercises the first extracted-part correction surface against a
/// hermetic synthetic document; it never opens or modifies the user's store.
@MainActor
final class DocumentCorrectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTUX07CorrectionEditorSavesHistoryAndShowsReindexing() {
        // T-UX-07 expected RED: no part-edit caller, editor/reason controls, or
        // correction-history accessibility surface exists in the Documents tab.
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestDocumentCorrection",
            "-uiTestInitialMatterTab", "Documents",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let row = app.staticTexts["Correction Fixture.txt"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Synthetic correction fixture did not appear")
        row.click()
        // T-UX-09 accessibility companion expected RED: the selected row's
        // preview action has no stable identifier and is collapsed into the row.
        XCTAssertTrue(
            app.buttons["documents.preview"].waitForExistence(timeout: 10),
            "Selected document preview action is not independently accessible"
        )
        let edit = app.buttons["documents.editExtractedText"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit extracted text action is missing")
        edit.click()

        let editor = app.textViews["documents.partEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Part editor did not appear")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("CORRECTED-BETA UI wire proof")
        let reason = app.textFields["documents.editReason"]
        XCTAssertTrue(reason.exists)
        reason.click()
        reason.typeText("Corrected the synthetic nondefault text")
        app.buttons["documents.saveCorrection"].click()

        XCTAssertTrue(
            app.descendants(matching: .any)["documents.reindexingBadge"].waitForExistence(timeout: 10),
            "Saved correction did not expose the Reindexing badge"
        )

        row.click()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        XCTAssertEqual(app.textViews["documents.partEditor"].value as? String, "CORRECTED-BETA UI wire proof")
        XCTAssertTrue(app.staticTexts["Revision history (2)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ORIGINAL-ALPHA"].exists)
        XCTAssertTrue(app.staticTexts["CORRECTED-BETA UI wire proof"].exists)
    }
}

/// T-UX-08 drives the review queue through exact accessibility controls against
/// a hermetic draft/executed fixture.
@MainActor
final class DocumentRelationReviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTUX08ReviewSurfaceShowsEvidenceAndClearsBlockerOnlyAfterReview() {
        // T-UX-08 expected RED: the Documents tab has no relation review queue,
        // evidence/diff surface, or confirm/reject/override accessibility actions.
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestDocumentRelations",
            "-uiTestInitialMatterTab", "Documents",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let queue = app.buttons["relations.openReview"]
        XCTAssertTrue(queue.waitForExistence(timeout: 20))
        XCTAssertEqual(queue.value as? String, "1 unreviewed relation")
        queue.click()

        XCTAssertTrue(app.descendants(matching: .any)["relations.reviewSheet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["relations.evidence"].exists)
        XCTAssertTrue(app.staticTexts["relations.diff"].exists)
        XCTAssertTrue(app.buttons["relations.confirm"].exists)
        XCTAssertTrue(app.buttons["relations.reject"].exists)
        XCTAssertTrue(app.buttons["relations.override"].exists)
        XCTAssertTrue(app.staticTexts["relations.blocker"].exists)

        app.buttons["relations.override"].click()
        XCTAssertTrue(app.descendants(matching: .any)["relations.overrideSheet"].waitForExistence(timeout: 10))
        app.buttons["relations.saveOverride"].click()

        XCTAssertTrue(app.staticTexts["relations.auditConfirmation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["relations.reviewComplete"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["relations.blocker"].exists)
    }
}

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

    private func launchApp(extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
        ] + extraArguments
        let tabCommandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraAI-UITest-\(UUID().uuidString)-matter-tab.txt")
        try "".write(to: tabCommandURL, atomically: true, encoding: .utf8)
        self.tabCommandURL = tabCommandURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tabCommandURL)
        }
        app.launchEnvironment["SUPRA_UI_TEST_TAB_COMMAND_FILE"] = tabCommandURL.path
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "UI-test window restoration reset did not publish a fresh WindowGroup"
        )
        return app
    }

    func testResearchPlannerAndAuthoritiesFlow() throws {
        let app = try launchApp()

        // Open the seeded matter from the far-left sidebar.
        let matter = seededMatterRow(in: app)
        XCTAssertTrue(matter.waitForExistence(timeout: 20), "Seeded matter did not appear in the sidebar")
        // DEBUG launch routing invokes the same selectMatter path as the sidebar
        // binding, avoiding Xcode-version-specific synthetic List click behavior.

        // --- Research tab --- (ghost segments surface as buttons, not radioButtons)
        let researchTab = app.buttons["matterTab.Research"]
        XCTAssertTrue(researchTab.waitForExistence(timeout: 10), "Research tab not found")
        try selectMatterTab("Research")

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
        try selectMatterTab("Authorities")
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

    func testResearchPlannerTabOrderIsTopToBottom() throws {
        let app = try launchApp()

        let matter = seededMatterRow(in: app)
        XCTAssertTrue(matter.waitForExistence(timeout: 20), "Seeded matter did not appear in the sidebar")

        try selectMatterTab("Research+planner")
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

    func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() throws {
        let app = try launchApp(extraArguments: [
            "-uiTestRemediationWarnings",
            "-uiTestInitialMatterTab", "Outputs",
        ])

        let matter = seededMatterRow(in: app)
        XCTAssertTrue(
            matter.waitForExistence(timeout: 20),
            "Seeded matter did not appear in the sidebar"
        )

        XCTAssertTrue(
            app.buttons["matterTab.Outputs"].waitForExistence(timeout: 10),
            "Outputs tab did not appear before navigation"
        )
        let output = app.buttons["output.row.Legacy Verification Fixture"]
        XCTAssertTrue(output.waitForExistence(timeout: 10), "Legacy output fixture did not appear")
        XCTAssertTrue(output.isHittable, "Legacy output row must be pointer-reachable before navigation")
        let windowFrameBeforeNavigation = app.windows.firstMatch.frame
        // Expected RED before the deterministic output-navigation hook: Xcode 16
        // can drop a synthesized NavigationLink click even after reporting this
        // row hittable. The DEBUG command must drive the same NavigationStack path.
        sendDebugNavigationCommand("output Legacy Verification Fixture")

        // The destination marker separates a completed navigation push from the
        // warning assertions below. DEBUG launch routing uses the production
        // selection helper, including controller scoping and responder cleanup.
        let detail = app.descendants(matching: .any)["output.detail.Legacy Verification Fixture"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Legacy output detail did not finish navigating")

        let warning = app.descendants(matching: .any)["output.verificationWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "Legacy verification warning was not shown")
        XCTAssertEqual(
            warning.label,
            "Output verification status. Previous output needs revalidation. This version predates proposition verification. Reverify its retained sources or regenerate from fresh sources before relying on or exporting it."
        )

        let export = app.descendants(matching: .any)["output.export"]
        XCTAssertTrue(export.exists, "Unavailable export action should remain discoverable")
        XCTAssertFalse(export.isEnabled, "Legacy output must not be exportable")
        XCTAssertEqual(export.label, "Export output unavailable until the output is reverified or regenerated")

        let reverify = app.buttons["Reverify Sources"]
        XCTAssertTrue(reverify.exists)
        XCTAssertTrue(
            reverify.isHittable,
            "Warning repair action must be keyboard and pointer reachable: \(reverify.debugDescription)"
        )
        assertVerticalWindowFrame(
            app.windows.firstMatch.frame,
            equals: windowFrameBeforeNavigation,
            context: "opening a legacy output"
        )
    }

    func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() throws {
        let app = try launchApp(extraArguments: [
            "-uiTestRemediationWarnings",
            "-uiTestInitialRoute", "scratchpad",
            "-uiTestInitialBillingTab",
        ])

        let billingTab = app.buttons["scratchpad.tab.billing"]
        XCTAssertTrue(billingTab.waitForExistence(timeout: 10), "ScratchPad billing tab did not appear")
        billingTab.click()

        let warning = app.descendants(matching: .any)["billing.legacyReviewWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "Legacy billing warning was not shown")
        XCTAssertEqual(
            warning.label,
            "Billing draft review required. Legacy multi-matter draft. Confirm every matter assignment and source entry before export."
        )

        let export = app.descendants(matching: .any)["billing.export"]
        XCTAssertTrue(export.exists, "Unavailable billing export should remain discoverable")
        XCTAssertFalse(export.isEnabled, "Migrated billing draft must not be exportable before review")
        XCTAssertEqual(export.label, "Export billing draft unavailable until migrated matter assignments are reviewed")

        let review = app.buttons["I Reviewed Assignments"]
        XCTAssertTrue(review.exists)
        XCTAssertTrue(review.isHittable, "Billing review action must be keyboard and pointer reachable")
    }

    private func selectMatterTab(_ rawValue: String) throws {
        let tabCommandURL = try XCTUnwrap(
            tabCommandURL,
            "Matter-tab command file was not initialized; the intended navigation action cannot run"
        )
        try rawValue.write(to: tabCommandURL, atomically: true, encoding: .utf8)
    }

    private func sendDebugNavigationCommand(_ command: String) {
        DistributedNotificationCenter.default().post(
            name: .init("SupraDebugNav"),
            object: command
        )
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

/// A blocked draft is an error-only state: VoiceOver receives the block announcement and
/// there is no file artifact or Open/Reveal/Share affordance to act on.
@MainActor
final class DraftingBlockedStateUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testBlockedDraftIsAnnouncedWithoutFileActions() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestOpenDraftSheet",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "UI-test window restoration reset did not publish a fresh WindowGroup"
        )

        let matter = app.descendants(matching: .any)["matter.row.McKernon Motors v. Liberty Rail"]
        XCTAssertTrue(matter.waitForExistence(timeout: 20))
        let generate = app.buttons["drafting.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        XCTAssertTrue(generate.isEnabled)
        // Expected RED before the stable-Xcode layout fix: the finite sheet is
        // centered in a repeatedly expanding parent window, placing this pinned
        // footer thousands of points below the visible screen.
        XCTAssertTrue(
            generate.isHittable,
            "Generate must remain pointer-reachable in the visible sheet footer: \(generate.debugDescription)"
        )
        let windowFrameBeforeGeneration = app.windows.firstMatch.frame
        // Click the visible center explicitly. Some Xcode/macOS combinations can
        // fall back from the accessibility press action after a sheet reflows;
        // coordinate synthesis still exercises the real pointer target.
        generate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let blocked = app.descendants(matching: .any)["drafting.blocked"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 10))
        XCTAssertTrue(blocked.label.localizedCaseInsensitiveContains("blocked"))
        XCTAssertFalse(app.descendants(matching: .any)["drafting.open"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["drafting.reveal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["drafting.share"].exists)
        assertVerticalWindowFrame(
            app.windows.firstMatch.frame,
            equals: windowFrameBeforeGeneration,
            context: "publishing a blocked draft"
        )
    }
}

@MainActor
private func assertVerticalWindowFrame(
    _ actual: CGRect,
    equals expected: CGRect,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual.origin.y,
        expected.origin.y,
        accuracy: 1,
        "Window moved vertically while \(context)",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.height,
        expected.height,
        accuracy: 1,
        "Window height changed while \(context)",
        file: file,
        line: line
    )
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

        // T-UX-09 expected RED: the document preview has no extraction-structure
        // switch or accessible node/relationship rows.
        let structureToggle = app.descendants(matching: .any)["documentPreview.structureToggle"]
        XCTAssertTrue(structureToggle.waitForExistence(timeout: 5), "Extraction Structure control is missing")
        structureToggle.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["documentPreview.structureSummary"].waitForExistence(timeout: 5),
            "Structure node/relationship count is missing"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["documentPreview.structure.node.footnote/1"].waitForExistence(timeout: 5),
            "Footnote structure node is missing"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["documentPreview.structure.node.comment/1"].waitForExistence(timeout: 5),
            "Comment structure node is missing"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["documentPreview.structure.edge.anchor_of.footnote/1.body/paragraph/1"].waitForExistence(timeout: 5),
            "Footnote anchor relationship is missing"
        )
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
