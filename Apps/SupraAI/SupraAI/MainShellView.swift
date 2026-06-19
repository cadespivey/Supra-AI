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
        ToolbarItem(placement: .navigation) {
            SupraToolbarIconButton("New Matter", systemImage: "case") {
                showNewMatter = true
            }
        }

        // A compact runtime indicator plus the consistent runtime action.
        ToolbarItemGroup(placement: .primaryAction) {
            ModelStatusToolbarItem(library: environment.modelLibrary)
            SupraToolbarIconButton("Refresh Runtime Status", systemImage: "arrow.clockwise") {
                Task { await environment.refreshRuntimeStatus() }
            }
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

/// A subtle toolbar status for the runtime's currently loaded model.
private struct ModelStatusToolbarItem: View {
    @ObservedObject var library: ModelLibrary

    var body: some View {
        switch library.loadState {
        case .loaded:
            label("Runtime model loaded", systemImage: "checkmark.circle.fill", color: .green)
        case .idle:
            label("Runtime idle", systemImage: "cpu", color: .secondary)
        case .loading:
            label("Loading model…", systemImage: "hourglass", color: .secondary)
        case .failed:
            label("Model failed to load", systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func label(_ title: String, systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .accessibilityLabel(title)
            .help(title)
    }
}

struct SupraToolbarIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14.5, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(foregroundStyle)
                .frame(width: 28, height: 28)
                .background(backgroundFill, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(isHovered && isEnabled ? 0.18 : 0.10), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .help(title)
    }

    private var backgroundFill: Color {
        Color.secondary.opacity(isHovered && isEnabled ? 0.18 : 0.10)
    }

    private var foregroundStyle: Color {
        role == .destructive ? .red : .primary
    }
}
