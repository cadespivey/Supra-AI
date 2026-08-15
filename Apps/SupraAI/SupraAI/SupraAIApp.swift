import SwiftUI

struct SupraAIApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        Window("Supra AI", id: "main") {
            RootView()
                .environmentObject(environment)
        }
        // The splash is shown alone (the shell is swapped in afterward), and a bare
        // splash has no intrinsic size — pin the first-launch window so it opens at
        // full size instead of collapsing to the splash content.
        .defaultSize(width: 1100, height: 720)
        // This is the app's one primary workspace, not an optional utility
        // scene. Present it when no saved scene is restored and when the user
        // reopens a running, windowless app from the Dock.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            // Supra AI owns one process-wide workspace session. Replacing the
            // standard new-item group removes File > New Window and Command-N,
            // so visual selection can never diverge from the shared controller
            // bundle through a second main scene.
            CommandGroup(replacing: .newItem) {}

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
