import AppKit
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .supraNavigateToRoute)) { note in
            if let route = note.object as? AppRoute { selection = .route(route) }
        }
        #if DEBUG
        // Sandboxes (the app's and any automation harness's) exclude each
        // other's filesystems, so the DEBUG automation channel rides
        // distributed notifications instead of a command file.
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("SupraDebugNav"))) { note in
            handleDebugNavCommand(note.object as? String)
        }
        #endif
        .sheet(isPresented: $showNewMatter) {
            MatterEditorSheet(
                mode: .create,
                draft: MatterDraft(),
                clientDirectory: environment.mattersController.clientDirectory(),
                practiceAreaDirectory: environment.mattersController.practiceAreaDirectory()
            ) { draft in
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
                    // Clear any control that still holds keyboard focus — chiefly the
                    // Global Chats composer, which auto-focuses at launch. Left focused,
                    // its text-field edit session lingers into the matter workspace and
                    // eats the first click on a matter tab (finalizing the edit instead
                    // of switching tabs); the second click then works. Dropping first
                    // responder here means the first tab click lands on the first try.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { @MainActor in
                        environment.mattersController.select(matterID: id)
                    }
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
        case .recycleBin:
            RecycleBinView(
                controller: environment.recycleBinController,
                matters: environment.mattersController,
                chats: environment.chatController
            )
        }
    }

    #if DEBUG
    /// DEBUG-only automation commands ("route <name>" / "matter-first" /
    /// "tab <Tab>[+planner]") — synthetic mouse clicks don't register on every
    /// machine, so UI verification drives navigation this way. Compiled out of
    /// release builds.
    private func handleDebugNavCommand(_ command: String?) {
        guard let command else { return }
        let pieces = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch pieces.first {
        case "route":
            if pieces.count > 1, let route = AppRoute(rawValue: pieces[1]) {
                selection = .route(route)
            }
        case "matter-first":
            if let id = environment.mattersController.matters.first?.id {
                environment.mattersController.select(matterID: id)
                selection = .matter(id)
            }
        case "tab":
            if pieces.count > 1 {
                NotificationCenter.default.post(name: .supraDebugSelectMatterTab, object: pieces[1])
            }
        default:
            break
        }
    }
    #endif

    @ViewBuilder
    private func routeView(_ route: AppRoute) -> some View {
        switch route {
        case .globalChats:
            GlobalChatsView(
                controller: environment.chatController,
                library: environment.modelLibrary,
                settings: environment.settingsController,
                matters: environment.mattersController
            )
        case .scratchpad:
            ScratchPadView(
                controller: environment.scratchPadController,
                billing: environment.billingDraftController,
                billingSettings: environment.billingSettingsController,
                library: environment.modelLibrary
            )
        case .models:
            ModelsView(
                library: environment.modelLibrary,
                downloader: environment.modelDownloadController,
                documentSetup: environment.documentSetupController,
                embeddingDownloader: environment.embeddingDownloadController
            )
        case .publicRecords:
            PublicRecordsView(controller: environment.publicRecordsController)
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView(
                settings: environment.settingsController,
                profile: environment.assistantProfileController,
                update: environment.sparkleUpdater,
                billing: environment.billingSettingsController,
                firmStyle: environment.firmStyleProfileController,
                parseExemplar: environment.parseFirmStyleExemplar
            )
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
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(foregroundStyle)
                // Even, square padding around the glyph (the old 30×26 left more
                // horizontal than vertical room, which read as off-center).
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((role == .destructive ? Color.red : Color.primary).opacity(isHovered && isEnabled ? 0.10 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .help(title)
    }

    private var foregroundStyle: Color {
        role == .destructive ? .red : .primary
    }
}
