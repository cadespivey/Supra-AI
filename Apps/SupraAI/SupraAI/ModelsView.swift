import AppKit
import SupraSessions
import SwiftUI

/// Lets the user register a local MLX model folder and load it into the runtime.
struct ModelsView: View {
    @ObservedObject var library: ModelLibrary

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
                Button(action: addModelFolder) {
                    Label("Add Model Folder", systemImage: "plus")
                }
                .help("Choose a local MLX model folder")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Models", systemImage: "cpu")
        } description: {
            Text("Add a local MLX model folder to load a 32B-class model into the runtime.")
        } actions: {
            Button("Add Model Folder…", action: addModelFolder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelList: some View {
        List {
            ForEach(library.models) { model in
                ModelRow(model: model, isLoading: isLoading(model)) {
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

    private func addModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Model"
        panel.message = "Choose a local MLX model folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Persist a security-scoped bookmark so the app retains access across launches.
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

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
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isActive ? "cpu.fill" : "cpu")
                .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(model.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else if model.isActive {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Button("Load", action: onLoad)
            }
        }
        .padding(.vertical, 4)
    }
}
