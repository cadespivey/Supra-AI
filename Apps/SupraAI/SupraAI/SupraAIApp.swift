import Foundation
import SwiftUI

struct SupraAIApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        Window("Supra AI", id: "main") {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(Self.uiTestColorScheme)
#if DEBUG
                .overlay(alignment: .topLeading) {
                    if ProcessInfo.processInfo.arguments.contains("-uiTestMode") {
                        UITestAppearanceProbe()
                    }
                }
#endif
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

    /// `AppleInterfaceStyle=Light` does not override a dark macOS host reliably;
    /// an explicit DEBUG-only root preference makes the visual qualification
    /// matrix exercise both appearances instead of producing mislabeled copies.
    private static var uiTestColorScheme: ColorScheme? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "-uiTestAppearance"),
              arguments.indices.contains(marker + 1) else { return nil }
        switch arguments[marker + 1].lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
#else
        nil
#endif
    }
}

#if DEBUG
private struct UITestAppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(colorScheme == .dark ? "Dark" : "Light")
            .accessibilityIdentifier("uiTest.appearance")
    }
}
#endif
