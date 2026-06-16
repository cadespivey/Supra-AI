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
            GlobalChatsView(controller: environment.chatController, library: environment.modelLibrary)
        case .matters:
            ContentUnavailableView("Matters", systemImage: "folder.badge.gearshape")
        case .models:
            ModelsView(library: environment.modelLibrary, validation: environment.validationController)
        case .tasks:
            ContentUnavailableView("Tasks", systemImage: "checklist")
        case .diagnostics:
            DiagnosticsView(history: environment.validationHistory, validation: environment.validationController)
        case .settings:
            ContentUnavailableView("Settings", systemImage: "gearshape")
        }
    }
}
