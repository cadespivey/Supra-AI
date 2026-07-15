import AppKit
import SupraDesignSystem
import SupraSessions
import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: SidebarSelection? = .route(.globalChats)
    @State private var showNewMatter = false
    @State private var windowContentHeight: CGFloat = 720

    var body: some View {
        // Top alignment matters: while the measured height lags the live
        // proposal (first pass after mount, enlarging live resizes), the
        // stale-shorter shell must hug the toolbar edge, not center with both
        // edges adrift.
        ZStack(alignment: .top) {
            // Measures the height SwiftUI actually proposes for the window's
            // content region, which is what the shell's cap below must match
            // exactly. Reading NSWindow metrics instead (the previous approach)
            // breaks whenever AppKit's window arithmetic and SwiftUI's proposal
            // disagree: on macOS 27 the proposed region excludes the unified
            // toolbar while contentRect(forFrameRect:) still spans the full
            // frame, so the over-tall shell was centered and its bottom ~26pt —
            // the Recycle Bin bar and chat composer — hung below the window's
            // bottom edge. The proposal is also updated on programmatic resizes
            // (zoom, tiling), which the notification-based reader deliberately
            // ignored. It never depends on content size, so the original
            // feedback loop (tall pushed destinations growing the window, which
            // grew the content, which grew the window) cannot restart.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateWindowContentHeight(proxy.size.height) }
                            .onChange(of: proxy.size.height) { _, newHeight in
                                updateWindowContentHeight(newHeight)
                            }
                    }
                )
            // The columns are NOT pinned to the measured height: each split-view
            // column is its own hosting environment with its own safe-area
            // accounting (on macOS 27 the sidebar column adds a ~52pt toolbar
            // inset internally), so a root-height frame inside a column can
            // exceed the column's real region — SwiftUI resolves that by
            // centering, which pushed the Recycle Bin bar ~26pt below the
            // window bottom even while the outer shell measured flush. Greedy
            // fills resolve to each column's own proposal exactly; only the
            // ROOT frame below needs the pinned ideal/max, and that alone
            // keeps content from growing the window.
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 880)
            // Flexible below the measured height, never above it: if the region
            // shrinks (the toolbar registers a beat after the shell mounts), the
            // shell follows in the same layout pass instead of forcing the window
            // to grow — a rigid height here made the window gain the toolbar's
            // 20pt every launch, and clipped again once the screen blocked the
            // growth. The pinned ideal keeps tall pushed destinations from
            // growing the window; the cap keeps the shell from ever exceeding
            // the region (which SwiftUI resolves by centering, i.e. clipping).
            .frame(minHeight: 420, idealHeight: windowContentHeight, maxHeight: windowContentHeight, alignment: .top)
        }
        .onReceive(NotificationCenter.default.publisher(for: .supraNavigateToRoute)) { note in
            if let route = note.object as? AppRoute { selection = .route(route) }
        }
        #if DEBUG
        .onAppear { applyUITestInitialSelection() }
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

    /// Pins the shell to the proposed layout height, so the panes end exactly at
    /// the window's bottom edge. The 420pt floor mirrors the detail pane's
    /// minimum, guarding against transient degenerate proposals mid-teardown.
    private func updateWindowContentHeight(_ proposedHeight: CGFloat) {
        guard proposedHeight > 0 else { return }
        let height = max(420, proposedHeight)
        if windowContentHeight != height { windowContentHeight = height }
    }

    /// Selecting a matter row also scopes the controller so its workspace (and the
    /// per-matter chat/research/document sub-controllers) are wired before render.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { newValue in
                if case let .matter(id) = newValue {
                    selectMatter(id)
                } else {
                    selection = newValue
                }
            }
        )
    }

    /// Clears the outgoing editor and scopes every per-matter controller before
    /// the workspace is rendered. DEBUG launch routing calls this same path so UI
    /// tests do not depend on version-specific synthetic List-selection clicks.
    private func selectMatter(_ id: String) {
        // The Global Chats composer auto-focuses at launch. If its edit session
        // survives the transition, the first click in a matter workspace merely
        // ends that session instead of activating the intended control.
        NSApp.keyWindow?.makeFirstResponder(nil)
        environment.mattersController.select(matterID: id)
        selection = .matter(id)
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
                selectMatter(id)
            }
        case "tab":
            if pieces.count > 1 {
                NotificationCenter.default.post(name: .supraDebugSelectMatterTab, object: pieces[1])
            }
        case "output":
            if pieces.count > 1 {
                NotificationCenter.default.post(name: .supraDebugOpenOutput, object: pieces[1])
            }
        default:
            break
        }
    }

    private func applyUITestInitialSelection() {
        guard AppEnvironment.isUITestMode else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let routeFlag = arguments.firstIndex(of: "-uiTestInitialRoute"),
           arguments.indices.contains(routeFlag + 1),
           let route = AppRoute(rawValue: arguments[routeFlag + 1]) {
            selection = .route(route)
        } else if arguments.contains("-uiTestSelectFirstMatter"),
                  let id = environment.mattersController.matters.first?.id {
            selectMatter(id)
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
                backup: environment.backupController,
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
