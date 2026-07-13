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
            result.waitForExistence(timeout: 45),
            "The hosted XPC lifecycle harness did not publish a result."
        )
        XCTAssertEqual(result.label, "PASS", app.staticTexts["runtimeXPCIntegration.detail"].label)
    }

    func testSwitchBindingAndKeyboardTraversal() {
        let app = launchIntegrationApp(scenario: "switch")

        let toggle = app.switches["runtimeXPCIntegration.switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "1", "NSSwitch action must update its SwiftUI binding.")

        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
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
        return app
    }
}
