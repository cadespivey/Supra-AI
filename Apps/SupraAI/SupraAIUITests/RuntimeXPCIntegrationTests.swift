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
            // T-QUEUE-03 expected RED: the hosted harness does not yet ask the
            // loaded content-bound model to generate with a deliberately wrong,
            // non-default expected SHA. The service must reject that request
            // before publishing generationStarted or invoking the model actor.
            "generationFingerprintMismatchRejected",
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

    func testBoundedLargeCorpusRAGResourceEnvelope() {
        let app = launchIntegrationApp(scenario: "rag-scan")

        let result = app.staticTexts["runtimeXPCIntegration.ragScan.result"]
        XCTAssertTrue(
            result.waitForExistence(timeout: 90),
            "The hosted T-RAG-SCAN-02 probe did not publish a result."
        )
        XCTAssertEqual(
            result.value as? String,
            "PASS",
            app.staticTexts["runtimeXPCIntegration.ragScan.detail"].value as? String
                ?? "No hosted RAG resource detail."
        )

        XCTAssertEqual(intValue(app, "scannedRows"), 31)
        XCTAssertLessThanOrEqual(intValue(app, "maximumLivePageRows"), 3)
        XCTAssertLessThanOrEqual(intValue(app, "maximumHeapEntries"), 2)
        XCTAssertLessThanOrEqual(intValue(app, "maximumLiveVectorBytes"), 36)
        XCTAssertEqual(intValue(app, "publishedCandidateCount"), 2)
        XCTAssertEqual(intValue(app, "cacheCeilingBytes"), 17)

        XCTAssertLessThanOrEqual(intValue(app, "appCurrentDeltaMiB"), 64)
        XCTAssertLessThanOrEqual(intValue(app, "appPeakDeltaMiB"), 64)
        XCTAssertLessThanOrEqual(intValue(app, "xpcCurrentDeltaMiB"), 32)
        XCTAssertLessThanOrEqual(intValue(app, "xpcPeakDeltaMiB"), 32)
        XCTAssertLessThanOrEqual(intValue(app, "combinedCurrentDeltaMiB"), 96)
        XCTAssertLessThanOrEqual(intValue(app, "combinedPeakDeltaMiB"), 96)

        let detail = app.staticTexts["runtimeXPCIntegration.ragScan.detail"].value as? String
            ?? ""
        XCTAssertTrue(detail.contains("T_RAG_SCAN_02_WIRE_731"))
        XCTAssertTrue(detail.contains("QUERY_713"))
        XCTAssertFalse(detail.contains("T_RAG_SCAN_02_DEFAULT-000"))
    }

    private func intValue(_ app: XCUIApplication, _ name: String) -> Int {
        let element = app.staticTexts["runtimeXPCIntegration.ragScan.\(name)"]
        XCTAssertTrue(element.exists, "Missing hosted RAG metric \(name).")
        let value = element.value as? String
        XCTAssertNotNil(value, "Hosted RAG metric \(name) has no accessibility value.")
        let parsed = value.flatMap(Int.init)
        XCTAssertNotNil(parsed, "Hosted RAG metric \(name) is not an integer: \(value ?? "nil")")
        return parsed ?? Int.max
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
