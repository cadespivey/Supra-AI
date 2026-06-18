import AppKit
import SupraCore
import SupraSessions
import SwiftUI

/// Generation defaults, model storage location, and app info.
struct SettingsView: View {
    @ObservedObject var settings: SettingsController
    @ObservedObject var documentSetup: DocumentIntelligenceSetupController
    @ObservedObject var embeddingDownloader: EmbeddingModelDownloadController
    @State private var courtListenerToken = ""

    var body: some View {
        Form {
            DocumentIntelligenceSection(
                setup: documentSetup,
                downloader: embeddingDownloader
            )


            Section("Generation Defaults") {
                Picker("Preset", selection: $settings.preset) {
                    ForEach(GenerationPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", settings.temperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                }

                Stepper(
                    "Max output tokens: \(settings.maxOutputTokens)",
                    value: $settings.maxOutputTokens,
                    in: 128...8192,
                    step: 128
                )
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: settings.hasCourtListenerToken ? "checkmark.seal.fill" : "key.slash")
                        .foregroundStyle(settings.hasCourtListenerToken ? .green : .orange)
                    Text(settings.hasCourtListenerToken ? "API token saved" : "No API token saved")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                if settings.hasCourtListenerToken {
                    Button("Clear Token", role: .destructive) {
                        settings.clearCourtListenerToken()
                    }
                } else {
                    SecureField("CourtListener API token", text: $courtListenerToken)
                    Button("Save Token") {
                        settings.saveCourtListenerToken(courtListenerToken)
                        courtListenerToken = ""
                    }
                    .disabled(courtListenerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("CourtListener")
            } footer: {
                Text(settings.hasCourtListenerToken
                     ? "Stored in your Keychain. Clear it to enter a different token."
                     : "Add your token to run CourtListener research. Stored only in your Keychain.")
            }

            Section("Model Storage") {
                LabeledContent("Downloaded models") {
                    Text(settings.modelsDirectoryPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    revealInFinder(settings.modelsDirectoryPath)
                }
            }

            Section("About") {
                LabeledContent(
                    "Version",
                    value: "\(settings.appVersion.marketingVersion) (\(settings.appVersion.buildNumber))"
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func revealInFinder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Document Intelligence setup (Milestone 3 §2): chat-model readiness, embedding
/// model selection/test-load, toolchain/OCR checks, storage init, and
/// notifications. Import is blocked until this is complete.
private struct DocumentIntelligenceSection: View {
    @ObservedObject var setup: DocumentIntelligenceSetupController
    @ObservedObject var downloader: EmbeddingModelDownloadController

    var body: some View {
        Section {
            HStack {
                Image(systemName: setup.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(setup.isComplete ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.isComplete ? "Setup complete — document import is enabled." : "Setup required before importing documents.")
                        .font(.callout.weight(.medium))
                    if let reason = setup.settings.setupInvalidatedReason {
                        Text("Needs review: \(reason)").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if setup.isBusy { ProgressView().controlSize(.small) }
            }

            stepRow("Chat model loaded", done: setup.chatModelLoaded, detail: "Load a chat model in the Models tab.")
            embeddingRow
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
                Button("Mark Setup Complete") { _ = setup.completeSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!setup.canCompleteSetup)
            }
            if let message = setup.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Document Intelligence")
        } footer: {
            if !setup.outstandingSteps.isEmpty {
                Text("Remaining: " + setup.outstandingSteps.joined(separator: " "))
            }
        }
    }

    private var embeddingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(
                "Embedding model",
                done: setup.selectedEmbeddingModel != nil && setup.embeddingTestPassed,
                detail: setup.selectedEmbeddingModel?.displayName ?? "None selected."
            )
            if let selected = setup.selectedEmbeddingModel {
                HStack {
                    Text(selected.displayName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Load") { Task { await setup.testLoadEmbeddingModel() } }
                        .controlSize(.small)
                        .disabled(setup.isBusy)
                }
            }
            Picker("Download", selection: $downloadSelection) {
                Text("Choose a model to download…").tag("")
                ForEach(EmbeddingModelCatalog.curated) { model in
                    Text("\(model.displayName) · \(model.dimension)d · ~\(model.approxSizeMB) MB").tag(model.repoID)
                }
            }
            .labelsHidden()
            .disabled(downloader.isBusy)
            .onChange(of: downloadSelection) { _, newValue in
                if let model = EmbeddingModelCatalog.model(repoID: newValue) {
                    downloader.downloadCatalogModel(model)
                }
            }
            downloadStatus
        }
    }

    @State private var downloadSelection = ""

    @ViewBuilder private var downloadStatus: some View {
        switch downloader.state {
        case .preparing(let repo):
            Text("Preparing \(repo)…").font(.caption).foregroundStyle(.secondary)
        case let .downloading(_, completed, total, file):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("\(completed)/\(total) — \(file)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case let .finished(_, name):
            Text("Downloaded \(name). Test-load it to finish setup.").font(.caption).foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
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
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}
