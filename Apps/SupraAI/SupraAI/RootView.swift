import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        MainShellView()
            .task {
                await environment.refreshRuntimeStatus()
            }
    }
}
