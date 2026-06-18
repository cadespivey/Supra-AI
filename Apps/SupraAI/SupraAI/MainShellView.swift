import SupraDesignSystem
import SupraSessions
import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: SidebarSelection? = .route(.globalChats)
    @State private var showNewMatter = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                matters: environment.mattersController,
                onNewMatter: { showNewMatter = true }
            )
        } detail: {
            VStack(spacing: 0) {
                if environment.usingFallbackStore {
                    SupraWarningBanner(
                        .warning,
                        title: "Working in temporary storage",
                        message: "Supra AI couldn't open its database, so matters, chats, and documents created now won't be saved when you quit. Restart the app; if this keeps happening, check the disk space and permissions for your Application Support folder."
                    )
                    .padding([.horizontal, .top], 12)
                }
                detailView
                    .frame(minWidth: 640, minHeight: 420)
                    .toolbar { toolbar }
            }
        }
        .sheet(isPresented: $showNewMatter) {
            MatterEditorSheet(mode: .create, draft: MatterDraft()) { draft in
                if let created = try? environment.mattersController.createMatter(draft) {
                    environment.mattersController.select(matterID: created.id)
                    selection = .matter(created.id)
                }
            }
        }
    }

    /// Selecting a matter row also scopes the controller so its workspace (and the
    /// per-matter chat/research/document sub-controllers) are wired before render.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if case let .matter(id) = newValue {
                    environment.mattersController.select(matterID: id)
                }
            }
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .route(.globalChats) {
        case let .route(route):
            routeView(route)
        case let .matter(id):
            MatterDetailView(
                controller: environment.mattersController,
                library: environment.modelLibrary,
                queue: environment.documentQueue,
                settings: environment.settingsController,
                matterID: id
            )
        }
    }

    @ViewBuilder
    private func routeView(_ route: AppRoute) -> some View {
        switch route {
        case .globalChats:
            GlobalChatsView(controller: environment.chatController, library: environment.modelLibrary, settings: environment.settingsController)
        case .models:
            ModelsView(
                library: environment.modelLibrary,
                downloader: environment.modelDownloadController
            )
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView(
                settings: environment.settingsController,
                profile: environment.assistantProfileController,
                documentSetup: environment.documentSetupController,
                embeddingDownloader: environment.embeddingDownloadController
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // A quiet model-status indicator (only when a model isn't loaded), then the
        // consistent action buttons. Replaces the old always-on "Limited Mode" pill.
        ToolbarItemGroup(placement: .primaryAction) {
            ModelStatusToolbarItem(library: environment.modelLibrary)
            Button {
                Task { await environment.refreshRuntimeStatus() }
            } label: {
                Label("Refresh runtime status", systemImage: "arrow.clockwise")
            }
            .help("Refresh runtime status")
            Button {
                showNewMatter = true
            } label: {
                Label("New Matter", systemImage: "folder.badge.plus")
            }
            .help("New Matter")
        }
    }
}

/// Hosts a matter's workspace, resolving the matter from the (observed) controller
/// so it re-renders once the matter's scoped sub-controllers are wired.
private struct MatterDetailView: View {
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    let queue: DocumentProcessingQueue
    @ObservedObject var settings: SettingsController
    let matterID: String

    var body: some View {
        if let matter = controller.matters.first(where: { $0.id == matterID }) {
            MatterWorkspaceView(controller: controller, library: library, queue: queue, settings: settings, matter: matter)
        } else {
            ContentUnavailableView(
                "Select a Matter",
                systemImage: "folder",
                description: Text("Choose or create a matter to open its workspace.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A subtle toolbar status shown only when chat isn't ready. Driven by the same
/// source of truth as the chat composer (ModelLibrary.loadState), so the badge and
/// the chat gate can never disagree.
private struct ModelStatusToolbarItem: View {
    @ObservedObject var library: ModelLibrary

    var body: some View {
        switch library.loadState {
        case .loaded:
            EmptyView()
        case .idle:
            label("No model loaded", systemImage: "cpu", color: .secondary)
        case .loading:
            label("Loading model…", systemImage: "hourglass", color: .secondary)
        case .failed:
            label("Model failed to load", systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func label(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
            .help(title)
    }
}
