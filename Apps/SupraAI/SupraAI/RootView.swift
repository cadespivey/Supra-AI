import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showSplash = true

    var body: some View {
        MainShellView()
            .task { await environment.bootstrap() }
            .overlay {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(nanoseconds: 1_600_000_000)
                            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
                        }
                }
            }
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
