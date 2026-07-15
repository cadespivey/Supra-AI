import AppKit
import CoreGraphics
import XCTest

/// Gating test for bottom-chrome clipping in the main window.
///
/// EXPECTED RED (pre-fix, macOS 27): `MainShellView` pins the sidebar/detail panes
/// to `NSWindow.contentRect(forFrameRect:)` height — the full window frame including
/// the title bar. On macOS 27 the root layout region SwiftUI proposes excludes the
/// ~52pt unified toolbar, so the over-tall shell is centered vertically: roughly
/// 26pt of every pane lands below the window's bottom edge. That clips the sidebar's
/// Recycle Bin bar and the Global Chats composer field out of reach.
///
/// Durable contract (any macOS): the bottom chrome — the sidebar's Recycle Bin
/// bar and the chat composer — must lie fully inside the window frame and be
/// hittable at the default window size, with no user resize.
@MainActor
final class WindowChromeLayoutUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testBottomChromeStaysWithinWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
        ]
        app.launch()
        app.activate()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window did not appear")

        // The shell mounts after the launch splash dismisses (~1.6s).
        let recycleBin = app.buttons["sidebar.recycleBin"]
        XCTAssertTrue(
            recycleBin.waitForExistence(timeout: 20),
            "Sidebar Recycle Bin button never appeared (shell not mounted?)"
        )

        // Global Chats is the default route; its composer sits at the pane's bottom.
        let composer = app.textFields["Message — type / for commands"]
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "Global Chats composer field never appeared"
        )

        // Let the post-splash layout settle before measuring geometry.
        Thread.sleep(forTimeInterval: 2)

        let windowFrame = window.frame
        let binFrame = recycleBin.frame
        let composerFrame = composer.frame

        // Frame containment (screen coordinates, y grows downward): an element whose
        // maxY exceeds the window's maxY is laid out past the window's bottom edge.
        XCTAssertLessThanOrEqual(
            binFrame.maxY, windowFrame.maxY + 0.5,
            "Recycle Bin bar extends below the window bottom — bin \(binFrame) vs window \(windowFrame)"
        )
        XCTAssertLessThanOrEqual(
            composerFrame.maxY, windowFrame.maxY + 0.5,
            "Chat composer extends below the window bottom — composer \(composerFrame) vs window \(windowFrame)"
        )

        // And both must be actually clickable, not merely laid out somewhere.
        XCTAssertTrue(recycleBin.isHittable, "Recycle Bin bar is not hittable")
        XCTAssertTrue(composer.isHittable, "Chat composer is not hittable")
    }
}
