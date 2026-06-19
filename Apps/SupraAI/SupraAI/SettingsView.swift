import AppKit
import SupraCore
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// Generation defaults, model storage location, and app info.
struct SettingsView: View {
    @ObservedObject var settings: SettingsController
    @ObservedObject var profile: AssistantProfileController
    @ObservedObject var documentSetup: DocumentIntelligenceSetupController
    @ObservedObject var embeddingDownloader: EmbeddingModelDownloadController
    @State private var courtListenerToken = ""

    var body: some View {
        Form {
            AssistantProfileSection(profile: profile)

            DocumentIntelligenceSection(
                setup: documentSetup,
                downloader: embeddingDownloader
            )


            Section("Generation Defaults") {
                Picker("Preset", selection: $settings.preset) {
                    ForEach(GenerationPreset.userSelectableDefaults, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
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
                    Text(courtListenerStatusText)
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                if settings.courtListenerTokenSource == .keychain {
                    Button("Clear Token", role: .destructive) {
                        settings.clearCourtListenerToken()
                    }
                } else if settings.courtListenerTokenSource == .none {
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
                Text(courtListenerFooterText)
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
                AboutBanner()
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

    private var courtListenerStatusText: String {
        switch settings.courtListenerTokenSource {
        case .environment:
            "API token from environment"
        case .keychain:
            "API token saved in Keychain"
        case .none:
            "No API token saved"
        }
    }

    private var courtListenerFooterText: String {
        switch settings.courtListenerTokenSource {
        case .environment:
            "Using SUPRA_COURTLISTENER_API_KEY from the environment. Change or unset that variable to use a different token."
        case .keychain:
            "Stored in your Keychain. Clear it to enter a different token."
        case .none:
            "Add your token to run CourtListener research. Stored only in your Keychain."
        }
    }
}

/// Branded About banner: the § mark, the name, and the "See Supra" tagline.
private struct AboutBanner: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(BrandColors.navy)
                .frame(width: 60, height: 60)
                .overlay(
                    Text("§")
                        .font(.system(size: 38, weight: .semibold, design: .serif))
                        .foregroundStyle(BrandColors.gold)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Supra AI").font(.title3.weight(.semibold))
                Text("Secure legal AI without compromise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("See Supra.")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// The "Assistant Profile": plain-language inputs about who you are, how you write,
/// and how you cite, plus samples of your own writing. These are combined into the
/// system prompt the assistant follows on every response. Written for a legal
/// audience — no machine-learning jargon.
private struct AssistantProfileSection: View {
    @ObservedObject var profile: AssistantProfileController
    @State private var isImportingSample = false
    @State private var showPreview = false

    /// File types accepted for writing samples (handled by the extraction service).
    private static let sampleTypes: [UTType] = {
        var types: [UTType] = [.pdf, .rtf, .plainText, .text]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        if let doc = UTType("com.microsoft.word.doc") { types.append(doc) }
        return types
    }()

    var body: some View {
        Section {
            Text("These details shape how the assistant writes for you. Everything is optional — fill in what's useful and update it anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Full name", text: $profile.profile.fullName)
            TextField("Role or title", text: $profile.profile.role, prompt: Text("e.g. Partner, Associate, Paralegal"))
            TextField("Firm or organization", text: $profile.profile.organization)
            TextField("Jurisdictions", text: $profile.profile.jurisdictions, prompt: Text("e.g. California state and the Ninth Circuit"))
            TextField("Practice areas", text: $profile.profile.practiceAreas, prompt: Text("e.g. Commercial litigation, employment"))
        } header: {
            Text("Assistant Profile")
        } footer: {
            Text("Tells the assistant who it's helping and the law you work in, so its answers fit your practice.")
        }

        Section {
            Picker("Tone", selection: $profile.profile.formality) {
                ForEach(AssistantProfile.Formality.allCases) { Text($0.label).tag($0) }
            }
            Picker("Default length", selection: $profile.profile.length) {
                ForEach(AssistantProfile.Length.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Style notes").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "Style notes",
                    text: $profile.profile.voiceNotes,
                    prompt: Text("e.g. Lead with the bottom line, avoid legalese, use IRAC for analysis"),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .labelsHidden()
            }
        } header: {
            Text("Writing Style")
        } footer: {
            Text("Shapes how the assistant writes for you — how formal, how long, and any habits you prefer.")
        }

        Section {
            TextField(
                "Citation style",
                text: $profile.profile.citationStyle,
                prompt: Text("e.g. Bluebook, ALWD, or your court's local rules")
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Citation notes").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "Citation notes",
                    text: $profile.profile.citationNotes,
                    prompt: Text("e.g. Always pin-cite; include parallel cites; short form after first reference"),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .labelsHidden()
            }
        } header: {
            Text("Citations")
        } footer: {
            Text("How you want authorities cited. The assistant follows this when it references cases, statutes, or rules.")
        }

        Section {
            TextField(
                "Anything else",
                text: $profile.profile.additionalInstructions,
                prompt: Text("e.g. Flag missing facts; caveat firm conclusions; prefer primary sources"),
                axis: .vertical
            )
            .lineLimit(2...6)
            .labelsHidden()
        } header: {
            Text("Other Instructions")
        } footer: {
            Text("Standing instructions you'd give a new associate. These apply to every response.")
        }

        Section {
            if profile.profile.writingSamples.isEmpty {
                Text("No samples added yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(profile.profile.writingSamples) { sample in
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(sample.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            profile.removeWritingSample(id: sample.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this sample")
                    }
                }
            }
            HStack {
                Button {
                    isImportingSample = true
                } label: {
                    Label("Add writing sample…", systemImage: "plus")
                }
                .disabled(profile.isAddingSample)
                if profile.isAddingSample { ProgressView().controlSize(.small) }
                Spacer()
            }
        } header: {
            Text("Writing Samples")
        } footer: {
            Text("Add a brief, motion, or letter you've written. The assistant studies its voice and formatting to match your style — it won't reuse the content. Accepts PDF, Word, RTF, or text.")
        }
        .fileImporter(
            isPresented: $isImportingSample,
            allowedContentTypes: Self.sampleTypes,
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                for url in urls {
                    Task { await profile.addWritingSample(url: url) }
                }
            }
        }

        Section {
            HStack {
                Button("Save Profile") { profile.save() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if let message = profile.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Preview what the assistant receives", isExpanded: $showPreview) {
                ScrollView {
                    Text(profile.composedSystemPrompt.isEmpty ? "Nothing configured yet." : profile.composedSystemPrompt)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        } header: {
            Text("Review & Save")
        } footer: {
            Text("Everything above is combined into the instructions the assistant follows. Changes take effect once you save.")
        }
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

            stepRow("Runtime text model loaded", done: setup.chatModelLoaded, detail: "Load a registered model in the Models tab.")
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
