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
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                matters: environment.mattersController,
                onNewMatter: { showNewMatter = true }
            )
            .frame(height: windowContentHeight, alignment: .top)
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
            .frame(height: windowContentHeight, alignment: .top)
        }
        .frame(minWidth: 880)
        .frame(height: windowContentHeight, alignment: .top)
        .background(WindowLiveResizeHeightReader(height: $windowContentHeight))
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

/// Publishes a finite initial window height and subsequent user-driven live
/// resizes only. Programmatic layout changes are deliberately ignored: feeding
/// every AppKit resize back into SwiftUI caused long pushed destinations to grow
/// the window, update the binding, and repeat while recentering vertically.
private struct WindowLiveResizeHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WindowLiveResizeHeightView {
        let view = WindowLiveResizeHeightView()
        configureHeightCallback(for: view)
        return view
    }

    func updateNSView(_ view: WindowLiveResizeHeightView, context: Context) {
        configureHeightCallback(for: view)
    }

    private func configureHeightCallback(for view: WindowLiveResizeHeightView) {
        view.onHeightChange = { newHeight in
            DispatchQueue.main.async {
                if height != newHeight { height = newHeight }
            }
        }
    }

    static func dismantleNSView(_ view: WindowLiveResizeHeightView, coordinator: ()) {
        view.stopObserving()
    }
}

private final class WindowLiveResizeHeightView: NSView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var liveResizeStartObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var liveResizeEndObserver: NSObjectProtocol?
    private var isUserResizing = false
    private var lastHeight: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        reportHeight(of: window, isInitialMeasurement: true)
        liveResizeStartObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isUserResizing = true
            }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUserResizing, let window else { return }
                self.reportHeight(of: window, isInitialMeasurement: false)
            }
        }
        liveResizeEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.reportHeight(of: window, isInitialMeasurement: false)
                self.isUserResizing = false
            }
        }
    }

    private func reportHeight(of window: NSWindow, isInitialMeasurement: Bool) {
        let currentHeight = window.contentRect(forFrameRect: window.frame).height
        let visibleScreenHeight = window.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 900
        guard currentHeight > 0 else { return }
        let boundedHeight: CGFloat
        if isInitialMeasurement, currentHeight > visibleScreenHeight {
            boundedHeight = min(800, max(420, visibleScreenHeight - 80))
        } else {
            boundedHeight = min(currentHeight, max(420, visibleScreenHeight))
        }
        guard boundedHeight != lastHeight else { return }
        lastHeight = boundedHeight
        onHeightChange?(boundedHeight)
    }

    func stopObserving() {
        for observer in [liveResizeStartObserver, resizeObserver, liveResizeEndObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        liveResizeStartObserver = nil
        resizeObserver = nil
        liveResizeEndObserver = nil
        isUserResizing = false
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
