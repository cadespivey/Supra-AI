import XCTest

/// Exercises the signed app -> embedded XPC service boundary. The app's dedicated
/// integration-test surface performs the async protocol checks and exposes only a
/// compact, accessibility-readable result to this out-of-process UI test.
@MainActor
final class RuntimeXPCIntegrationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHostedBoundaryLifecycle() {
        let app = launchIntegrationApp(scenario: "lifecycle")

        let result = app.staticTexts["runtimeXPCIntegration.result"]
        XCTAssertTrue(
            result.waitForExistence(timeout: 90),
            "The hosted XPC lifecycle harness did not publish a result."
        )
        XCTAssertEqual(
            result.value as? String,
            "PASS",
            app.staticTexts["runtimeXPCIntegration.detail"].value as? String ?? "No lifecycle detail."
        )
        XCTAssertEqual(app.staticTexts["runtimeXPCIntegration.iterations"].value as? String, "20/20")

        for checkID in [
            "statusRoundTrip",
            "nilBookmarkRejected",
            "invalidBookmarkRejected",
            "nilManagedIdentityRejected",
            "staleBookmarkRejected",
            "samePathReplacementRejected",
            "managedRootEscapeRejected",
            "contentBindingVerified",
            "controlledModelLoaded",
            "streamCompletedOnce",
            "cancelExactlyOnce",
            "cancelBeforeTaskInstall",
            "reservationBeforeAdmission",
            "foreignCancelRejected",
            "reusedGenerationID",
            "clientTermination",
            "concurrentLoadUnload",
            "reconnect",
            "resourceBound",
        ] {
            let check = app.staticTexts["runtimeXPCIntegration.check.\(checkID)"]
            XCTAssertTrue(check.exists, "Missing lifecycle assertion \(checkID).")
            XCTAssertEqual(check.value as? String, "PASS", "Lifecycle assertion failed: \(checkID).")
        }
    }

    func testSwitchBindingAndKeyboardTraversal() {
        let app = launchIntegrationApp(scenario: "switch")

        let toggle = app.switches["runtimeXPCIntegration.switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "1", "NSSwitch action must update its SwiftUI binding.")

        // Target the AppKit-backed control explicitly: macOS's "click focuses
        // controls" preference is user-configurable, while typeKey(on:) first
        // establishes the deterministic responder under test.
        toggle.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts["runtimeXPCIntegration.afterSwitchFocused"].waitForExistence(timeout: 5),
            "Tab from the NSSwitch must move to the next control exactly once."
        )
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .shift)
        XCTAssertTrue(
            app.staticTexts["runtimeXPCIntegration.switchFocused"].waitForExistence(timeout: 5),
            "Shift-Tab must deterministically return focus to the NSSwitch."
        )
    }

    private func launchIntegrationApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-runtimeXPCIntegrationMode",
            "-runtimeXPCScenario", scenario,
        ]
        app.launch()
        app.activate()
        // macOS can preserve the user's last "all windows closed" state even
        // when application state restoration is disabled. Open the WindowGroup
        // explicitly so the hosted harness is mounted and its task can run.
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(
                app.windows.firstMatch.waitForExistence(timeout: 10),
                "SupraAI did not publish a window for the hosted integration surface."
            )
        }
        return app
    }
}
