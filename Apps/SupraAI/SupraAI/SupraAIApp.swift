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
    }
}
