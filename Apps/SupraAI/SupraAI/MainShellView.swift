import SupraDesignSystem
import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedRoute: AppRoute? = .globalChats

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedRoute)
        } detail: {
            detailView(for: selectedRoute ?? .globalChats)
                .frame(minWidth: 640, minHeight: 420)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task {
                                await environment.refreshRuntimeStatus()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh runtime status")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        SupraStatusBadge(environment.statusBadgeTitle)
                    }
                }
        }
    }

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route {
        case .globalChats:
            ContentUnavailableView("Global Chats", systemImage: "bubble.left.and.bubble.right")
        case .matters:
            ContentUnavailableView("Matters", systemImage: "folder.badge.gearshape")
        case .models:
            ContentUnavailableView("Models", systemImage: "cpu")
        case .tasks:
            ContentUnavailableView("Tasks", systemImage: "checklist")
        case .diagnostics:
            VStack(alignment: .leading, spacing: 12) {
                Label(environment.runtimeServiceState.rawValue, systemImage: "waveform.path.ecg")
                    .font(.title3)
                Text(environment.runtimeStatusMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .settings:
            ContentUnavailableView("Settings", systemImage: "gearshape")
        }
    }
}
