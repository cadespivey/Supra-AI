import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showSplash = true

    var body: some View {
        ZStack {
            // The main shell is a NavigationSplitView whose sidebar is backed by an
            // AppKit NSVisualEffectView (vibrancy). That material renders straight to
            // the window and ignores SwiftUI layer opacity, so overlaying the splash
            // on top of a still-mounted shell let the sidebar/chrome bleed through.
            // Swapping (shell absent until the splash dismisses) removes the vibrancy
            // source entirely; the transitions still cross-fade the reveal.
            if !showSplash {
                MainShellView()
                    .transition(.opacity)
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
                    }
            }
        }
        .background(showSplash ? BrandColors.navy : Color.clear)
        .task { await environment.bootstrap() }
    }
}

/// Brand palette: legal "ink & gold". The § (section symbol) is the mark.
enum BrandColors {
    static let navy = Color(red: 0x0B / 255, green: 0x23 / 255, blue: 0x40 / 255)
    static let gold = Color(red: 0xC9 / 255, green: 0xA2 / 255, blue: 0x4B / 255)
}

/// Launch splash: the § mark, the name, and the "See Supra" tagline.
struct SplashView: View {
    var body: some View {
        ZStack {
            BrandColors.navy.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("§")
                    .font(.system(size: 104, weight: .semibold, design: .serif))
                    .foregroundStyle(BrandColors.gold)
                VStack(spacing: 6) {
                    Text("Supra AI")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("Secure legal AI without compromise.")
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("See Supra.")
                        .font(.system(size: 15, design: .serif).italic())
                        .foregroundStyle(BrandColors.gold.opacity(0.92))
                }
            }
        }
    }
}
