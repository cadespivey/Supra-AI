import AppKit
import SupraCore
import SupraDraftingCore
import SupraNetworking
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// Generation defaults, model storage location, and app info.
struct SettingsView: View {
    @ObservedObject var settings: SettingsController
    @ObservedObject var profile: AssistantProfileController
    @ObservedObject var update: SparkleUpdaterController
    @ObservedObject var billing: BillingSettingsController
    @ObservedObject var backup: BackupController
    @ObservedObject var firmStyle: FirmStyleProfileController
    let parseExemplar: @MainActor (ExemplarKind, URL) async -> ExemplarParseOutcome

    var body: some View {
        Form {
            AssistantProfileSection(profile: profile, billing: billing)

            FirmStyleSection(firmStyle: firmStyle, parseExemplar: parseExemplar)

            ScratchPadBillingSection(billing: billing)

            BackupSection(backup: backup)

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
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(
                        "Max output tokens: \(settings.maxOutputTokens)",
                        value: $settings.maxOutputTokens,
                        in: 128...8192,
                        step: 128
                    )
                    Text("The longest a single answer can be (≈¾ of a word per token). Higher allows fuller answers but uses more memory and takes longer; it doesn't change accuracy.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Connectors that ground research in primary law and track legislative & regulatory developments. Expand a source to add and verify a key — keys are free and stored only in your Keychain. Sources marked “Free · no key required” are public APIs with no key; use Verify to confirm they’re reachable.")
                    .font(.callout).foregroundStyle(.secondary)
                // Case law
                APIKeyDisclosure(
                    settings: settings, title: "CourtListener",
                    description: "Federal & state case law from courts and PACER, via the nonprofit Free Law Project. Updated continuously as new opinions are published.",
                    kind: .courtListener(signupURL: URL(string: "https://www.courtlistener.com/help/api/rest/")!)
                )
                // Codified law
                APIKeyDisclosure(
                    settings: settings, title: "govinfo",
                    description: "The official U.S. Code from the U.S. Government Publishing Office. USCODE editions are issued annually, with supplements between editions.",
                    kind: .service(.govInfo, prompt: "govinfo (api.data.gov) API key", signupURL: URL(string: "https://api.data.gov/signup/")!)
                )
                APIKeyDisclosure(
                    settings: settings, title: "eCFR",
                    description: "The official Code of Federal Regulations. Continuously updated; each section carries an effective date, typically current to within a few days.",
                    kind: .builtIn(sourceID: "ecfr")
                )
                APIKeyDisclosure(
                    settings: settings, title: "Open Legal Codes",
                    description: "State statutes, the U.S. Code, and the CFR, crawled best-effort. Coverage varies and there is no verified effective date — always confirm currency against the official source.",
                    kind: .builtIn(sourceID: "open-legal-codes")
                )
                // Legislative & regulatory developments (tracked, not cited as authority)
                APIKeyDisclosure(
                    settings: settings, title: "Federal Register",
                    description: "Federal rules, proposed rules, and agency notices. Published every federal business day. Tracked as developments — not cited as authority.",
                    kind: .builtIn(sourceID: "federal-register")
                )
                APIKeyDisclosure(
                    settings: settings, title: "OpenStates",
                    description: "State & federal bills, from the Plural civic-data project. Updated daily while legislatures are in session.",
                    kind: .service(.openStates, prompt: "OpenStates API key", signupURL: URL(string: "https://openstates.org/accounts/profile/")!)
                )
                APIKeyDisclosure(
                    settings: settings, title: "Regulations.gov",
                    description: "Federal rulemaking dockets and public comments. Updated each federal business day. Tracked as developments — not cited as authority.",
                    kind: .service(.regulationsGov, prompt: "Regulations.gov API key", signupURL: URL(string: "https://api.data.gov/signup/")!)
                )
            } header: {
                Text("Legal Data Sources")
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
                Text("Supra AI updates itself: new versions download in the background and install with a single restart — no browser, no drag-to-Applications. Update checks fetch only a signed version feed from supralegal.ai; no usage data is sent.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Check for updates automatically", isOn: $update.automaticallyChecksForUpdates)
                HStack {
                    Button("Check for Updates") { update.checkForUpdates() }
                        .disabled(!update.canCheckForUpdates)
                    Spacer()
                    if let message = update.statusMessage {
                        Text(message).font(.supraCaption).foregroundStyle(.secondary)
                    } else {
                        Text("You're on \(settings.appVersion.marketingVersion).")
                            .font(.supraCaption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Software Update")
            }

            Section {
                Text("Supra AI's research is grounded in free, public-interest data projects: CourtListener and the Free Law Project (case law), Open Legal Codes (statutes & codes), and OpenStates (legislation). Please consider creating a free account or otherwise supporting their work.")
                    .font(.callout).foregroundStyle(.secondary)
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
                Link(destination: URL(string: "https://openlegalcodes.org")!) {
                    Label("Open Legal Codes", systemImage: "text.book.closed")
                }
                Link(destination: URL(string: "https://openstates.org")!) {
                    Label("OpenStates", systemImage: "building.2")
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        // Larger, bolder section headers — consistent with the Models tab.
        .headerProminence(.increased)
        // A clearly-bordered box for every single-line field, so they're easy to
        // identify (cascades to all TextField/SecureField descendants; MultilineField
        // has its own border). Left-align the contents so text and spaces flow with
        // typing instead of the grouped form's default right alignment.
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func revealInFinder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// P2's deliberately compact backup surface. The card reads like a continuity
/// ledger — destination, last protected state, snapshot size, document count —
/// while folder choice and execution remain ordinary macOS controls.
private struct BackupSection: View {
    @ObservedObject var backup: BackupController

    var body: some View {
        Section {
            Text("Keep a restorable copy of your database and managed documents in a folder you control. Supra AI backs up when you ask and once on launch when the last successful copy is at least 24 hours old.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 34, height: 34)
                        .background(statusColor.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(statusTitle)
                                .font(.supraHeadline)
                            if backup.isBackingUp {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        Text(statusDetail)
                            .font(.supraCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if backup.destinationIsICloudDrive {
                        Label("iCloud Drive", systemImage: "icloud.fill")
                            .font(.supraCaption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                ledgerRow(label: "Destination", systemImage: "folder") {
                    Text(backup.destinationPath ?? "No folder chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ledgerRow(label: "Last backup", systemImage: "clock") {
                    Text(lastBackupText)
                        .monospacedDigit()
                }
                ledgerRow(label: "Snapshot", systemImage: "externaldrive") {
                    Text(snapshotText)
                        .monospacedDigit()
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(statusColor.opacity(0.25), lineWidth: 1)
            }

            if backup.shouldWarnAboutLargeFirstBackup {
                Label {
                    Text("Your managed documents use about \(formattedBytes(backup.estimatedSourceBytes)). The first backup may take a while; later runs copy only new documents.")
                } icon: {
                    Image(systemName: "externaldrive.badge.timemachine")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if backup.hasDestination, !backup.destinationIsICloudDrive {
                Label {
                    Text("This folder may exist only on this Mac. For off-site protection, choose iCloud Drive. If you use an external disk, keep it encrypted.")
                } icon: {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button(folderButtonTitle) { chooseFolder() }
                Button("Back Up Now") {
                    Task { await backup.backUpNow() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!backup.hasDestination || backup.isBackingUp)
                Spacer()
                Text("Keeps the newest 10 database snapshots; document blobs are incremental.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup")
        }
        .task { await backup.refreshEstimatedSourceSize() }
    }

    @ViewBuilder
    private func ledgerRow<Content: View>(
        label: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.supraCaption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            content()
                .font(.supraCaption)
            Spacer(minLength: 0)
        }
    }

    private var statusTitle: String {
        switch backup.state {
        case .unconfigured: "Backup not configured"
        case .ready: backup.lastSuccessAt == nil ? "Ready for first backup" : "Backup ready"
        case .backingUp: "Backing up"
        case .succeeded: "Backup complete"
        case .failed: "Backup needs attention"
        case .needsDestinationRepick: "Choose the folder again"
        }
    }

    private var statusDetail: String {
        if let message = backup.statusMessage { return message }
        if backup.lastSuccessAt != nil {
            return backup.isLastBackupStale
                ? "The last copy is more than 24 hours old."
                : "Database and managed documents have a current copy."
        }
        return "Choose a folder, then make the first copy."
    }

    private var statusSymbol: String {
        switch backup.state {
        case .unconfigured: "archivebox"
        case .ready: backup.lastSuccessAt == nil ? "archivebox" : "checkmark.shield.fill"
        case .backingUp: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .needsDestinationRepick: "folder.badge.questionmark"
        }
    }

    private var statusColor: Color {
        switch backup.state {
        case .succeeded: .green
        case .failed: .red
        case .needsDestinationRepick: .orange
        case .backingUp: .accentColor
        case .ready where backup.lastSuccessAt != nil && !backup.isLastBackupStale: .green
        case .ready where backup.isLastBackupStale: .orange
        default: .secondary
        }
    }

    private var lastBackupText: String {
        guard let date = backup.lastSuccessAt else { return "Not yet backed up" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var snapshotText: String {
        guard let bytes = backup.lastSnapshotBytes else { return "—" }
        let size = formattedBytes(Int64(bytes))
        if let documents = backup.lastReferencedBlobCount {
            return "\(size) · \(documents) document\(documents == 1 ? "" : "s")"
        }
        return size
    }

    private var folderButtonTitle: String {
        switch backup.state {
        case .needsDestinationRepick: "Choose Folder Again…"
        default: backup.hasDestination ? "Change Folder…" : "Choose Backup Folder…"
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Use for Backups"
        panel.message = "Choose a folder for Supra AI backups. iCloud Drive is recommended for an off-site copy."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = backup.configureDestination(bookmarkData: bookmark, url: url)
        } catch {
            backup.reportDestinationSelectionFailure(
                "The folder permission could not be saved. Choose a different folder."
            )
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
                Text("Supra AI").font(.supraHeadline)
                Text("Secure legal AI without compromise.")
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// One collapsible row in the consolidated "Legal Data Sources" group. Collapsed, it shows the
/// source name + a one-word status; expanded, it shows the update/currency note plus the relevant
/// controls. Handles three kinds: a keyed `APIKeyService`, the CourtListener token (its own store
/// methods), and a key-less "built in" source (free, no entry — just the description).
private struct APIKeyDisclosure: View {
    @ObservedObject var settings: SettingsController
    let title: String
    /// One line on coverage + how current the source is — shown when expanded.
    let description: String
    let kind: Kind
    @State private var entry = ""

    enum Kind {
        case service(APIKeyService, prompt: String, signupURL: URL)
        case courtListener(signupURL: URL)
        /// A free, key-less public source (eCFR / Federal Register / Open Legal Codes).
        /// `sourceID` drives the reachability "Verify" check.
        case builtIn(sourceID: String)
    }

    private var configured: Bool {
        switch kind {
        case let .service(service, _, _): settings.hasAPIKey(service)
        case .courtListener: settings.courtListenerTokenSource != .none
        case .builtIn: true
        }
    }

    private var isEnvironment: Bool {
        switch kind {
        case let .service(service, _, _): settings.isEnvironmentAPIKey(service)
        case .courtListener: settings.courtListenerTokenSource == .environment
        case .builtIn: false
        }
    }

    private var verificationState: SettingsController.KeyVerificationState {
        switch kind {
        case let .service(service, _, _): settings.verificationState(service)
        case .courtListener: settings.courtListenerVerification
        case .builtIn: .idle
        }
    }

    private var statusLabel: String {
        if case let .builtIn(sourceID) = kind {
            return settings.keylessVerificationState(sourceID) == .valid ? "Verified" : "Free · no key"
        }
        if isEnvironment { return "From environment" }
        return configured ? "Key saved" : "No key"
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(description)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                controls
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configured ? "checkmark.seal.fill" : "key.slash")
                    .foregroundStyle(configured ? .green : .orange)
                Text(title).font(.supraHeadline.weight(.medium))
                Spacer()
                Text(statusLabel).font(.supraCaption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch kind {
        case let .builtIn(sourceID):
            Text("Free · no key required.").font(.supraCaption).foregroundStyle(.secondary)
            HStack {
                Button("Verify") { Task { await settings.verifyKeylessSource(sourceID) } }
                    .disabled(settings.keylessVerificationState(sourceID) == .verifying)
                Spacer()
            }
            KeyVerificationStatusView(state: settings.keylessVerificationState(sourceID))
        case let .service(service, prompt, signupURL):
            keyControls(
                prompt: prompt, signupURL: signupURL,
                save: { settings.saveAPIKey($0, for: service) },
                clear: { settings.clearAPIKey(for: service) },
                verify: { await settings.verifyAPIKey(service) }
            )
        case let .courtListener(signupURL):
            keyControls(
                prompt: "CourtListener API token", signupURL: signupURL,
                save: { settings.saveCourtListenerToken($0) },
                clear: { settings.clearCourtListenerToken() },
                verify: { await settings.verifyCourtListenerToken() }
            )
        }
    }

    @ViewBuilder
    private func keyControls(
        prompt: String,
        signupURL: URL,
        save: @escaping (String) -> Void,
        clear: @escaping () -> Void,
        verify: @escaping () async -> Void
    ) -> some View {
        if isEnvironment {
            Text("Provided by the environment.").font(.supraCaption).foregroundStyle(.secondary)
            verifyButton(verify)
            KeyVerificationStatusView(state: verificationState)
        } else if configured {
            HStack {
                Button("Clear Key", role: .destructive) { clear() }
                Spacer()
                verifyButton(verify)
            }
            KeyVerificationStatusView(state: verificationState)
        } else {
            SecureField(prompt, text: $entry)
            HStack {
                Button("Save Key") { save(entry); entry = "" }
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
        // Always reachable — the app ships with no key preloaded.
        Link("Get a \(title) key…", destination: signupURL).font(.callout)
    }

    private func verifyButton(_ verify: @escaping () async -> Void) -> some View {
        Button("Verify Key") { Task { await verify() } }
            .disabled(verificationState == .verifying)
    }
}

/// Shared "Verify Key" outcome line, used by every API-key row and the CourtListener token.
private struct KeyVerificationStatusView: View {
    let state: SettingsController.KeyVerificationState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.supraCaption).foregroundStyle(.secondary)
            }
        case .valid:
            Label("Verified", systemImage: "checkmark.circle.fill")
                .font(.supraCaption).foregroundStyle(.green)
        case let .invalid(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.supraCaption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case let .unreachable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.supraCaption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ScratchPadBillingSection: View {
    @ObservedObject var billing: BillingSettingsController

    /// Common rounding increments offered in the picker (in hours).
    private static let increments: [Double] = [0.1, 0.2, 0.25, 0.5, 1.0]

    private var sensitivityLabel: String {
        BillingSensitivity(value: billing.sensitivity).rawValue.capitalized
    }

    var body: some View {
        Section {
            Text("Standing instructions applied to every billing draft. Per-matter rules (Matter → Billing) layer on top of these. “Narrative punctuation” normalizes how every billing narrative ends at export — a matter can override it.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Global billing instructions").font(.subheadline).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. No block billing; spell out abbreviations on first use; cap intra-office conferences",
                    text: $billing.globalInstructions
                )
            }
            Picker("Narrative punctuation", selection: $billing.narrativeTerminal) {
                ForEach(BillingNarrativeTerminal.allCases) { terminal in
                    Text(terminal.label).tag(terminal)
                }
            }
        } header: {
            Text("ScratchPad & Billing")
        }

        Section {
            Text("Auto-timestamp records when each note is written and uses the gaps as time evidence. Turn it off to rely on written cues instead. UTBMS auto-coding proposes task/activity codes you can always edit.")
                .font(.callout).foregroundStyle(.secondary)
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
                    Text("Precise").font(.supraCaption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Generous").font(.supraCaption).foregroundStyle(.secondary)
                }
                Text("How freely the engine infers durations. Precise bills only explicit, strong-evidence time; generous may infer implied workflow (e.g. research before drafting). Guardrails always apply — nothing is fabricated without a basis.")
                    .font(.callout).foregroundStyle(.secondary)
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
        }
        // The former "Timekeeper & Firm" section now lives inside Profile & Firm Identity.
    }
}

// `LabeledTextField` / `LeadingTextField` now live in `MultilineField.swift` (shared
// across Settings, Edit Matter, and drafting — spec §9.3).

/// Editor for the attorney's bar admissions (multi-jurisdiction). Each row is a
/// jurisdiction + bar number; one is marked primary (★). At draft time the admission
/// matching a filing's court prints on its signature block, falling back to primary.
private struct BarLicensesEditor: View {
    @Binding var profile: AssistantProfile

    private func isPrimary(_ license: AssistantProfile.BarLicense) -> Bool {
        if !profile.primaryBarLicenseID.isEmpty {
            return profile.primaryBarLicenseID == license.id
        }
        return profile.barLicenses.first?.id == license.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($profile.barLicenses) { $license in
                HStack(spacing: 8) {
                    Picker("Jurisdiction", selection: $license.jurisdictionID) {
                        Text("Select jurisdiction…").tag("")
                        ForEach(BarJurisdictionCatalog.all) { jurisdiction in
                            Text(jurisdiction.displayName).tag(jurisdiction.id)
                        }
                        // Preserve an unlisted/custom value so it isn't lost.
                        if !license.jurisdictionID.isEmpty,
                           BarJurisdictionCatalog.jurisdiction(id: license.jurisdictionID) == nil {
                            Text(license.jurisdictionID).tag(license.jurisdictionID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    LeadingTextField(text: $license.barNumber, placeholder: "Bar number")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    Button {
                        profile.primaryBarLicenseID = license.id
                        profile.barNumber = ""
                    } label: {
                        Image(systemName: isPrimary(license) ? "star.fill" : "star")
                            .foregroundStyle(isPrimary(license) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mark as primary for supported drafting paths")
                    Button {
                        let removedPrimary = profile.primaryBarLicenseID == license.id
                        profile.barLicenses.removeAll { $0.id == license.id }
                        if removedPrimary || !profile.barLicenses.contains(where: { $0.id == profile.primaryBarLicenseID }) {
                            profile.primaryBarLicenseID = profile.barLicenses.first?.id ?? ""
                        }
                        profile.barNumber = ""
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this admission")
                    // The last row carries an inline "+" that appends a new admission,
                    // replacing the separate Add button.
                    if license.id == profile.barLicenses.last?.id {
                        Button { appendLicense() } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Add another admission")
                    }
                }
            }
            // With no admissions saved yet, offer a single add affordance to start.
            if profile.barLicenses.isEmpty {
                Button { appendLicense() } label: {
                    Label("Add bar admission", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }

    private func appendLicense() {
        let license = AssistantProfile.BarLicense(jurisdictionID: "", barNumber: "")
        profile.barLicenses.append(license)
        if profile.primaryBarLicenseID.isEmpty { profile.primaryBarLicenseID = license.id }
        profile.barNumber = ""
    }
}

/// The "Assistant Profile": plain-language inputs about who you are, how you write,
/// and how you cite, plus samples of your own writing. These are combined into the
/// system prompt the assistant follows on every response. Written for a legal
/// audience — no machine-learning jargon.
private struct AssistantProfileSection: View {
    @ObservedObject var profile: AssistantProfileController
    @ObservedObject var billing: BillingSettingsController
    @State private var isImportingSample = false
    @State private var showPreview = false

    /// File types accepted for writing samples (handled by the extraction service).
    private static let sampleTypes: [UTType] = {
        var types: [UTType] = [.pdf, .rtf, .plainText, .text]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        if let doc = UTType("com.microsoft.word.doc") { types.append(doc) }
        return types
    }()

    /// Bridges the `[String]` secondary-email list to a single-line field: designations
    /// are separated by semicolons (per 2.516, ≤2 are used).
    private var secondaryEmailsBinding: Binding<String> {
        Binding(
            get: { profile.profile.secondaryEmails.joined(separator: "; ") },
            set: { newValue in
                profile.profile.secondaryEmails = newValue
                    .split(separator: ";", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// Fills the LEDES timekeeper name/classification from the profile above when they
    /// are blank (still editable). Classification uppercases the role to match LEDES
    /// code conventions (e.g. "Associate" -> "ASSOCIATE"). Only fills blanks, so a
    /// value the user typed is never overwritten.
    private func syncTimekeeperDefaults() {
        let name = profile.profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if billing.timekeeperName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.isEmpty {
            billing.timekeeperName = name
        }
        let role = profile.profile.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if billing.timekeeperClassification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !role.isEmpty {
            billing.timekeeperClassification = role.uppercased()
        }
    }

    var body: some View {
        Section {
            // One VStack owns the whole section so the grouped Form doesn't draw a
            // separator between every field; spacing here controls the vertical rhythm.
            VStack(alignment: .leading, spacing: 12) {
            Text("Who you are and your firm details — this shapes how the assistant writes for you and fills the signature block and letterhead of documents you draft. Everything is optional; blank drafting fields are asked for rather than guessed. Notice of Appearance drafting is currently Florida-only and uses Florida service designations (Fla. R. Jud. Admin. 2.516); when several admissions are saved, the Florida admission prints on that filing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Identity — paired two-up.
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Full name", text: $profile.profile.fullName)
                LabeledTextField(label: "Firm or organization", text: $profile.profile.organization)
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Role or title", text: $profile.profile.role, prompt: "e.g. Partner, Associate, Paralegal")
                LabeledTextField(label: "Jurisdictions", text: $profile.profile.jurisdictions, prompt: "e.g. California state and the Ninth Circuit")
            }
            LabeledTextField(label: "Practice areas", text: $profile.profile.practiceAreas, prompt: "e.g. Commercial litigation, employment")

            // Office address.
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Office street", text: $profile.profile.officeStreet, prompt: "e.g. 200 West Forsyth Street")
                LabeledTextField(label: "Suite / floor (optional)", text: $profile.profile.officeSuite, prompt: "e.g. Suite 1400").frame(width: 180)
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "City", text: $profile.profile.officeCity)
                LabeledTextField(label: "State", text: $profile.profile.officeState).frame(width: 72)
                LabeledTextField(label: "ZIP", text: $profile.profile.officeZip).frame(width: 96)
            }
            // Contact — the office line split into main / direct / cell, plus fax.
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Main", text: $profile.profile.officePhone, prompt: "e.g. (904) 555-0142")
                LabeledTextField(label: "Direct", text: $profile.profile.officePhoneDirect, prompt: "e.g. (904) 555-0143")
                LabeledTextField(label: "Cell", text: $profile.profile.officeCell, prompt: "e.g. (904) 555-0199")
                LabeledTextField(label: "Facsimile", text: $profile.profile.officeFax, prompt: "e.g. (904) 555-0100")
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Primary service e-mail", text: $profile.profile.primaryEmail, prompt: "e.g. hspecter@psl.com")
                LabeledTextField(label: "Secondary service e-mails (separate with ;)", text: secondaryEmailsBinding, prompt: "e.g. litdocket@psl.com; paralegal@psl.com")
            }

            // Bar admissions and the LEDES billing identity fill an even two-column grid
            // so a short column never leaves a tall empty gap beside a taller one.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bar admissions").font(.subheadline).foregroundStyle(.secondary)
                    BarLicensesEditor(profile: $profile.profile)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LabeledTextField(label: "Timekeeper name", text: $billing.timekeeperName, prompt: "e.g. H. Specter")
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Timekeeper ID", text: $billing.timekeeperID, prompt: "e.g. TK-1001")
                LabeledTextField(label: "Firm ID (LAW_FIRM_ID)", text: $billing.lawFirmID, prompt: "e.g. 98-7654321")
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledTextField(label: "Classification", text: $billing.timekeeperClassification, prompt: "e.g. PARTNER, ASSOCIATE")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Default rate").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Rate", value: $billing.timekeeperRate, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("/ hr").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
                .fixedSize()
            }
            Text("Timekeeper name & classification (LEDES) default from your details above (still editable); export also needs the rate, Timekeeper ID, and Firm ID.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Profile & Firm Identity")
        }
        .onAppear { syncTimekeeperDefaults() }
        .onChange(of: profile.profile.fullName) { _, _ in syncTimekeeperDefaults() }
        .onChange(of: profile.profile.role) { _, _ in syncTimekeeperDefaults() }

        Section {
            Text("Shapes how the assistant writes for you — how formal, how long, and any habits you prefer.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Tone", selection: $profile.profile.formality) {
                ForEach(AssistantProfile.Formality.allCases) { Text($0.label).tag($0) }
            }
            Picker("Default length", selection: $profile.profile.length) {
                ForEach(AssistantProfile.Length.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Style notes").font(.subheadline).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. Lead with the bottom line, avoid legalese, use IRAC for analysis",
                    text: $profile.profile.voiceNotes
                )
            }
        } header: {
            Text("Writing Style")
        }

        Section {
            Text("How you want authorities cited. The assistant follows this when it references cases, statutes, or rules.")
                .font(.callout).foregroundStyle(.secondary)
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
                Text(style.guidance).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Citation notes").font(.subheadline).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "e.g. Always pin-cite; include parallel cites; short form after first reference",
                    text: $profile.profile.citationNotes
                )
            }
        } header: {
            Text("Citations")
        }

        Section {
            Text("Standing instructions you'd give a new associate. These apply to every response.")
                .font(.callout).foregroundStyle(.secondary)
            MultilineField(
                placeholder: "e.g. Flag missing facts; caveat firm conclusions; prefer primary sources",
                text: $profile.profile.additionalInstructions
            )
        } header: {
            Text("Other Instructions")
        }

        Section {
            Text("Add a brief, motion, or letter you've written. The assistant studies its voice and formatting to match your style — it won't reuse the content. Accepts PDF, Word, RTF, or text.")
                .font(.callout).foregroundStyle(.secondary)
            if profile.profile.writingSamples.isEmpty {
                Text("No samples added yet.").font(.supraCaption).foregroundStyle(.secondary)
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
            Text("Everything above is combined into the instructions the assistant follows. Your changes save automatically as you type.")
                .font(.supraCaption).foregroundStyle(.secondary)
            if let message = profile.message {
                Text(message).font(.supraCaption).foregroundStyle(.secondary)
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
        }
    }
}

/// Guided embedding-model setup flow: 1) download a curated or custom model, then
/// 2) select it for use. Selecting (or finishing a download) auto-verifies the
/// model by loading it into the runtime — no manual test-load. Shown in the Models tab.
struct EmbeddingModelSetupView: View {
    @ObservedObject var setup: DocumentIntelligenceSetupController
    @ObservedObject var downloader: EmbeddingModelDownloadController
    @State private var downloadSelection = ""
    @State private var customRepoID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(number: 1, title: "Download a model") {
                Picker("Embedding model to download", selection: $downloadSelection) {
                    Text("Choose a curated model…").tag("")
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
                HStack {
                    TextField("or a custom repo ID, e.g. mlx-community/Qwen3-Embedding-4B-4bit-DWQ", text: $customRepoID)
                        .textFieldStyle(.roundedBorder)
                    Button("Download") { downloadCustom() }
                        .disabled(downloader.isBusy || customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                downloadStatus
            }

            step(number: 2, title: "Select for use", enabled: !setup.availableEmbeddingModels.isEmpty) {
                if setup.availableEmbeddingModels.isEmpty {
                    Text("No embedding models downloaded yet.")
                        .font(.supraCaption).foregroundStyle(.secondary)
                } else {
                    Picker("Active embedding model", selection: activeSelection) {
                        ForEach(setup.availableEmbeddingModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    verifyStatus
                }
            }

            if let message = setup.message {
                Text(message).font(.supraCaption).foregroundStyle(.orange)
            }
        }
    }

    /// Inline verification status for the selected model: verifying / ready (with the
    /// confirmed dimension) / failed. Replaces the old manual "Test Load" step.
    @ViewBuilder private var verifyStatus: some View {
        if let selected = setup.selectedEmbeddingModel {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if setup.embeddingVerifyInFlight {
                    ProgressView().controlSize(.small)
                    Text("Verifying \(selected.displayName)…")
                } else if setup.embeddingTestPassed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready (\(selected.dimension)-d)")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(selected.displayName) didn't load. Try another model.")
                }
            }
            .font(.supraCaption).foregroundStyle(.secondary)
        }
    }

    private var activeSelection: Binding<String> {
        Binding(
            get: { setup.selectedEmbeddingModel?.id ?? "" },
            set: { newID in Task { await setup.selectAndVerifyEmbeddingModel(id: newID) } }
        )
    }

    /// Starts a custom Hugging Face embedding download. The dimension is unknown up
    /// front (registered as 0) and discovered when the model auto-verifies.
    private func downloadCustom() {
        let trimmed = customRepoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = String(trimmed.split(separator: "/").last ?? Substring(trimmed))
        downloader.download(
            repoID: trimmed,
            displayName: name,
            dimension: 0,
            runtimeFamily: "",
            selectAfterDownload: true
        )
        customRepoID = ""
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

    @ViewBuilder private var downloadStatus: some View {
        switch downloader.state {
        case .preparing(let repo):
            Text("Preparing \(repo)…").font(.supraCaption).foregroundStyle(.secondary)
        case let .downloading(_, completed, total, file):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("\(completed)/\(total) files — \(file)").font(.supraCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case let .finished(_, name):
            Text("Downloaded \(name). Verifying it below…").font(.supraCaption).foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.supraCaption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

/// Settings section for the firm's structural document style (Track A): the letterhead,
/// caption, signature-block, and certificate wording/geometry that render deterministically
/// into every draft. Every field is optional — blank ⇒ the Florida house default, shown as the
/// field's placeholder — and every edit autosaves through `FirmStyleProfileController`. Font
/// size and margins are floor-clamped to Fla. R. Jud. Admin. 2.520(a) (≥ 12 pt, ≥ 1″) before
/// any render, so nothing set here can make a filing non-compliant.
///
/// M2-T2 (manual gate — no app unit-test target): persistence rides the tested
/// `FirmStyleProfileController` (T-PERSIST-*), and application rides `effectiveStyle()`
/// (T-CTRL-01..05). The rendered .docx preview ships with M3-T3.
private struct FirmStyleSection: View {
    @ObservedObject var firmStyle: FirmStyleProfileController
    /// Resolves the drafting model and parses an exemplar into a candidate profile (M3).
    let parseExemplar: @MainActor (ExemplarKind, URL) async -> ExemplarParseOutcome

    @State private var exemplarKind: ExemplarKind = .letterhead
    @State private var isImportingExemplar = false
    @State private var isParsing = false
    @State private var parseOutcome: ExemplarParseOutcome?

    /// File types accepted for exemplars (same set the writing-sample importer handles).
    private static let exemplarTypes: [UTType] = {
        var types: [UTType] = [.pdf, .rtf, .plainText, .text]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        if let doc = UTType("com.microsoft.word.doc") { types.append(doc) }
        return types
    }()

    /// Bridges an optional override to a text field: blank ⇄ nil (inherit the house default).
    private func text(_ keyPath: WritableKeyPath<FirmStyleProfile, String?>) -> Binding<String> {
        Binding(
            get: { firmStyle.profile[keyPath: keyPath] ?? "" },
            set: { firmStyle.profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Bridges an optional toggle: nil reads as the house default (`true` for all of these).
    private func flag(_ keyPath: WritableKeyPath<FirmStyleProfile, Bool?>) -> Binding<Bool> {
        Binding(
            get: { firmStyle.profile[keyPath: keyPath] ?? true },
            set: { firmStyle.profile[keyPath: keyPath] = $0 }
        )
    }

    private var hasOverrides: Bool { firmStyle.profile != FirmStyleProfile() }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("How your firm's documents are put together — letterhead wording, caption labels, signature-block labels, and the certificate of service. These are structural settings applied mechanically to every draft (they never pass through the model). Leave a field blank to use the Florida house default shown in gray. Font size and margins can never go below the Fla. R. Jud. Admin. 2.520(a) floor (12 pt, 1″ margins).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Letterhead (letters only).
                Text("Letterhead").font(.headline)
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Tagline", text: text(\.letterheadTagline), prompt: "Attorneys at Law")
                    LabeledTextField(label: "RE: label", text: text(\.letterheadRELabel), prompt: "RE:")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Phone label", text: text(\.letterheadPhoneLabel), prompt: "Telephone: ")
                    LabeledTextField(label: "Fax label", text: text(\.letterheadFaxLabel), prompt: "Facsimile: ")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Enclosure prefix", text: text(\.letterheadEnclosurePrefix), prompt: "Enclosure: ")
                    LabeledTextField(label: "cc prefix", text: text(\.letterheadCCPrefix), prompt: "cc:  ")
                }
                Toggle("Rule under the letterhead", isOn: flag(\.letterheadBottomRule))

                // Caption (court filings).
                Text("Caption").font(.headline)
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Case number label", text: text(\.captionCaseNumberLabel), prompt: "CASE NO.: ")
                    LabeledTextField(label: "Division label", text: text(\.captionDivisionLabel), prompt: "DIVISION: ")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Judge label", text: text(\.captionJudgeLabel), prompt: "JUDGE: ")
                    LabeledTextField(label: "Party separator", text: text(\.captionPartySeparator), prompt: "v.")
                }
                Toggle("Court header bold and centered", isOn: flag(\.captionHeaderBoldCentered))
                Toggle("End the party box with the closing rule", isOn: flag(\.captionClosingRuleEndsInSlash))

                // Signature block.
                Text("Signature Block").font(.headline)
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Signature prefix", text: text(\.signatureByPrefix), prompt: "By: ")
                    LabeledTextField(label: "E-signature mark", text: text(\.signatureESignatureMark), prompt: "/s/ ")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Representation prefix", text: text(\.signatureRepresentationPrefix), prompt: "Attorneys for ")
                    LabeledTextField(label: "Bar number label", text: text(\.signatureBarNumberLabel), prompt: "(none)")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledTextField(label: "Phone label", text: text(\.signaturePhoneLabel), prompt: "Telephone: ")
                    LabeledTextField(label: "Fax label", text: text(\.signatureFaxLabel), prompt: "Facsimile: ")
                }
                Toggle("Firm name in bold capitals", isOn: flag(\.signatureFirmNameBoldCaps))
                Toggle("\u{201C}Attorneys for\u{201D} line in italics", isOn: flag(\.signatureRepresentationLineItalic))

                // Certificate of service.
                Text("Certificate of Service").font(.headline)
                LabeledTextField(label: "Heading", text: text(\.certificateHeading), prompt: "CERTIFICATE OF SERVICE")

                // Learn from an exemplar (M3): parsed ONCE into the reviewable fields below —
                // the document's text never becomes prompt context and identity is never captured.
                Text("Learn From an Exemplar").font(.headline)
                Text("Upload a document that shows just your letterhead, caption, or signature block. The style labels are read out of it once for you to review — names, numbers, and addresses are never captured, and the document itself is not kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Picker("Element", selection: $exemplarKind) {
                        Text("Letterhead").tag(ExemplarKind.letterhead)
                        Text("Caption").tag(ExemplarKind.caption)
                        Text("Signature block").tag(ExemplarKind.signature)
                    }
                    .frame(maxWidth: 260)
                    Button(isParsing ? "Reading exemplar…" : "Upload exemplar…") {
                        isImportingExemplar = true
                    }
                    .disabled(isParsing)
                    Spacer()
                    Button("Preview a sample filing…") { openPreview() }
                }
                if let outcome = parseOutcome {
                    VStack(alignment: .leading, spacing: 8) {
                        if let message = outcome.message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                        if capturedFields.isEmpty {
                            Text("No style fields were captured — set your choices manually above.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Captured from the exemplar — review, then apply:").font(.callout)
                            ForEach(capturedFields, id: \.label) { field in
                                HStack {
                                    Text(field.label).font(.callout).foregroundStyle(.secondary)
                                    Text("\u{201C}\(field.value)\u{201D}").font(.system(.callout, design: .monospaced))
                                }
                            }
                            HStack {
                                Button("Apply to firm style") { apply(outcome.candidate) }
                                Button("Discard") { parseOutcome = nil }
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                }

                if firmStyle.message != nil || hasOverrides {
                    HStack {
                        if let message = firmStyle.message {
                            Text(message).font(.callout).foregroundStyle(.red)
                        }
                        Spacer()
                        if hasOverrides {
                            Button("Reset to house defaults", role: .destructive) {
                                firmStyle.profile = FirmStyleProfile()
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Firm Style")
        }
        .fileImporter(isPresented: $isImportingExemplar,
                      allowedContentTypes: Self.exemplarTypes,
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task {
                    isParsing = true
                    let accessed = url.startAccessingSecurityScopedResource()
                    parseOutcome = await parseExemplar(exemplarKind, url)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    isParsing = false
                }
            }
        }
    }

    /// The candidate's captured (non-nil) fields for the review list.
    private var capturedFields: [(label: String, value: String)] {
        guard let c = parseOutcome?.candidate else { return [] }
        var rows: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) {
            if let value { rows.append((label, value)) }
        }
        add("Tagline", c.letterheadTagline)
        add("Letterhead phone label", c.letterheadPhoneLabel)
        add("Letterhead fax label", c.letterheadFaxLabel)
        add("RE: label", c.letterheadRELabel)
        add("Enclosure prefix", c.letterheadEnclosurePrefix)
        add("cc prefix", c.letterheadCCPrefix)
        add("Party separator", c.captionPartySeparator)
        add("Case number label", c.captionCaseNumberLabel)
        add("Division label", c.captionDivisionLabel)
        add("Judge label", c.captionJudgeLabel)
        add("Signature prefix", c.signatureByPrefix)
        add("E-signature mark", c.signatureESignatureMark)
        add("Representation prefix", c.signatureRepresentationPrefix)
        add("Bar number label", c.signatureBarNumberLabel)
        add("Signature phone label", c.signaturePhoneLabel)
        add("Signature fax label", c.signatureFaxLabel)
        return rows
    }

    /// Confirm: merge only the fields the exemplar captured into the saved profile (one
    /// assignment ⇒ one autosave via the controller's didSet), leaving unrelated overrides alone.
    private func apply(_ candidate: FirmStyleProfile) {
        var updated = firmStyle.profile
        if let v = candidate.letterheadTagline { updated.letterheadTagline = v }
        if let v = candidate.letterheadPhoneLabel { updated.letterheadPhoneLabel = v }
        if let v = candidate.letterheadFaxLabel { updated.letterheadFaxLabel = v }
        if let v = candidate.letterheadRELabel { updated.letterheadRELabel = v }
        if let v = candidate.letterheadEnclosurePrefix { updated.letterheadEnclosurePrefix = v }
        if let v = candidate.letterheadCCPrefix { updated.letterheadCCPrefix = v }
        if let v = candidate.captionPartySeparator { updated.captionPartySeparator = v }
        if let v = candidate.captionCaseNumberLabel { updated.captionCaseNumberLabel = v }
        if let v = candidate.captionDivisionLabel { updated.captionDivisionLabel = v }
        if let v = candidate.captionJudgeLabel { updated.captionJudgeLabel = v }
        if let v = candidate.signatureByPrefix { updated.signatureByPrefix = v }
        if let v = candidate.signatureESignatureMark { updated.signatureESignatureMark = v }
        if let v = candidate.signatureRepresentationPrefix { updated.signatureRepresentationPrefix = v }
        if let v = candidate.signatureBarNumberLabel { updated.signatureBarNumberLabel = v }
        if let v = candidate.signaturePhoneLabel { updated.signaturePhoneLabel = v }
        if let v = candidate.signatureFaxLabel { updated.signatureFaxLabel = v }
        firmStyle.profile = updated
        parseOutcome = nil
    }

    /// Renders the fictional sample notice under the current effective sheet and opens it.
    private func openPreview() {
        do {
            let data = try firmStyle.previewDocx()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Firm-Style-Preview-\(UUID().uuidString)")
                .appendingPathExtension("docx")
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            firmStyle.message = "Couldn't render the preview. \(error.localizedDescription)"
        }
    }
}
