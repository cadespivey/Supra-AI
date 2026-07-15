import AppKit
import SupraCore
import SupraSessions
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("supra.remediationNoticeV057Acknowledged") private var remediationNoticeAcknowledged = false
    @State private var showingRemediationNotice = false

    @ViewBuilder
    var body: some View {
#if DEBUG
        if let scenario = Self.runtimeXPCIntegrationScenario {
            RuntimeXPCIntegrationView(scenario: scenario)
        } else {
            applicationRoot
        }
#else
        applicationRoot
#endif
    }

    private var applicationRoot: some View {
        ZStack {
            // The main shell is a NavigationSplitView whose sidebar is backed by an
            // AppKit NSVisualEffectView (vibrancy). That material renders straight to
            // the window and ignores SwiftUI layer opacity, so overlaying the splash
            // on top of a still-mounted shell let the sidebar/chrome bleed through.
            // Swapping (shell absent until the splash dismisses) removes the vibrancy
            // source entirely; the transitions still cross-fade the reveal.
            //
            // The splash-visible flag lives on AppEnvironment (not @State here) so it
            // survives a window close/reopen while the process keeps running — the
            // splash then shows only on a true cold launch, not every Dock re-open.
            if !environment.isShowingSplash {
                if let recoveryState = environment.databaseRecoveryState {
                    DatabaseRecoveryView(state: recoveryState)
                        .transition(.opacity)
                } else if environment.shouldShowOnboarding {
                    FirstRunOnboardingView(
                        library: environment.modelLibrary,
                        downloader: environment.modelDownloadController,
                        embeddingDownloader: environment.embeddingDownloadController,
                        documentSetup: environment.documentSetupController,
                        onComplete: { environment.markOnboardingComplete() }
                    )
                    .transition(.opacity)
                } else {
                    MainShellView()
                        .transition(.opacity)
                }
            }

            if environment.isShowingSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeOut(duration: 0.45)) { environment.isShowingSplash = false }
                    }
            }
        }
        .background(environment.isShowingSplash ? BrandColors.navy : Color.clear)
        .task { await environment.bootstrap() }
        .onChange(of: environment.isShowingSplash) { _, showingSplash in
            if !showingSplash,
               environment.remediationRecoverySummary.pendingCount > 0,
               !remediationNoticeAcknowledged {
                showingRemediationNotice = true
            }
        }
        .alert("Review previous generated work", isPresented: $showingRemediationNotice) {
            Button("Continue") { remediationNoticeAcknowledged = true }
        } message: {
            Text(remediationNoticeMessage)
        }
    }

#if DEBUG
    private static var runtimeXPCIntegrationScenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-runtimeXPCIntegrationMode"),
              let marker = arguments.firstIndex(of: "-runtimeXPCScenario"),
              arguments.indices.contains(marker + 1) else {
            return nil
        }
        return arguments[marker + 1]
    }
#endif

    private var remediationNoticeMessage: String {
        let summary = environment.remediationRecoverySummary
        let outputs = summary.pendingByKind[.legacyStructuredOutput, default: 0]
        let drafts = summary.pendingByKind[.legacyDraftArtifact, default: 0]
        let billing = summary.pendingByKind[.multiMatterBillingDraft, default: 0]
        return "A security update changed how generated work is verified. \(outputs) saved output(s), \(drafts) draft artifact(s), and \(billing) multi-matter billing draft(s) need review. Nothing was deleted. Affected screens identify the item and provide reverify, regenerate, or confirmation actions."
    }
}

private struct DatabaseRecoveryView: View {
    let state: DatabaseRecoveryState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.title2.weight(.semibold))
            Text(state.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620)

            HStack(spacing: 12) {
                if let snapshotURL = state.snapshotURL {
                    Button("Show Recovery Snapshot") {
                        NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
                    }
                    .accessibilityHint("Opens Finder with the verified pre-upgrade snapshot selected.")
                }
                Button("Quit Without Changes") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Quits without allowing new work to be saved to temporary storage.")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database recovery required")
    }
}

/// Brand palette: legal "ink & gold". The § (section symbol) is the mark.
enum BrandColors {
    static let navy = Color(red: 0x0B / 255, green: 0x23 / 255, blue: 0x40 / 255)
    static let gold = Color(red: 0xC9 / 255, green: 0xA2 / 255, blue: 0x4B / 255)
}

/// Launch splash: the § mark, the name, and the "See Supra" tagline.
struct SplashView: View {
    var body: some View {
        ZStack {
            BrandColors.navy.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("§")
                    .font(.system(size: 104, weight: .semibold, design: .serif))
                    .foregroundStyle(BrandColors.gold)
                VStack(spacing: 6) {
                    Text("Supra AI")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("Secure legal AI without compromise.")
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("See Supra.")
                        .font(.system(size: 15, design: .serif).italic())
                        .foregroundStyle(BrandColors.gold.opacity(0.92))
                }
            }
        }
    }
}

