import AppKit
import SupraCore
import SupraSessions
import SwiftUI

/// Lets the user download an MLX model from Hugging Face or register a local
/// model folder, then load it into the runtime.
struct ModelsView: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var downloader: ModelDownloadController
    @ObservedObject var documentSetup: DocumentIntelligenceSetupController
    @ObservedObject var embeddingDownloader: EmbeddingModelDownloadController
    @State private var showDownloadSheet = false
    @State private var pendingDelete: ModelSummary?
    @State private var deleteBlocked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelList
            Divider()
            footer
        }
        .sheet(isPresented: $showDownloadSheet) {
            ModelDownloadSheet(downloader: downloader)
                // Clear a finished/failed banner on close (no-op mid-download).
                .onDisappear { downloader.dismissResult() }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.displayName)”?" } ?? "Delete model?",
            isPresented: deleteConfirmBinding,
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                if let model = pendingDelete { confirmDelete(model) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert("Couldn't delete model", isPresented: deleteBlockedBinding) {
            Button("OK", role: .cancel) { deleteBlocked = nil }
        } message: {
            Text(deleteBlocked ?? "")
        }
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteBlockedBinding: Binding<Bool> {
        Binding(get: { deleteBlocked != nil }, set: { if !$0 { deleteBlocked = nil } })
    }

    private var deleteButtonTitle: String {
        guard let model = pendingDelete else { return "Delete" }
        return library.isManagedDownload(model) ? "Delete Files" : "Remove"
    }

    private var deleteMessage: String {
        guard let model = pendingDelete else { return "" }
        if library.isManagedDownload(model) {
            return "This permanently deletes the downloaded model files from disk to free space. You can re-download it later. Any task roles assigned to it are cleared."
        }
        return "This unregisters the model from Supra AI. The folder on your disk is left in place. Any task roles assigned to it are cleared."
    }

    private func confirmDelete(_ model: ModelSummary) {
        Task { @MainActor in
            if case let .blocked(message) = await library.deleteModel(modelID: model.id) {
                deleteBlocked = message
            }
        }
    }

    // Laid out as a plain ScrollView (not a List) so sections are separated by
    // whitespace alone — macOS List separators can't be reliably hidden.
    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                modelSection("Registered Models") {
                    if library.models.isEmpty {
                        noModelsRow
                    } else {
                        VStack(spacing: 6) {
                            ForEach(library.models) { model in
                                ModelRow(
                                    model: model,
                                    isLoading: isLoading(model),
                                    isLoaded: isLoaded(model),
                                    onLoad: { Task { await library.activateAndLoad(modelID: model.id) } },
                                    onDelete: { pendingDelete = model }
                                )
                                .contextMenu {
                                    Button(role: .destructive) { pendingDelete = model } label: {
                                        Label("Delete Model", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                modelSection(
                    "Task Models",
                    footer: "The runtime holds one model at a time."
                ) {
                    RuntimeModelSetupView(library: library, downloader: downloader)
                }

                modelSection(
                    "Embedding Model",
                    footer: "Embeddings power document semantic search. It feeds the Document Intelligence readiness check below."
                ) {
                    EmbeddingModelSetupView(setup: documentSetup, downloader: embeddingDownloader)
                }

                DocumentIntelligenceSection(setup: documentSetup)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A titled section: a header, its content, and an optional footnote — separated
    /// from its neighbours by whitespace rather than divider lines.
    @ViewBuilder
    private func modelSection(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.supraHeadline)
            content()
            if let footer {
                Text(footer).font(.supraCaption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noModelsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No Models", systemImage: "cpu")
                .font(.supraHeadline)
            Text("Download an MLX model from Hugging Face, or register a folder already on disk.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Download a Model…") { showDownloadSheet = true }
                    .buttonStyle(.ghostAccent)
                Button("Add Local Folder…", action: addModelFolder)
                    .buttonStyle(.ghost)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch library.loadState {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("No runtime model loaded.")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading model…")
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(library.loadedModel.map { "Runtime loaded: \($0.displayName)" } ?? "Runtime model loaded.")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .font(.supraBody)
        .padding(12)
    }

    private func isLoading(_ model: ModelSummary) -> Bool {
        if case let .loading(modelID) = library.loadState {
            return modelID == model.id
        }
        return false
    }

    /// Whether this model is the one actually loaded into the runtime right now —
    /// distinct from `model.isActive`, which is the persisted default that survives
    /// relaunches even though the runtime starts empty.
    private func isLoaded(_ model: ModelSummary) -> Bool {
        library.loadedModelID?.rawValue.uuidString == model.id
    }

    private func addModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Model"
        panel.message = "Choose a local MLX model folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A user-selected folder is only usable if we can persist a security-scoped
        // bookmark for it; without one the sandboxed service could never read it.
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        _ = try? library.addModel(
            displayName: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            bookmarkData: bookmark
        )
    }
}

private struct ModelRow: View {
    let model: ModelSummary
    let isLoading: Bool
    let isLoaded: Bool
    var onLoad: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isActive ? "cpu.fill" : "cpu")
                .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                    // The persisted startup model; this is independent of whether
                    // it's currently loaded into the runtime.
                    if model.isActive {
                        Text("Startup")
                            .font(.supraCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(model.path)
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else if isLoaded {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.supraCaption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(action: onLoad) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Load model")
                .accessibilityLabel("Load model")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Delete model")
            .accessibilityLabel("Delete model")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ModelRoleAssignmentRow: View {
    let role: ModelRole
    let models: [ModelSummary]
    @Binding var assignedModelID: String
    let resolvedModel: ModelSummary?
    let recommendedModel: ModelSummary?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(resolvedModel == nil ? .orange : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.displayName)
                    .font(.supraHeadline)
                // The picker names the assigned model — subtext only when the
                // route needs attention.
                if resolvedModel == nil {
                    Text(statusText)
                        .font(.supraCaption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Suggest the best-fitting downloaded model for this route when it
                // isn't already the one in use; one tap assigns it.
                if let recommendedModel, recommendedModel.id != resolvedModel?.id {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Recommended: \(recommendedModel.displayName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Use") { assignedModelID = recommendedModel.id }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .font(.supraCaption)
                    .foregroundStyle(.tint)
                }
            }
            Spacer()
            Picker(role.displayName, selection: $assignedModelID) {
                Text("Not assigned").tag("")
                ForEach(models) { model in
                    Text(model.displayName).tag(model.id)
                }
                if !assignedModelID.isEmpty && !models.contains(where: { $0.id == assignedModelID }) {
                    Text("Missing model").tag(assignedModelID)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .disabled(models.isEmpty)
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        models.isEmpty ? "Add a model to assign this route" : "No route model"
    }

    private var iconName: String {
        switch role {
        case .legalReasoning:
            "scalemass"
        case .legalReasoningHighQuality:
            "sparkles"
        case .drafting:
            "square.and.pencil"
        case .critique:
            "checkmark.seal"
        }
    }
}

/// Guided setup for the runtime text models, mirroring the embedding-model flow:
/// 1) download → 2) assign to each task (recommending from what's downloaded) →
/// 3) load & verify.
private struct RuntimeModelSetupView: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var downloader: ModelDownloadController
    @State private var downloadSelection = ""
    @State private var customRepoID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(number: 1, title: "Download a model") {
                Picker("Model to download", selection: $downloadSelection) {
                    Text("Choose a curated model…").tag("")
                    ForEach(ModelCatalog.curated) { model in
                        Text("\(model.displayName) · ~\(sizeText(model.approxSizeGB)) GB").tag(model.repoID)
                    }
                }
                .labelsHidden()
                .disabled(downloader.isBusy)
                .onChange(of: downloadSelection) { _, newValue in
                    if let model = ModelCatalog.curated.first(where: { $0.repoID == newValue }) {
                        downloader.downloadCatalogModel(model)
                    }
                }
                HStack {
                    TextField("or a custom repo ID, e.g. mlx-community/Qwen2.5-32B-Instruct-4bit", text: $customRepoID).supraField()
                        .textFieldStyle(.roundedBorder)
                    Button("Download") {
                        downloader.download(repoID: customRepoID)
                        customRepoID = ""
                    }
                    .disabled(downloader.isBusy || customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                downloadStatus
            }

            step(number: 2, title: "Assign to tasks", enabled: !library.models.isEmpty) {
                if library.models.isEmpty {
                    Text("Download a model first.").font(.supraCaption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(ModelRole.allCases, id: \.self) { role in
                            ModelRoleAssignmentRow(
                                role: role,
                                models: library.models,
                                assignedModelID: assignmentBinding(for: role),
                                resolvedModel: library.resolvedModel(for: role),
                                recommendedModel: library.recommendedModel(for: role)
                            )
                        }
                    }
                    Text("Assigned models load automatically when a task runs; loading below verifies the files now.")
                        .font(.supraCaption).foregroundStyle(.secondary)
                }
            }

            step(number: 3, title: "Load & verify", enabled: !library.models.isEmpty) {
                if library.models.isEmpty {
                    Text("Download and assign a model first.").font(.supraCaption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        runtimeStatus
                        Spacer()
                        Button {
                            loadRecommendedRuntimeModel()
                        } label: {
                            Label("Load Runtime Model", systemImage: "play.fill")
                        }
                        .disabled(isRuntimeLoading || library.startupModelID() == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var downloadStatus: some View {
        switch downloader.state {
        case let .preparing(repoID):
            HStack(spacing: 10) {
                Text("Preparing \(repoID)…").font(.supraCaption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { downloader.cancel() }
                    .buttonStyle(.ghostDanger)
            }
        case let .downloading(_, progress):
            DownloadProgressRow(progress: progress, onCancel: { downloader.cancel() })
        case let .finished(_, displayName):
            Text("Downloaded \(displayName). Assign it below.").font(.supraCaption).foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.supraCaption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func assignmentBinding(for role: ModelRole) -> Binding<String> {
        Binding(
            // Show the effective selection: an explicit assignment, or the lone model
            // when only one is registered (so a single-model setup displays as selected
            // for every role without the user touching each menu).
            get: { library.effectiveAssignedModelID(for: role) ?? "" },
            set: { newValue in library.assignModel(newValue.isEmpty ? nil : newValue, to: role) }
        )
    }

    @ViewBuilder private var runtimeStatus: some View {
        switch library.loadState {
        case .idle:
            Label("No runtime model loaded", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model...")
            }
        case .loaded:
            Label(library.loadedModel.map { "Loaded: \($0.displayName)" } ?? "Runtime model loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private var isRuntimeLoading: Bool {
        if case .loading = library.loadState { return true }
        return false
    }

    private func loadRecommendedRuntimeModel() {
        guard let modelID = library.startupModelID() else { return }
        Task { await library.activateAndLoad(modelID: modelID) }
    }

    private func sizeText(_ gb: Double) -> String {
        gb == gb.rounded() ? String(Int(gb)) : String(format: "%.1f", gb)
    }

    @ViewBuilder
    private func step(
        number: Int,
        title: String,
        enabled: Bool = true,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.supraCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                Text(title)
                    .font(.supraHeadline)
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
            content()
                .padding(.leading, 26)
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

/// Guided Hugging Face download: a curated MLX list plus a custom repo-id field.
private struct ModelDownloadSheet: View {
    @ObservedObject var downloader: ModelDownloadController
    @Environment(\.dismiss) private var dismiss
    @State private var customRepoID = ""

    var body: some View {
        SupraSheetScaffold("Download a Model", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                statusView

                Divider()

                Text("Curated · Hugging Face MLX 4-bit")
                    .font(.supraHeadline)
                ForEach(ModelCatalog.curated) { model in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text("\(model.repoID) · ~\(sizeText(model.approxSizeGB)) GB")
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                            Text(model.notes)
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") { downloader.downloadCatalogModel(model) }
                            .buttonStyle(.ghost)
                            .disabled(downloader.isBusy)
                    }
                }

                Divider()

                Text("Custom repo ID")
                    .font(.supraHeadline)
                HStack {
                    TextField("e.g. mlx-community/Qwen2.5-32B-Instruct-4bit", text: $customRepoID).supraField()
                        .textFieldStyle(.roundedBorder)
                    Button("Download") {
                        downloader.download(repoID: customRepoID)
                        customRepoID = ""
                    }
                    .buttonStyle(.ghost)
                    .disabled(downloader.isBusy || customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 580, maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusView: some View {
        switch downloader.state {
        case .idle:
            Text("Models download into the app's storage and then appear in the list to load. Large models (a 32B is ~18 GB) can take a while.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        case let .preparing(repoID):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing \(repoID)…")
                Button("Cancel", role: .cancel) { downloader.cancel() }
                    .buttonStyle(.ghostDanger)
            }
        case let .downloading(repoID, progress):
            DownloadProgressRow(
                progress: progress,
                title: repoID,
                onCancel: { downloader.cancel() }
            )
        case let .finished(_, displayName):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Downloaded “\(displayName)”. It's now in your models list.")
                Spacer()
                Button("OK") { downloader.dismissResult() }
            }
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.supraCaption)
                    .textSelection(.enabled)
                Spacer()
                Button("Dismiss") { downloader.dismissResult() }
            }
        }
    }

    private func sizeText(_ gb: Double) -> String {
        gb == gb.rounded() ? String(Int(gb)) : String(format: "%.1f", gb)
    }
}

/// Document Intelligence setup (Milestone 3 §2): chat-model readiness, embedding
/// model selection/auto-verify, toolchain/OCR checks, storage init, and
/// notifications. Import is blocked until this is complete. Lives in the Models tab
/// (the models it depends on are configured in the sections above).
private struct DocumentIntelligenceSection: View {
    @ObservedObject var setup: DocumentIntelligenceSetupController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Document Intelligence")
                .font(.supraHeadline)
            HStack {
                Image(systemName: setup.isComplete ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(setup.isComplete ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.isComplete ? "Setup complete — document import is enabled." : "Setup required before importing documents.")
                        .font(.supraHeadline)
                    if let reason = setup.settings.setupInvalidatedReason {
                        Text("Needs review: \(reason)").font(.supraCaption).foregroundStyle(.red)
                    }
                }
                Spacer()
                if setup.isBusy { ProgressView().controlSize(.small) }
            }

            readinessProgress

            stepRow(
                "Runtime text model loaded",
                done: setup.chatModelReady,
                detail: setup.chatModelReady ? "A runtime model has loaded successfully." : "Download and assign a task model above."
            )
            stepRow(
                "Embedding model",
                done: setup.selectedEmbeddingModel != nil && setup.embeddingTestPassed,
                detail: setup.selectedEmbeddingModel.map { "\($0.displayName) — manage it above." } ?? "Download and select one above."
            )
            stepRow(
                "Extraction / OCR toolchain",
                done: setup.toolchain?.meetsMinimumForSetup ?? false,
                detail: setup.toolchain.map { "OCR languages: \($0.ocrLanguages.count)" } ?? "Not checked yet."
            )
            stepRow("Document storage initialized", done: setup.storageInitialized, detail: "Creates app-managed storage.") {
                if !setup.storageInitialized {
                    Button("Initialize") { setup.initializeStorage() }
                }
            }
            stepRow(
                "Completion notifications",
                done: setup.notificationStatus == .authorized,
                detail: "Optional. Notifies when long imports finish."
            ) {
                if setup.notificationStatus != .authorized {
                    Button("Allow") { Task { await setup.requestNotificationPermission() } }
                }
            }

            Stepper(
                "Auto-purge trash after \(setup.autoPurgeDays == 0 ? "never" : "\(setup.autoPurgeDays) days")",
                value: Binding(get: { setup.autoPurgeDays }, set: { setup.updateAutoPurgeDays($0) }),
                in: 0...365,
                step: 5
            )

            HStack {
                Button("Re-check") { Task { await setup.refreshAll() } }
                Spacer()
            }
            if let message = setup.message {
                Text(message).font(.supraCaption).foregroundStyle(.orange)
            }
            if !setup.requiredOutstandingSteps.isEmpty {
                Text("Remaining: " + setup.requiredOutstandingSteps.joined(separator: " "))
                    .font(.supraCaption).foregroundStyle(.secondary)
            }
            if !setup.optionalOutstandingSteps.isEmpty {
                Text("Optional: " + setup.optionalOutstandingSteps.joined(separator: " "))
                    .font(.supraCaption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readinessProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(
                value: Double(setup.completedRequiredStepCount),
                total: Double(setup.requiredStepCount)
            )
            .tint(setup.isComplete ? .green : .orange)
            Text("\(setup.completedRequiredStepCount) of \(setup.requiredStepCount) required checks complete")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepRow(
        _ title: String,
        done: Bool,
        detail: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.supraCaption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}
