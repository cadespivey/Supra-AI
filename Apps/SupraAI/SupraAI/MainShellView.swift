import AppKit
import SupraDesignSystem
import SupraSessions
import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: SidebarSelection? = .route(.globalChats)
    @State private var setupNavigationRequest: SetupNavigationRequest?
    @State private var showNewMatter = false
    @State private var windowContentHeight: CGFloat = 720
#if DEBUG
    @State private var setupNavigationFixture: SetupNavigationUITestFixture?
    @State private var isShowingSetupNavigationFixture = false
#endif

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
#if DEBUG
        .overlay(alignment: .topLeading) {
            windowSessionLedgerView
        }
#endif
        .onReceive(NotificationCenter.default.publisher(for: .supraNavigateToRoute)) { note in
            if let route = note.object as? AppRoute { selectRoute(route) }
        }
        .onChange(of: environment.mattersController.selectedMatterID) { _, matterID in
            // SidebarView refreshes its matter list on appearance. The controller
            // historically auto-selected the first matter during that refresh,
            // even while this window visibly showed a global route. In the one-
            // window model, a non-matter destination owns no hidden matter scope.
            guard matterID != nil else { return }
            if case .matter = selection { return }
            environment.mattersController.select(matterID: nil)
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
                    environment.mattersController.select(matterID: nil)
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
        selection = .matter(id)
        environment.mattersController.select(matterID: id)
    }

    /// A global route and a matter-scoped controller are mutually exclusive in
    /// the supported single window. Go-menu and setup navigation use this same
    /// targeted path as the sidebar.
    private func selectRoute(_ route: AppRoute) {
        selection = .route(route)
        environment.mattersController.select(matterID: nil)
    }

    @ViewBuilder
    private var detailView: some View {
#if DEBUG
        if let fixture = setupNavigationFixture,
           isShowingSetupNavigationFixture {
            SetupBlockerFixtureView(
                fixture: fixture,
                library: environment.modelLibrary,
                documentSetup: environment.documentSetupController,
                settings: environment.settingsController,
                backup: environment.backupController,
                onOpenSetup: beginSetupNavigation
            )
        } else {
            standardDetailView
        }
#else
        standardDetailView
#endif
    }

    @ViewBuilder
    private var standardDetailView: some View {
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
                selectRoute(route)
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
        if let fixture = SetupNavigationUITestFixture(arguments: arguments) {
            setupNavigationFixture = fixture
            isShowingSetupNavigationFixture = true
            setupNavigationRequest = nil
            environment.mattersController.select(matterID: nil)
        } else if let routeFlag = arguments.firstIndex(of: "-uiTestInitialRoute"),
           arguments.indices.contains(routeFlag + 1),
           let route = AppRoute(rawValue: arguments[routeFlag + 1]) {
            selectRoute(route)
        } else if arguments.contains("-uiTestSelectFirstMatter"),
                  let id = environment.mattersController.matters.first?.id {
            selectMatter(id)
        }
    }

    @ViewBuilder
    private var windowSessionLedgerView: some View {
        if let wire = WindowSessionLedgerWire(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            Text("Window session ledger")
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .clipped()
                .accessibilityLabel("Window session ledger")
                .accessibilityValue(windowSessionLedgerValue(wire: wire))
                .accessibilityIdentifier("window.session.ledger")
        }
    }

    private func windowSessionLedgerValue(wire: WindowSessionLedgerWire) -> String {
        let route: String
        let visibleMatter: String
        switch selection ?? .route(.globalChats) {
        case let .route(selectedRoute):
            route = selectedRoute.rawValue
            visibleMatter = "none"
        case let .matter(matterID):
            route = "matter"
            visibleMatter = matterID
        case .recycleBin:
            route = "recycleBin"
            visibleMatter = "none"
        }
        let controllerMatter = environment.mattersController.selectedMatterID ?? "none"
        return "ledger=\(wire.ledgerID)|route=\(route)|visibleMatter=\(visibleMatter)|controllerMatter=\(controllerMatter)"
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
                embeddingDownloader: environment.embeddingDownloadController,
                setupNavigationRequest: setupNavigationRequest,
                onReturnFromSetup: returnFromSetup
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
                parseExemplar: environment.parseFirmStyleExemplar,
                setupNavigationRequest: setupNavigationRequest,
                onReturnFromSetup: returnFromSetup
            )
        }
    }

    /// Opens the precise setup destination carried by the typed request. The
    /// originating matter and work inputs remain on the request until the user
    /// explicitly returns; no current-matter or default-route substitution is
    /// permitted here.
    private func beginSetupNavigation(_ request: SetupNavigationRequest) {
        setupNavigationRequest = request
#if DEBUG
        isShowingSetupNavigationFixture = false
#endif
        switch request.navigationTarget {
        case .aiSetup:
            selectRoute(.models)
        case .settings:
            selectRoute(.settings)
        }
    }

    /// Restores only the work context that opened the active setup request.
    /// A stale return control cannot redirect a newer request.
    private func returnFromSetup(_ request: SetupNavigationRequest) {
        guard setupNavigationRequest == request else { return }
        setupNavigationRequest = nil
#if DEBUG
        if setupNavigationFixture?.request == request {
            isShowingSetupNavigationFixture = true
            return
        }
#endif
        switch request.returnContext.returnDestination {
        case let .matterTask(matterID, _):
            selectMatter(matterID)
        }
    }

}

