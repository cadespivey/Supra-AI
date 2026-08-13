import AppKit
import SwiftUI

struct SupraAIApp: App {
    @NSApplicationDelegateAdaptor(SupraApplicationDelegate.self) private var applicationDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        // The splash is shown alone (the shell is swapped in afterward), and a bare
        // splash has no intrinsic size — pin the first-launch window so it opens at
        // full size instead of collapsing to the splash content.
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Go menu: keyboard navigation to every sidebar destination
            // (Mail/Finder convention). MainShellView owns the selection, so
            // the menu posts and the shell observes.
            CommandMenu("Go") {
                ForEach(Array(AppRoute.allCases.enumerated()), id: \.element) { index, route in
                    Button(route.title) {
                        NotificationCenter.default.post(name: .supraNavigateToRoute, object: route)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

@MainActor
private final class SupraApplicationDelegate: NSObject, NSApplicationDelegate {
    private var freshWindowOpenScheduled = false
#if DEBUG
    private var uiTestWindowWidthScheduled = false
    private var uiTestWindowWidthApplied = false
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = notification.object as? NSApplication
        scheduleFreshUITestWindowIfNeeded(app)
        scheduleUITestWindowWidthIfNeeded(app)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let app = notification.object as? NSApplication
        scheduleFreshUITestWindowIfNeeded(app)
        scheduleUITestWindowWidthIfNeeded(app)
    }

    private func scheduleFreshUITestWindowIfNeeded(_ app: NSApplication?) {
        guard shouldEnsureFreshUITestWindow,
              let app,
              app.windows.isEmpty,
              !freshWindowOpenScheduled else { return }
        freshWindowOpenScheduled = true
        DispatchQueue.main.async { [weak self, weak app] in
            guard let self, let app else { return }
            self.freshWindowOpenScheduled = false
            guard app.windows.isEmpty,
                  let item = app.mainMenu?
                    .item(withTitle: "File")?
                    .submenu?
                    .item(withTitle: "New Window"),
                  let action = item.action else { return }
            app.sendAction(action, to: item.target, from: item)
            self.scheduleUITestWindowWidthIfNeeded(app)
        }
    }

    private func scheduleUITestWindowWidthIfNeeded(_ app: NSApplication?) {
#if DEBUG
        guard let requestedWidth = requestedUITestWindowWidth,
              let app,
              !uiTestWindowWidthApplied,
              !uiTestWindowWidthScheduled else { return }
        uiTestWindowWidthScheduled = true
        DispatchQueue.main.async { [weak self, weak app] in
            guard let self, let app else { return }
            self.uiTestWindowWidthScheduled = false
            guard !self.uiTestWindowWidthApplied,
                  let window = app.windows.first(where: \.canBecomeMain) else { return }
            var frame = window.frame
            frame.origin.x += (frame.width - requestedWidth) / 2
            frame.size.width = requestedWidth
            window.setFrame(frame, display: true)
            self.uiTestWindowWidthApplied = true
        }
#endif
    }

    private var requestedUITestWindowWidth: CGFloat? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard AppEnvironment.isUITestMode,
              let marker = arguments.firstIndex(of: "-uiTestWindowWidth"),
              arguments.indices.contains(marker + 1),
              let width = Double(arguments[marker + 1]),
              width.isFinite,
              width > 0 else { return nil }
        return CGFloat(width)
#else
        nil
#endif
    }

    private var shouldEnsureFreshUITestWindow: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestEnsureFreshWindow")
#else
        false
#endif
    }
}