/// First-run guided setup: prompts the user to download a reasoning, a drafting, and
/// an embedding model. Skippable / non-blocking — downloads continue in the background
/// after the user enters the app (the controllers live on AppEnvironment). Shown once;
/// dismissing records completion so it never reappears.
struct FirstRunOnboardingView: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var downloader: ModelDownloadController
    @ObservedObject var embeddingDownloader: EmbeddingModelDownloadController
    @ObservedObject var documentSetup: DocumentIntelligenceSetupController
    let onComplete: () -> Void

    // Per-job download selections, defaulted to the curated role recommendations
    // (addressed by name so the catalog list can be sorted by quality).
    @State private var reasoningRepo = ModelCatalog.defaultReasoningModel.repoID
    @State private var draftingRepo = ModelCatalog.defaultDraftingModel.repoID
    @State private var embeddingRepo = EmbeddingModelCatalog.defaultModel.repoID
    // Models whose download was started here, by display name → the role to assign on
    // registration (captured at click time so changing a picker later can't misroute).
    @State private var pendingRoleByName: [String: ModelRole] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Supra AI runs entirely on your Mac. Pick a model for each job to get started — these are large (each reasoning/drafting model is ~17 GB), so you can start the downloads now and keep working while they finish, or set them up later.")
                        .font(.supraBody).foregroundStyle(.secondary)
                    textModelStep(
                        number: 1, title: "Reasoning model",
                        blurb: "Powers legal research and analysis (the /legal and /research routes).",
                        selection: $reasoningRepo, role: .legalReasoning
                    )
                    textModelStep(
                        number: 2, title: "Drafting model",
                        blurb: "Powers document drafting (the /draft route).",
                        selection: $draftingRepo, role: .drafting
                    )
                    embeddingStep(number: 3)
                    if let error = downloadError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.supraCaption).foregroundStyle(.orange)
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 600)
        .onChange(of: library.models.map(\.id)) { _, _ in assignDownloadedRoles() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("§").font(.system(size: 40, weight: .semibold, design: .serif))
                .foregroundStyle(BrandColors.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Supra AI").font(.supraTitle)
                Text("Let's set up your local models.").font(.supraSubheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Set up later") { onComplete() }
                .buttonStyle(.ghost)
            Spacer()
            Button("Enter Supra AI") { onComplete() }
                .buttonStyle(.ghostAccent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    /// A best-effort surfaced download failure (text or embedding), shown once.
    private var downloadError: String? {
        if case let .failed(message) = downloader.state { return message }
        if case let .failed(message) = embeddingDownloader.state { return message }
        return nil
    }

    @ViewBuilder
    private func textModelStep(
        number: Int, title: String, blurb: String,
        selection: Binding<String>, role: ModelRole
    ) -> some View {
        let catalog = ModelCatalog.curated.first { $0.repoID == selection.wrappedValue }
        stepContainer(number: number, title: title) {
            Text(blurb).font(.supraCaption).foregroundStyle(.secondary)
            HStack {
                Picker("Model", selection: selection) {
                    ForEach(ModelCatalog.curated) { model in
                        Text("\(model.displayName) · ~\(sizeText(model.approxSizeGB)) GB").tag(model.repoID)
                    }
                }
                .labelsHidden()
                Button("Download") {
                    if let catalog { startTextDownload(catalog, role: role) }
                }
                .disabled(downloader.isBusy || isDownloaded(catalog))
            }
            textStatus(for: catalog)
        }
    }

    @ViewBuilder
    private func embeddingStep(number: Int) -> some View {
        let catalog = EmbeddingModelCatalog.curated.first { $0.repoID == embeddingRepo }
        stepContainer(number: number, title: "Embedding model") {
            Text("Powers document semantic search across your matters.").font(.supraCaption).foregroundStyle(.secondary)
            HStack {
                Picker("Embedding model", selection: $embeddingRepo) {
                    ForEach(EmbeddingModelCatalog.curated) { model in
                        Text("\(model.displayName) · ~\(model.approxSizeMB) MB").tag(model.repoID)
                    }
                }
                .labelsHidden()
                Button("Download") {
                    if let catalog { embeddingDownloader.downloadCatalogModel(catalog) }
                }
                .disabled(embeddingDownloader.isBusy || documentSetup.embeddingTestPassed)
            }
            embeddingStatus
        }
    }

    @ViewBuilder
    private func textStatus(for catalog: CatalogModel?) -> some View {
        if isDownloaded(catalog) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.supraCaption).foregroundStyle(.green)
        } else if isDownloading(catalog) {
            if case let .downloading(_, progress) = downloader.state {
                DownloadProgressRow(progress: progress)
            } else {
                Text("Preparing…").font(.supraCaption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var embeddingStatus: some View {
        if documentSetup.embeddingVerifyInFlight {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.supraCaption).foregroundStyle(.secondary)
            }
        } else if documentSetup.embeddingTestPassed, let model = documentSetup.selectedEmbeddingModel {
            Label("Ready — \(model.displayName)", systemImage: "checkmark.circle.fill")
                .font(.supraCaption).foregroundStyle(.green)
        } else if case let .downloading(_, progress) = embeddingDownloader.state {
            DownloadProgressRow(progress: progress)
        } else if case .preparing = embeddingDownloader.state {
            Text("Preparing…").font(.supraCaption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stepContainer(
        number: Int, title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.supraHeadline)
                content()
            }
            Spacer()
        }
    }

    private func startTextDownload(_ catalog: CatalogModel, role: ModelRole) {
        pendingRoleByName[catalog.displayName] = role
        downloader.downloadCatalogModel(catalog)
    }

    /// Assigns each freshly-registered model to the role its download was started for.
    private func assignDownloadedRoles() {
        guard !pendingRoleByName.isEmpty else { return }
        for model in library.models {
            if let role = pendingRoleByName[model.displayName] {
                library.assignModel(model.id, to: role)
                pendingRoleByName[model.displayName] = nil
            }
        }
    }

    private func isDownloaded(_ catalog: CatalogModel?) -> Bool {
        guard let catalog else { return false }
        return library.models.contains { $0.displayName == catalog.displayName }
    }

    private func isDownloading(_ catalog: CatalogModel?) -> Bool {
        guard let catalog else { return false }
        switch downloader.state {
        case let .preparing(repoID): return repoID == catalog.repoID
        case let .downloading(repoID, _): return repoID == catalog.repoID
        default: return false
        }
    }

    private func sizeText(_ gb: Double) -> String {
        gb == gb.rounded() ? String(Int(gb)) : String(format: "%.1f", gb)
    }
}