/// Keeps return navigation consistent across AI Setup and Settings. The action
/// carries the complete typed request back to the shell rather than rebuilding
/// a matter or task from global state.
struct SetupNavigationReturnBar: View {
    let request: SetupNavigationRequest
    let onReturn: (SetupNavigationRequest) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup for blocked work")
                    .font(.supraHeadline)
                Text("Your matter, selected sources, and task checkpoint are preserved.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Return to Draft Motion") {
                onReturn(request)
            }
            .accessibilityIdentifier("setup.navigation.return")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Stable focus surface for a setup requirement row. Applying the identifier
/// and keyboard focus to the same element lets assistive technology confirm
/// that navigation reached the requested correction, not merely its screen.
struct SetupRequirementFocusModifier: ViewModifier {
    let identifier: String
    let focusedIdentifier: FocusState<String?>.Binding

    func body(content: Content) -> some View {
        content
            .id(identifier)
            .accessibilityIdentifier(identifier)
            .focusable()
            .focused(focusedIdentifier, equals: identifier)
    }
}

extension View {
    func setupRequirementFocus(
        _ identifier: String,
        focusedIdentifier: FocusState<String?>.Binding
    ) -> some View {
        modifier(
            SetupRequirementFocusModifier(
                identifier: identifier,
                focusedIdentifier: focusedIdentifier
            )
        )
    }
}

#if DEBUG
/// Exact launch-only identity for T-WINDOW-01. Every field is parsed once from
/// a unique nonempty argument; the app never substitutes a current matter or a
/// default ledger identity when the wire is malformed.
@MainActor
struct WindowSessionLedgerWire: Equatable {
    let ledgerID: String
    let matterID: String
    let matterName: String

