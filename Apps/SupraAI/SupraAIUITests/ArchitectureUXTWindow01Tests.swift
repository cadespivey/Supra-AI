import Foundation
import XCTest

/// T-WINDOW-01 native wire proof.
///
/// Expected RED: the app still declares a `WindowGroup`, its DEBUG launch
/// delegate reaches into the File menu to create a fresh “New Window,” and the
/// process-global matter-controller scope has no exact window-context ledger.
/// Every live test checks that source contract first, so the pre-implementation
/// RED is immediate and does not become an app-launch timeout on a locked Mac.
@MainActor
final class ArchitectureUXTWindow01Tests: XCTestCase {
    private enum Wire {
        static let ledgerID = "T_WINDOW_01_LEDGER_941"
        static let matterID = "matter-window-947"
        static let matterName = "Aster Harbor LLC v. Northline Rail 953"
        static let route = "publicRecords"
        static let routeTitle = "Public Records"
        static let forbiddenDefault = "DEFAULT-000"

        static var routeContext: String {
            "ledger=\(ledgerID)|route=\(route)|visibleMatter=none|controllerMatter=none"
        }

        static var matterContext: String {
            "ledger=\(ledgerID)|route=matter|visibleMatter=\(matterID)|controllerMatter=\(matterID)"
        }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func test00ShippingSceneOwnsOneMainWindowAndNoNewWindowHelper() throws {
        let source = try appSource(relativePath: "SupraAI/SupraAIApp.swift")

        XCTAssertFalse(
            source.contains("WindowGroup"),
            "Expected RED: the shipping scene still permits independent main windows"
        )
        XCTAssertTrue(
            source.contains("Window(\"Supra AI\""),
            "The single supported main scene must be an explicit Window"
        )
        XCTAssertTrue(
            source.contains(".defaultLaunchBehavior(.presented)"),
            "The primary singleton must reopen when no saved scene is visible"
        )
        XCTAssertTrue(source.contains(".restorationBehavior(.disabled)"))
        for forbidden in [
            "scheduleFreshUITestWindowIfNeeded",
            "shouldEnsureFreshUITestWindow",
            "item(withTitle: \"New Window\")",
            "-uiTestEnsureFreshWindow",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Expected RED: remove the second-main-window helper \(forbidden)"
            )
        }
    }

    func testSingleMainWindowExposesNoNewWindowCommandOrShortcut() throws {
        try requireImplementedSourceContract()

        let app = launch()
        defer { app.terminate() }

        XCTAssertEqual(app.windows.count, 1, "T-WINDOW-01 supports exactly one main window")

        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.75)
        XCTAssertEqual(
            app.windows.count,
            1,
            "Command-N must not create an unsupported second main window"
        )
    }

    func testRouteMatterAndControllerScopeRemainExactInOneWindow() throws {
        try requireImplementedSourceContract()

        let app = launch()
        defer { app.terminate() }

        let route = app.descendants(matching: .any)["sidebar.route.\(Wire.route)"]
        XCTAssertTrue(route.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[Wire.routeTitle].waitForExistence(timeout: 5))
        assertLedger(Wire.routeContext, in: app)

        let matter = app.descendants(matching: .any)["matter.row.\(Wire.matterName)"]
        XCTAssertTrue(matter.waitForExistence(timeout: 10))
        matter.click()
        assertLedger(Wire.matterContext, in: app)
        XCTAssertEqual(app.windows.count, 1)

        // Public Records is the third stable AppRoute. Exercise the production
        // Go command through its advertised keyboard shortcut; macOS 27 does
        // not consistently expose top-level SwiftUI menus as AX menu items.
        app.typeKey("3", modifierFlags: .command)

        XCTAssertTrue(route.waitForExistence(timeout: 10))
        assertLedger(Wire.routeContext, in: app)
        XCTAssertEqual(
            app.windows.count,
            1,
            "Targeted Go routing must update the one supported window"
        )
    }

    /// Before GREEN, each live test stops at the explicit scene-contract RED.
    /// After GREEN, the exact DEBUG ledger must also be present so a selected
    /// row cannot merely look correct while the shared controller points at a
    /// different matter.
    private func requireImplementedSourceContract() throws {
        let app = try appSource(relativePath: "SupraAI/SupraAIApp.swift")
        XCTAssertFalse(
            app.contains("WindowGroup"),
            "Expected RED: WindowGroup still allows a second main window"
        )
        XCTAssertTrue(app.contains("Window(\"Supra AI\""))
        XCTAssertTrue(app.contains(".defaultLaunchBehavior(.presented)"))
        XCTAssertTrue(app.contains(".restorationBehavior(.disabled)"))
        XCTAssertFalse(app.contains("scheduleFreshUITestWindowIfNeeded"))
        XCTAssertFalse(app.contains("item(withTitle: \"New Window\")"))

        let shell = try appSource(relativePath: "SupraAI/MainShellView.swift")
        XCTAssertTrue(
            shell.contains("window.session.ledger"),
            "Expected RED: the exact window route/matter/controller ledger is absent"
        )
        for wire in [Wire.ledgerID, Wire.matterID, Wire.forbiddenDefault] {
            XCTAssertFalse(
                shell.contains(wire),
                "Production must parse the launch wire; it may not hardcode \(wire)"
            )
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestWindowLedgerID", Wire.ledgerID,
            "-uiTestWindowMatterID", Wire.matterID,
            "-uiTestWindowMatterName", Wire.matterName,
            "-uiTestInitialRoute", Wire.route,
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))
        return app
    }

    private func assertLedger(_ expected: String, in app: XCUIApplication) {
        let ledger = app.descendants(matching: .any)["window.session.ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        XCTAssertEqual(ledger.value as? String, expected)
        let rendered = [ledger.label, ledger.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertFalse(rendered.contains(Wire.forbiddenDefault))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("current matter"))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("default route"))
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
