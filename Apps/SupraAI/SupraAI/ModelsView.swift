import AppKit
import SupraSessions
import SwiftUI

/// Lets the user download an MLX model from Hugging Face or register a local
/// model folder, then load it into the runtime.
struct ModelsView: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var downloader: ModelDownloadController
    @State private var showDownloadSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if library.models.isEmpty {
                emptyState
            } else {
                modelList
            }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDownloadSheet = true
                } label: {
                    Label("Download Model", systemImage: "arrow.down.circle")
                }
                .help("Download an MLX model from Hugging Face")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: addModelFolder) {
                    Label("Add Local Folder", systemImage: "folder.badge.plus")
                }
                .help("Register an MLX model folder already on disk")
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            ModelDownloadSheet(downloader: downloader)
                // Clear a finished/failed banner on close (no-op mid-download).
                .onDisappear { downloader.dismissResult() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Models", systemImage: "cpu")
        } description: {
            Text("Download an MLX model from Hugging Face, or register a folder already on disk, to load a model into the runtime.")
        } actions: {
            Button("Download a Model…") { showDownloadSheet = true }
                .buttonStyle(.borderedProminent)
            Button("Add Local Folder…", action: addModelFolder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelList: some View {
        List {
            ForEach(library.models) { model in
                ModelRow(model: model, isLoading: isLoading(model), isLoaded: isLoaded(model), loadDisabled: isAnyLoading) {
                    Task { await library.activateAndLoad(modelID: model.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch library.loadState {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("No model loaded.")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading model…")
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Model loaded and ready.")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .font(.callout)
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

    private var isAnyLoading: Bool {
        if case .loading = library.loadState { return true }
        return false
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

        guard let summary = try? library.addModel(
            displayName: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            bookmarkData: bookmark
        ) else { return }

        Task { await library.activateAndLoad(modelID: summary.id) }
    }
}

private struct ModelRow: View {
    let model: ModelSummary
    let isLoading: Bool
    let isLoaded: Bool
    let loadDisabled: Bool
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isActive ? "cpu.fill" : "cpu")
                .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                    // The persisted default model; "Default" is independent of whether
                    // it's currently loaded into the runtime.
                    if model.isActive {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(model.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else if isLoaded {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                // A "Load" action is always offered when the model isn't in the
                // runtime — including the default model after a relaunch (which used
                // to show a static "Active" label with no way to load it).
                Button("Load", action: onLoad)
                    .disabled(loadDisabled)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Guided Hugging Face download: a curated MLX list plus a custom repo-id field.
private struct ModelDownloadSheet: View {
    @ObservedObject var downloader: ModelDownloadController
    @Environment(\.dismiss) private var dismiss
    @State private var customRepoID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Download a Model")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            statusView

            Divider()

            Text("Curated · Hugging Face MLX 4-bit")
                .font(.headline)
            ForEach(ModelCatalog.curated) { model in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text("\(model.repoID) · ~\(sizeText(model.approxSizeGB)) GB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") { downloader.downloadCatalogModel(model) }
                        .disabled(downloader.isBusy)
                }
            }

            Divider()

            Text("Custom repo ID")
                .font(.headline)
            HStack {
                TextField("e.g. mlx-community/Qwen2.5-32B-Instruct-4bit", text: $customRepoID)
                    .textFieldStyle(.roundedBorder)
                Button("Download") {
                    downloader.download(repoID: customRepoID)
                    customRepoID = ""
                }
                .disabled(downloader.isBusy || customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    @ViewBuilder
    private var statusView: some View {
        switch downloader.state {
        case .idle:
            Text("Models download into the app's storage and then appear in the list to load. Large models (a 32B is ~18 GB) can take a while.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .preparing(repoID):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing \(repoID)…")
            }
        case let .downloading(repoID, completed, total, currentFile):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("\(repoID) — file \(completed + 1) of \(total): \(currentFile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Cancel", role: .cancel) { downloader.cancel() }
            }
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
                    .font(.callout)
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