    init?(arguments: [String]) {
        func exactValue(after flag: String) -> String? {
            let matches = arguments.indices.filter { arguments[$0] == flag }
            guard matches.count == 1,
                  let index = matches.first,
                  arguments.indices.contains(index + 1) else { return nil }
            let value = arguments[index + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard AppEnvironment.isUITestMode,
              let ledgerID = exactValue(after: "-uiTestWindowLedgerID"),
              let matterID = exactValue(after: "-uiTestWindowMatterID"),
              let matterName = exactValue(after: "-uiTestWindowMatterName") else {
            return nil
        }
        self.ledgerID = ledgerID
        self.matterID = matterID
        self.matterName = matterName
    }
}

private struct SetupNavigationUITestFixture: Equatable {
    let request: SetupNavigationRequest
    let input: String

    init?(arguments: [String]) {
        func exactValue(after flag: String) -> String? {
            let matches = arguments.indices.filter { arguments[$0] == flag }
            guard matches.count == 1,
                  let index = matches.first,
                  arguments.indices.contains(index + 1) else { return nil }
            let value = arguments[index + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard let requirementID = exactValue(after: "-uiTestSetupRequirement"),
              let requirement = SetupRequirement(id: requirementID),
              let requestID = exactValue(after: "-uiTestSetupRequestID"),
              let matterID = exactValue(after: "-uiTestSetupMatterID"),
              let intentRaw = exactValue(after: "-uiTestSetupIntent"),
              let intent = WorkIntent(rawValue: intentRaw),
              let sourceSetID = exactValue(after: "-uiTestSetupSourceSetID"),
              let sourceSetVersionRaw = exactValue(after: "-uiTestSetupSourceSetVersion"),
              let sourceSetVersion = Int(sourceSetVersionRaw),
              sourceSetVersion > 0,
              let authorityPacketID = exactValue(after: "-uiTestSetupAuthorityPacketID"),
              let authorityPacketVersionRaw = exactValue(after: "-uiTestSetupAuthorityPacketVersion"),
              let authorityPacketVersion = Int(authorityPacketVersionRaw),
              authorityPacketVersion > 0,
              let checkpointID = exactValue(after: "-uiTestSetupCheckpointID"),
              let input = exactValue(after: "-uiTestSetupInput") else { return nil }

        let context = WorkContext(
            matterID: matterID,
            intent: intent,
            sourceSet: VersionedWorkReference(id: sourceSetID, version: sourceSetVersion),
            authorityPacket: VersionedWorkReference(
                id: authorityPacketID,
                version: authorityPacketVersion
            ),
            workProduct: nil,
            returnDestination: .matterTask(matterID: matterID, intent: intent),
            checkpointID: checkpointID
        )
        self.request = SetupNavigationRequest(
            id: requestID,
            requirement: requirement,
            returnContext: context
        )
        self.input = input
    }
}

private struct SetupBlockerFixtureView: View {
    let fixture: SetupNavigationUITestFixture
    @ObservedObject var library: ModelLibrary
    @ObservedObject var documentSetup: DocumentIntelligenceSetupController
    @ObservedObject var settings: SettingsController
    @ObservedObject var backup: BackupController
    let onOpenSetup: (SetupNavigationRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Draft Motion")
                .font(.title2.weight(.semibold))
            Text("This synthetic task verifies that a setup detour preserves the exact work in progress.")
                .foregroundStyle(.secondary)

            Text(contextSummary)
                .font(.supraCaption.monospaced())
                .textSelection(.enabled)
                .accessibilityLabel(contextSummary)
                .accessibilityIdentifier("setup.fixture.context")

            Text(fixture.input)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Preserved input")
                .accessibilityValue(fixture.input)
                .accessibilityIdentifier("setup.fixture.input")

            VStack(alignment: .leading, spacing: 10) {
                Label(blockerTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.supraHeadline)
                    .foregroundStyle(.orange)
                Text(blockerDetail)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(actionTitle) {
                        onOpenSetup(fixture.request)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityValue(blockerAccessibilityValue)
                    .accessibilityIdentifier(
                        "setup.blocker.action.\(fixture.request.requirement.id)"
                    )
                    Spacer()
                    Button("Draft Motion") {}
                        .disabled(!isRequirementSatisfied)
                        .accessibilityIdentifier("setup.fixture.blockedAction")
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.orange.opacity(0.35), lineWidth: 1)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contextSummary: String {
        let context = fixture.request.returnContext
        var parts = [
            "request=\(fixture.request.id)",
            "matter=\(context.matterID)",
            "intent=\(context.intent.rawValue)",
        ]
        if let sourceSet = context.sourceSet {
            parts.append("sourceSet=\(sourceSet.id)@\(sourceSet.version)")
        }
        if let authorityPacket = context.authorityPacket {
            parts.append("authorityPacket=\(authorityPacket.id)@\(authorityPacket.version)")
        }
        if let workProduct = context.workProduct {
            parts.append("workProduct=\(workProduct.id)@\(workProduct.version)")
        }
        if let checkpointID = context.checkpointID {
            parts.append("checkpoint=\(checkpointID)")
        }
        return parts.joined(separator: " | ")
    }

    private var actionTitle: String {
        switch fixture.request.requirement {
        case .localAssistant:
            "Set Up Local Assistant"
        case .documentSearch:
            "Set Up Document Search"
        case .providerConnection:
            "Connect CourtListener"
        case .backupDestination:
            "Set Up Backup"
        }
    }

    private var blockerTitle: String {
        switch fixture.request.requirement {
        case .localAssistant:
            "Local assistant required"
        case .documentSearch:
            "Document search setup required"
        case .providerConnection:
            "CourtListener connection required"
        case .backupDestination:
            "Backup destination required"
        }
    }

    private var blockerDetail: String {
        "Draft Motion is unavailable until this requirement is satisfied. Open the exact setup row, complete it, then return to this preserved task."
    }

    private var blockerAccessibilityValue: String {
        "\(blockerTitle). Draft Motion is unavailable. Opens the required setup row."
    }

    private var isRequirementSatisfied: Bool {
        switch fixture.request.requirement {
        case let .localAssistant(role):
            switch role {
            case .drafting:
                library.resolvedModel(for: .drafting) != nil
            }
        case let .documentSearch(step):
            switch step {
            case .embeddingModel:
                documentSetup.selectedEmbeddingModel != nil
                    && documentSetup.embeddingTestPassed
            case .extractionToolchain:
                documentSetup.toolchain?.meetsMinimumForSetup == true
            case .storage:
                documentSetup.storageInitialized
            }
        case let .providerConnection(provider):
            switch provider {
            case .courtListener:
                settings.hasCourtListenerToken
            }
        case .backupDestination:
            backup.hasDestination
        }
    }
}
#endif

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
