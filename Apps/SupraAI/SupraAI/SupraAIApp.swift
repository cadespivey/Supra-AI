import SwiftUI

@main
struct SupraAIApp: App {
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
