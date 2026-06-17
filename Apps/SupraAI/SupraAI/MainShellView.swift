import SupraDesignSystem
import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedRoute: AppRoute? = .globalChats

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selectedRoute,
                matters: environment.mattersController,
                onNewMatter: {
                    selectedRoute = .matters
                    environment.newMatterRequests += 1
                }
            )
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
            MattersView(controller: environment.mattersController, library: environment.modelLibrary)
        case .models:
            ModelsView(
                library: environment.modelLibrary,
                validation: environment.validationController,
                downloader: environment.modelDownloadController
            )
        case .diagnostics:
            DiagnosticsView(history: environment.validationHistory, validation: environment.validationController)
        case .settings:
            SettingsView(
                settings: environment.settingsController,
                documentSetup: environment.documentSetupController,
                embeddingDownloader: environment.embeddingDownloadController
            )
        }
    }
}
