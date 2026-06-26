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
    @ObservedObject var update: UpdateController
    @ObservedObject var billing: BillingSettingsController
    @State private var courtListenerToken = ""

    var body: some View {
        Form {
            AssistantProfileSection(profile: profile)

            DocumentIntelligenceSection(setup: documentSetup)

            ScratchPadBillingSection(billing: billing)


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
                    Text("Lower is more precise, deterministic, and consistent — best for legal accuracy. Higher is more varied and creative, with more risk of drift or invented detail.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(
                        "Max output tokens: \(settings.maxOutputTokens)",
                        value: $settings.maxOutputTokens,
                        in: 128...8192,
                        step: 128
                    )
                    Text("The longest a single answer can be (≈¾ of a word per token). Higher allows fuller answers but uses more memory and takes longer; it doesn't change accuracy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

            Section {
                Toggle("Check for updates automatically", isOn: $update.autoCheckEnabled)
                if let available = update.available {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Version \(available.version) is available")
                                .font(.callout.weight(.medium))
                            Text("You have \(settings.appVersion.marketingVersion).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") {
                            NSWorkspace.shared.open(available.downloadURL ?? available.releaseURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Release notes…") { NSWorkspace.shared.open(available.releaseURL) }
                }
                HStack {
                    Button("Check Now") { Task { await update.checkNow() } }
                        .disabled(update.isChecking)
                    if update.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if update.available == nil, let message = update.statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("Checks GitHub for newer releases of Supra AI. It only fetches the latest version number — no usage data is sent — and only when you ask or turn on automatic checks.")
            }

            Section {
                AboutBanner(version: settings.appVersion.marketingVersion)
                Link(destination: URL(string: "https://github.com/cadespivey/Supra-AI")!) {
                    Label("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://www.courtlistener.com")!) {
                    Label("CourtListener", systemImage: "books.vertical")
                }
                Link(destination: URL(string: "https://free.law")!) {
                    Label("Free Law Project", systemImage: "building.columns")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Supra AI's legal research is powered by CourtListener and the Free Law Project — free, nonprofit resources. Please consider creating a free account to support and sustain their work.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Branded About banner: the app icon, name, tagline, and version.
private struct AboutBanner: View {
    let version: String

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("Supra AI").font(.title3.weight(.semibold))
                Text("Secure legal AI without compromise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// ScratchPad → billing settings (Milestone 4 Phase 7, spec §9): the firm-wide
/// billing instructions, time/rounding behaviour, auto-coding toggle, and the
/// single configured timekeeper + firm identity that populate fee lines. Every
/// control persists immediately. Written for a legal audience — no ML jargon.
private struct ScratchPadBillingSection: View {
    @ObservedObject var billing: BillingSettingsController

    /// Common rounding increments offered in the picker (in hours).
    private static let increments: [Double] = [0.1, 0.2, 0.25, 0.5, 1.0]

    private var sensitivityLabel: String {
        BillingSensitivity(value: billing.sensitivity).rawValue.capitalized
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Global billing instructions").font(.caption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. No block billing; spell out abbreviations on first use; cap intra-office conferences",
                    text: $billing.globalInstructions,
                    minHeight: 120
                )
            }
            Picker("Narrative punctuation", selection: $billing.narrativeTerminal) {
                ForEach(BillingNarrativeTerminal.allCases) { terminal in
                    Text(terminal.label).tag(terminal)
                }
            }
        } header: {
            Text("ScratchPad & Billing")
        } footer: {
            Text("Standing instructions applied to every billing draft. Per-matter rules (Matter → Billing) layer on top of these. “Narrative punctuation” normalizes how every billing narrative ends at export — a matter can override it.")
        }

        Section {
            Toggle("Auto-timestamp entries", isOn: $billing.autoTimestamp)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Time inference")
                    Spacer()
                    Text(sensitivityLabel).foregroundStyle(.secondary)
                }
                Slider(value: $billing.sensitivity, in: 0...1, step: 0.05) {
                    Text("Time inference")
                } minimumValueLabel: {
                    Text("Precise").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Generous").font(.caption2).foregroundStyle(.secondary)
                }
                Text("How freely the engine infers durations. Precise bills only explicit, strong-evidence time; generous may infer implied workflow (e.g. research before drafting). Guardrails always apply — nothing is fabricated without a basis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Round time to", selection: $billing.roundingIncrement) {
                ForEach(Self.increments, id: \.self) { value in
                    Text("\(BillingExporter.hoursString(value)) h").tag(value)
                }
                // Keep a non-standard stored increment selectable so it isn't lost.
                if !Self.increments.contains(billing.roundingIncrement) {
                    Text("\(BillingExporter.hoursString(billing.roundingIncrement)) h")
                        .tag(billing.roundingIncrement)
                }
            }
            Toggle("Propose UTBMS codes automatically", isOn: $billing.utbmsAutoCoding)
        } header: {
            Text("Time & Coding")
        } footer: {
            Text("Auto-timestamp records when each note is written and uses the gaps as time evidence. Turn it off to rely on written cues instead. UTBMS auto-coding proposes task/activity codes you can always edit.")
        }

        Section {
            TextField("Timekeeper ID", text: $billing.timekeeperID, prompt: Text("e.g. TK-1001"))
            TextField("Timekeeper name", text: $billing.timekeeperName, prompt: Text("e.g. C. Spivey"))
            TextField("Classification", text: $billing.timekeeperClassification, prompt: Text("e.g. PARTNER, ASSOCIATE, PARALEGAL"))
            HStack {
                Text("Default rate")
                Spacer()
                Text("$").foregroundStyle(.secondary)
                TextField("Rate", value: $billing.timekeeperRate, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                Text("/ hr").foregroundStyle(.secondary)
            }
            TextField("Firm ID (LAW_FIRM_ID)", text: $billing.lawFirmID, prompt: Text("e.g. 98-7654321"))
        } header: {
            Text("Timekeeper & Firm")
        } footer: {
            Text("Populates the timekeeper and firm fields on every fee line. LEDES export is blocked until the rate, timekeeper ID, and firm ID are set.")
        }
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

    /// Bridges the `[String]` secondary-email list to a newline-delimited text editor:
    /// each non-empty line becomes one designation (≤2 kept, per 2.516).
    private var secondaryEmailsBinding: Binding<String> {
        Binding(
            get: { profile.profile.secondaryEmails.joined(separator: "\n") },
            set: { newValue in
                profile.profile.secondaryEmails = newValue
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

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
            Text("Used only to fill the signature block and letterhead of documents you draft in chat. Nothing is invented — if these are blank, drafting asks you to complete them rather than guessing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Florida Bar number", text: $profile.profile.barNumber, prompt: Text("e.g. 100847"))
            TextField("Office street", text: $profile.profile.officeStreet, prompt: Text("e.g. 200 West Forsyth Street"))
            TextField("Suite / floor (optional)", text: $profile.profile.officeSuite, prompt: Text("e.g. Suite 1400"))
            HStack {
                TextField("City", text: $profile.profile.officeCity)
                TextField("State", text: $profile.profile.officeState)
                TextField("ZIP", text: $profile.profile.officeZip)
            }
            TextField("Telephone", text: $profile.profile.officePhone, prompt: Text("e.g. (904) 555-0142"))
            TextField("Facsimile (optional)", text: $profile.profile.officeFax)
            TextField("Primary service e-mail", text: $profile.profile.primaryEmail, prompt: Text("e.g. you@firm.com"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Secondary service e-mails (one per line)").font(.caption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. litdocket@firm.com",
                    text: secondaryEmailsBinding
                )
            }
        } header: {
            Text("Firm identity for drafting")
        } footer: {
            Text("Florida service designations (Fla. R. Jud. Admin. 2.516) and the signature block on court filings draw from these fields.")
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
                MultilineField(
                    placeholder: "e.g. Lead with the bottom line, avoid legalese, use IRAC for analysis",
                    text: $profile.profile.voiceNotes
                )
            }
        } header: {
            Text("Writing Style")
        } footer: {
            Text("Shapes how the assistant writes for you — how formal, how long, and any habits you prefer.")
        }

        Section {
            Picker("Citation style", selection: $profile.profile.citationStyle) {
                Text("Not set").tag("")
                Section("General") {
                    ForEach(CitationStyleCatalog.general) { style in
                        Text(style.displayName).tag(style.displayName)
                    }
                }
                Section("State-specific") {
                    ForEach(CitationStyleCatalog.states) { style in
                        Text(style.displayName).tag(style.displayName)
                    }
                }
                // Keep a previously-typed custom value selectable so it isn't lost.
                if !profile.profile.citationStyle.isEmpty,
                   CitationStyleCatalog.style(named: profile.profile.citationStyle) == nil {
                    Text(profile.profile.citationStyle).tag(profile.profile.citationStyle)
                }
            }
            .pickerStyle(.menu)
            if let style = CitationStyleCatalog.style(named: profile.profile.citationStyle) {
                Text(style.guidance).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Citation notes").font(.caption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. Always pin-cite; include parallel cites; short form after first reference",
                    text: $profile.profile.citationNotes
                )
            }
        } header: {
            Text("Citations")
        } footer: {
            Text("How you want authorities cited. The assistant follows this when it references cases, statutes, or rules.")
        }

        Section {
            MultilineField(
                placeholder: "e.g. Flag missing facts; caveat firm conclusions; prefer primary sources",
                text: $profile.profile.additionalInstructions,
                minHeight: 88
            )
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
            if let message = profile.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Preview what the assistant receives", isExpanded: $showPreview) {
                ScrollView {
                    Text(profile.composedSystemPrompt.isEmpty ? "Nothing configured yet." : profile.composedSystemPrompt)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("Everything above is combined into the instructions the assistant follows. Your changes save automatically as you type.")
        }
    }
}

/// Document Intelligence setup (Milestone 3 §2): chat-model readiness, embedding
/// model selection/test-load, toolchain/OCR checks, storage init, and
/// notifications. Import is blocked until this is complete.
private struct DocumentIntelligenceSection: View {
    @ObservedObject var setup: DocumentIntelligenceSetupController

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

            stepRow(
                "Runtime text model loaded",
                done: setup.chatModelReady,
                detail: setup.chatModelReady ? "A runtime model has loaded successfully." : "Load a registered model in the Models tab."
            )
            stepRow(
                "Embedding model",
                done: setup.selectedEmbeddingModel != nil && setup.embeddingTestPassed,
                detail: setup.selectedEmbeddingModel.map { "\($0.displayName) — manage it in the Models tab." } ?? "Download, select, and test-load one in the Models tab."
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

/// Guided embedding-model setup flow, presented as a linear sequence: 1) download
/// a model, 2) select it for use, 3) test-load it. Shown in the Models tab.
struct EmbeddingModelSetupView: View {
    @ObservedObject var setup: DocumentIntelligenceSetupController
    @ObservedObject var downloader: EmbeddingModelDownloadController
    @State private var downloadSelection = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(number: 1, title: "Download a model") {
                Picker("Embedding model to download", selection: $downloadSelection) {
                    Text("Choose a model…").tag("")
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

            step(number: 2, title: "Select for use", enabled: !setup.availableEmbeddingModels.isEmpty) {
                if setup.availableEmbeddingModels.isEmpty {
                    Text("No embedding models downloaded yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Active embedding model", selection: activeSelection) {
                        ForEach(setup.availableEmbeddingModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            step(number: 3, title: "Test load", enabled: setup.selectedEmbeddingModel != nil) {
                if let selected = setup.selectedEmbeddingModel {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: setup.embeddingTestPassed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(setup.embeddingTestPassed ? .green : .secondary)
                        Text(setup.embeddingTestPassed
                             ? "\(selected.displayName) loaded successfully."
                             : "Test-load \(selected.displayName) to confirm it works.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test Load") { Task { await setup.testLoadEmbeddingModel() } }
                            .controlSize(.small)
                            .disabled(setup.isBusy)
                    }
                } else {
                    Text("Download and select a model first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let message = setup.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var activeSelection: Binding<String> {
        Binding(
            get: { setup.selectedEmbeddingModel?.id ?? "" },
            set: { setup.selectEmbeddingModel(id: $0) }
        )
    }

    @ViewBuilder
    private func step(
        number: Int,
        title: String,
        enabled: Bool = true,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(enabled ? Color.accentColor : Color.secondary, in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
            content()
                .padding(.leading, 22)
        }
        .opacity(enabled ? 1 : 0.6)
    }

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
            Text("Downloaded \(name). Now select it and test-load.").font(.caption).foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}
