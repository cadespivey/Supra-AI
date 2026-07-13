import AppKit
import SwiftUI

@main
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

    func applicationShouldRestoreState(_ app: NSApplication) -> Bool {
        !shouldResetWindowRestorationForUITest
    }

    func applicationShouldSaveState(_ app: NSApplication) -> Bool {
        !shouldResetWindowRestorationForUITest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleFreshUITestWindowIfNeeded(notification.object as? NSApplication)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleFreshUITestWindowIfNeeded(notification.object as? NSApplication)
    }

    private func scheduleFreshUITestWindowIfNeeded(_ app: NSApplication?) {
        guard shouldResetWindowRestorationForUITest,
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
        }
    }

    private var shouldResetWindowRestorationForUITest: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestResetWindowRestoration")
#else
        false
#endif
    }
}
