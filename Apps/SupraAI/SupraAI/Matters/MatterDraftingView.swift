import AppKit
import CryptoKit
import SupraCore
import SupraDraftingCore
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// The chat-side drafting sheet. Caption, represented-side, opposing-side, and
/// service values are loaded from one Store-owned canonical identity snapshot;
/// the view never invents them from legacy matter strings.
struct MatterDraftingView: View {
    @ObservedObject var controller: MatterDraftingController
    @ObservedObject var library: ModelLibrary
    let matterID: String
    let matterName: String
    @Environment(\.dismiss) private var dismiss

    // Caption parties (e.g. "MCKERNON MOTORS, INC.," / "Plaintiff,").
    @State private var parties: [PartyDraft] = []
    @State private var partyRepresented = ""
    @State private var representedPartyName = ""

    // Service recipients (opposing counsel).
    @State private var recipients: [RecipientDraft] = []
    @State private var canonicalPartyDefaults: DraftPartyDefaults?
    @State private var partyDefaultsError: String?

    @State private var result: MatterDraftingController.DraftArtifact?
    @State private var errorText: String?

    // Work-product selection (the picker) + custom-description inputs.
    @State private var selection: WorkProductSelection = .kind(.noticeAppearance)
    @State private var availableKinds: [DraftKindAvailability] = []
    @State private var customTitle = ""
    @State private var customDescription = ""
    @State private var customInstructions = ""

    // Demand-letter inputs.
    @State private var letterRecipientName = ""
    @State private var letterRecipientFirm = ""
    @State private var letterStreet = ""
    @State private var letterCity = ""
    @State private var letterState = "Florida"
    @State private var letterZip = ""
    @State private var letterReSubject = ""
    @State private var letterClaim = ""
    @State private var letterAmount = ""
    @State private var letterDeadline = ""
    @State private var letterTone = "firm"
    @State private var letterDelivery = ""
    @State private var routingMessage: String?

    // Supported Florida motion inputs and exact source selections.
    @State private var motionRespondingTo = ""
    @State private var motionRelief = ""
    @State private var motionFactSources: [MotionDraftFactSource] = []
    @State private var motionAuthoritySources: [MotionDraftAuthoritySource] = []
    @State private var motionFactLoadError: String?
    @State private var motionAuthorityLoadError: String?
    @State private var selectedMotionFactIDs: Set<String> = []
    @State private var selectedMotionAuthorityIDs: Set<String> = []
    @State private var generationTask: Task<Void, Never>?
    @State private var generationToken: UUID?
#if DEBUG
    /// Retains the URL supplied by the validated recovery row so the hosted
    /// test can re-read the identical managed artifact after acknowledgement.
    @State private var interruptedDraftRecoveryUITestRecoveredURL: URL?
#endif

    private enum WorkProductSelection: Hashable {
        case kind(DraftKindID)
        case custom
    }

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }
    private var draftRoute: ModelRoute { router.route(for: .drafting) }
    private var routeModel: ModelSummary? {
        library.resolvedModel(for: draftRoute.role, configuration: router.configuration)
    }

    private struct PartyDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var designation: String
    }

    private struct RecipientDraft: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var firm = ""
        var street = ""
        var city = ""
        var state = ""
        var zip = ""
        var emails = ""
        var role = ""
    }

    init(
        controller: MatterDraftingController,
        library: ModelLibrary,
        matterID: String,
        matterName: String
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        _library = ObservedObject(wrappedValue: library)
        self.matterID = matterID
        self.matterName = matterName

    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if !controller.interruptedDraftRecoveries.isEmpty {
                    interruptedDraftRecoverySection
                }
#if DEBUG
                if let evidence = interruptedDraftRecoveryUITestEvidence {
                    Text("Recovery fixture evidence")
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .clipped()
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("drafting.interruptedRecovery.fixtureEvidence")
                        // macOS can omit the value of a clipped SwiftUI Text from
                        // the hosted accessibility snapshot. Keep the validated,
                        // content-free fixture facts in the label, which remains
                        // queryable even when this DEBUG-only marker is offscreen.
                        .accessibilityLabel(evidence)
                }
#endif
                if controller.legacyDraftsNeedReviewCount > 0 {
                    legacyDraftReviewSection
                }
                canonicalIdentitySection
                workProductSection
                    .disabled(isWorking)
                selectedForm
                    .disabled(isWorking)
                if let result {
                    resultSection(result)
                }
            }
            .formStyle(.grouped)
            if let errorText {
                Divider()
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.supraCaption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("drafting.blocked")
                    .accessibilityLabel("Draft generation blocked. \(errorText)")
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: 640)
        .onAppear {
            library.refresh()
            controller.refreshDraftReviewState(matterID: matterID)
            loadCanonicalPartyDefaults()
#if DEBUG
            captureInterruptedDraftRecoveryUITestURLIfNeeded()
#endif
            if availableKinds.isEmpty { availableKinds = controller.availableDraftKinds() }
            if selection == .kind(.motionToDismiss) { loadMotionSourcesIfNeeded() }
        }
#if DEBUG
        .onChange(of: controller.interruptedDraftRecoveries) { _, _ in
            captureInterruptedDraftRecoveryUITestURLIfNeeded()
        }
#endif
        // The result/error banner belongs to one work product — clear it when the
        // user switches to a different kind so a stale notice result doesn't linger
        // over the custom form (and vice versa).
        .onChange(of: selection) { _, _ in
            if isWorking { invalidateGeneration() }
            result = nil
            errorText = nil
            routingMessage = nil
            if selection == .kind(.letterDemand), !AppEnvironment.isUITestMode {
                library.prewarm(role: .drafting)
            }
            if selection == .kind(.motionToDismiss) { loadMotionSourcesIfNeeded() }
        }
        .onDisappear { invalidateGeneration() }
        .interactiveDismissDisabled(isWorking)
    }

#if DEBUG
    private func captureInterruptedDraftRecoveryUITestURLIfNeeded() {
        guard interruptedDraftRecoveryUITestRecoveredURL == nil,
              AppEnvironment.interruptedDraftRecoveryUITestManagedRoot != nil
        else { return }
        let recoveredURLs = controller.interruptedDraftRecoveries.compactMap(\.fileURL)
        guard recoveredURLs.count == 1 else { return }
        interruptedDraftRecoveryUITestRecoveredURL = recoveredURLs[0]
    }

    /// Content-free evidence for the one exact hosted recovery scenario. The
    /// value intentionally exposes neither an absolute local path nor contents.
    private var interruptedDraftRecoveryUITestEvidence: String? {
        guard let recoveredURL = interruptedDraftRecoveryUITestRecoveredURL?
                .standardizedFileURL
                .resolvingSymlinksInPath(),
              let authorizedRoot = AppEnvironment.interruptedDraftRecoveryUITestManagedRoot,
              let matterUUID = UUID(uuidString: matterID),
              matterID == matterUUID.uuidString
        else { return nil }

        let managedRoot = authorizedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let testStoreRoot = managedRoot
            .appendingPathComponent(".supra-ui-test-store", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let exportsRoot = managedRoot
            .appendingPathComponent("exports", isDirectory: true)
            .standardizedFileURL
        let matterRoot = exportsRoot
            .appendingPathComponent(matterUUID.uuidString, isDirectory: true)
            .standardizedFileURL
        let expectedRecoveredURL = matterRoot
            .appendingPathComponent("Interrupted-publication.md", isDirectory: false)
            .standardizedFileURL
        guard recoveredURL.path == expectedRecoveredURL.path,
              recoveredURL.deletingLastPathComponent().path == matterRoot.path,
              recoveredURL.path.hasPrefix("\(exportsRoot.path)/")
        else { return nil }

        guard let enumerator = FileManager.default.enumerator(
            at: managedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }

        var regularArtifactCount = 0
        for case let rawArtifactURL as URL in enumerator {
            let artifactURL = rawArtifactURL.standardizedFileURL.resolvingSymlinksInPath()
            if artifactURL.path == testStoreRoot.path {
                enumerator.skipDescendants()
                continue
            }
            guard !artifactURL.path.hasPrefix("\(testStoreRoot.path)/"),
                  artifactURL.path.hasPrefix("\(managedRoot.path)/"),
                  let values = try? rawArtifactURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isSymbolicLink != true
            else { return nil }
            if values.isRegularFile == true {
                regularArtifactCount += 1
            }
        }

        guard let recoveredBytes = try? Data(contentsOf: recoveredURL) else { return nil }
        let digest = SHA256.hash(data: recoveredBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "relative=exports/\(matterUUID.uuidString)/Interrupted-publication.md|bytes=\(recoveredBytes.count)|sha256=\(digest)|regularCount=\(regularArtifactCount)"
    }
#endif

    private var interruptedDraftRecoverySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 7) {
                Label("Interrupted draft files are recovery-required", systemImage: "exclamationmark.triangle.fill")
                    .font(.supraHeadline)
                    .foregroundStyle(.orange)
                Text("These unverified files were preserved because publication could not be authenticated. Do not rely on them as completed work. Review the named files, then regenerate anything you plan to use.")
                    .font(.supraCaption)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(controller.interruptedDraftRecoveries) { recovery in
                    HStack {
                        Text(recovery.fileName ?? "Interrupted draft details unavailable")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let fileURL = recovery.fileURL {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            }
                            .accessibilityIdentifier("drafting.interruptedRecovery.reveal.\(recovery.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("drafting.interruptedRecovery.item.\(recovery.id)")
                    .accessibilityLabel(
                        recovery.fileName.map { "Recovery-required draft file \($0)" }
                            ?? "Recovery-required interrupted draft with unavailable details"
                    )
                }
                Button("I Understand — Regenerate Before Use") {
                    controller.confirmInterruptedDraftArtifactsReviewed(matterID: matterID)
                }
                .accessibilityHint("Records your review without opening, moving, or deleting any preserved file")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drafting.interruptedRecoveryWarning")
        }
    }

    private var legacyDraftReviewSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Previous draft artifacts need review")
                        .font(.supraHeadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(controller.legacyDraftsNeedReviewCount) artifact(s) were generated before the current pre-render verification gate. Review Activity and exports, and regenerate anything you plan to use.")
                        .font(.supraCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("I Reviewed Them") {
                    controller.confirmLegacyDraftArtifactsReviewed(matterID: matterID)
                }
                .accessibilityHint("Records review without deleting the prior files")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drafting.legacyReviewWarning")
            .accessibilityLabel("Draft artifact review required")
            .accessibilityValue("\(controller.legacyDraftsNeedReviewCount) previous artifact(s) need review or regeneration before use.")
        }
    }

    @ViewBuilder
    private var canonicalIdentitySection: some View {
        Section {
            if let defaults = canonicalPartyDefaults {
                Text("\(defaults.representedClientName) — \(defaults.representedDesignation)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("drafting.identity.representedClient")
                    .accessibilityLabel("Represented client")
                    .accessibilityValue(
                        "\(defaults.representedClientName)|\(defaults.representedDesignation)"
                    )
                Text("\(defaults.opposingPartyName) — \(defaults.opposingDesignation)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("drafting.identity.opponent")
                    .accessibilityLabel("Opposing party")
                    .accessibilityValue(defaults.opposingPartyName)
                Text("\(defaults.serviceRecipient.name) — \(defaults.serviceRecipient.role)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("drafting.identity.serviceRecipient")
                    .accessibilityLabel("Service recipient")
                    .accessibilityValue(
                        "\(defaults.serviceRecipient.name)|\(defaults.serviceRecipient.role)"
                    )
            } else {
                Label(
                    partyDefaultsError
                        ?? "Canonical party and service identity is unavailable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("drafting.identity.blocked")
            }
        } header: {
            Text("Matter identity")
        } footer: {
            Text("Court filings use the exact structured parties and service recipient saved with this matter. Edit the matter identity to correct them.")
        }
    }

    private func loadCanonicalPartyDefaults() {
        do {
            let defaults = try controller.draftPartyDefaults(matterID: matterID)
            canonicalPartyDefaults = defaults
            partyDefaultsError = nil
            parties = defaults.captionParties.map {
                PartyDraft(name: $0.name, designation: $0.designation)
            }
            partyRepresented = defaults.representedDesignation
            representedPartyName = defaults.representedClientName
            recipients = [recipientDraft(from: defaults.serviceRecipient)]
        } catch {
            canonicalPartyDefaults = nil
            parties = []
            partyRepresented = ""
            representedPartyName = ""
            recipients = []
            partyDefaultsError = "Choose coherent structured parties and opposing counsel in the matter before drafting a court filing."
        }
    }

    private func recipientDraft(from recipient: ServiceRecipient) -> RecipientDraft {
        var draft = RecipientDraft()
        draft.name = recipient.name
        draft.firm = recipient.firm
        draft.street = recipient.address.street
        draft.city = recipient.address.city
        draft.state = recipient.address.state
        draft.zip = recipient.address.zip
        draft.emails = recipient.emails.joined(separator: ", ")
        draft.role = recipient.role
        return draft
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft").font(.supraTitle)
                Text(matterName).font(.supraSubheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isWorking)
                .accessibilityIdentifier("drafting.close.header")
                .accessibilityLabel("Close Draft")
        }
        .padding()
    }

    // MARK: - Work-product picker

    @ViewBuilder
    private var workProductSection: some View {
        Section {
            ForEach(availableKinds.filter(\.isEnabled)) { kind in
                Button {
                    selection = .kind(kind.id)
                } label: {
                    workProductRow(
                        title: kind.title,
                        selected: selection == .kind(kind.id),
                        enabled: true,
                        subtitle: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("drafting.kind.\(kind.id.rawValue)")
            }
            Button { selection = .custom } label: {
                workProductRow(
                    title: "Custom — describe work product",
                    selected: selection == .custom,
                    enabled: true,
                    subtitle: "For anything not in the catalog. Produces a description, not a court-ready filing."
                )
            }
            .buttonStyle(.plain)
        } header: {
            Text("Work product")
        } footer: {
            Text("Choose an available draft type, or describe another work product under Custom. Review every statement and citation before use.")
        }

        if availableKinds.contains(where: { !$0.isEnabled }) {
            Section("Coming Soon") {
                ForEach(availableKinds.filter { !$0.isEnabled }) { kind in
                    workProductRow(
                        title: kind.title,
                        selected: false,
                        enabled: false,
                        subtitle: kind.disabledReason
                    )
                    .accessibilityIdentifier("drafting.kind.unavailable.\(kind.id.rawValue)")
                }
            }
        }
    }

    private func workProductRow(title: String, selected: Bool, enabled: Bool, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(enabled ? 1 : 0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(enabled ? .primary : .secondary)
                if let subtitle {
                    Text(subtitle).font(.supraCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectedForm: some View {
        switch selection {
        case .kind(.noticeAppearance):
            captionSection
            representedSection
            recipientsSection
        case .kind(.motionToDismiss):
            captionSection
            representedSection
            motionSection
            recipientsSection
        case .kind(.letterDemand):
            letterSection
        case .custom:
            customSection
        }
    }

    private var motionSection: some View {
        Section {
            LabeledTextField(
                label: "Responding to",
                text: $motionRespondingTo,
                prompt: "e.g. Plaintiff's First Amended Complaint"
            )
            .accessibilityIdentifier("drafting.motion.respondingTo")
            LabeledTextField(
                label: "Relief sought",
                text: $motionRelief,
                prompt: "e.g. dismissal without prejudice and leave to amend"
            )
            .accessibilityIdentifier("drafting.motion.relief")

            VStack(alignment: .leading, spacing: 5) {
                Text("Ground").font(.supraCaption).foregroundStyle(.secondary)
                Label("Failure to state a claim", systemImage: "checkmark.circle.fill")
                    .accessibilityLabel("Selected ground: Failure to state a claim")
            }

            if !motionSourceLoadErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Motion sources could not be loaded", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(motionSourceLoadErrors, id: \.self) { message in
                        Text(message)
                            .font(.supraCaption)
                            .foregroundStyle(.orange)
                    }
                    Button("Retry Sources") { loadMotionSourcesIfNeeded() }
                        .accessibilityIdentifier("drafting.motion.sources.retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("drafting.motion.sources.error")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Fact excerpts").font(.supraHeadline)
                if motionFactLoadError == nil, motionFactSources.isEmpty {
                    Text("No current, indexed fact excerpts are available in this matter.")
                        .font(.supraCaption).foregroundStyle(.orange)
                } else if motionFactLoadError == nil {
                    ForEach(motionFactSources) { source in
                        sourceChoice(
                            selected: selectedMotionFactIDs.contains(source.chunkID),
                            enabled: source.isReady,
                            accessibilityID: "drafting.motion.fact.\(source.chunkID)",
                            title: "\(source.documentName) — \(source.locator)",
                            detail: source.blockingReason ?? source.text
                        ) {
                            toggle(source.chunkID, in: &selectedMotionFactIDs)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drafting.motion.factSources")

            VStack(alignment: .leading, spacing: 8) {
                Text("Reviewed authorities").font(.supraHeadline)
                if motionAuthorityLoadError == nil, motionAuthoritySources.isEmpty {
                    Text("No saved authorities are available in this matter.")
                        .font(.supraCaption).foregroundStyle(.orange)
                } else if motionAuthorityLoadError == nil {
                    ForEach(motionAuthoritySources) { source in
                        sourceChoice(
                            selected: selectedMotionAuthorityIDs.contains(source.authorityID),
                            enabled: source.isReady,
                            accessibilityID: "drafting.motion.authority.\(source.authorityID)",
                            title: source.caseName,
                            detail: source.blockingReason
                                ?? "\(source.citation)\nReviewed proposition: \(source.snippet)"
                        ) {
                            toggle(source.authorityID, in: &selectedMotionAuthorityIDs)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drafting.motion.authoritySources")

            let readiness = currentMotionReadiness
            Label(
                readiness.canGenerate
                    ? "Ready — \(readiness.selectedFactCount) fact excerpt and \(readiness.selectedAuthorityCount) reviewed authority selected."
                    : readiness.blockingReasons.joined(separator: " "),
                systemImage: readiness.canGenerate ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.supraCaption)
            .foregroundStyle(readiness.canGenerate ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("drafting.motion.readiness")
            .accessibilityLabel(
                readiness.canGenerate
                    ? "Motion ready to generate"
                    : "Motion blocked. \(readiness.blockingReasons.joined(separator: " "))"
            )
        } header: {
            Text("Supported Florida motion")
        } footer: {
            Text("Supra assembles this motion locally from only the fact excerpts and reviewed authorities you select. It checks that required sections are present and that selected sources are reproduced exactly, and the saved record keeps those exact sources and accepted authorities. It does not decide whether a fact supports a legal ground, whether the motion is legally sufficient, or whether it is ready to file. This first supported ground is failure to state a claim; no drafting model is used. Review every proposition and citation before filing.")
        }
    }

    private var motionSourceLoadErrors: [String] {
        [motionFactLoadError, motionAuthorityLoadError].compactMap { $0 }
    }

    private func sourceChoice(
        selected: Bool,
        enabled: Bool,
        accessibilityID: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(enabled ? .primary : .secondary)
                    Text(detail).font(.supraCaption)
                        .foregroundStyle(enabled ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(sourceAccessibilityLabel(title: title, detail: detail))
        .accessibilityValue(sourceAccessibilityValue(
            selected: selected,
            enabled: enabled,
            blockingDetail: detail
        ))
    }

    private func sourceAccessibilityLabel(title: String, detail: String) -> String {
        "\(title). \(detail)"
    }

    private func sourceAccessibilityValue(
        selected: Bool,
        enabled: Bool,
        blockingDetail: String
    ) -> String {
        if !enabled { return "Blocked. \(blockingDetail)" }
        return selected ? "Selected" : "Ready"
    }

    @ViewBuilder
    private var letterSection: some View {
        Section("Recipient") {
            LabeledTextField(label: "Name", text: $letterRecipientName)
            LabeledTextField(label: "Firm (optional)", text: $letterRecipientFirm)
            LabeledTextField(label: "Street", text: $letterStreet)
            HStack(alignment: .bottom, spacing: 8) {
                LabeledTextField(label: "City", text: $letterCity)
                LabeledTextField(label: "State", text: $letterState).frame(width: 96)
                LabeledTextField(label: "ZIP", text: $letterZip).frame(width: 96)
            }
        }
        Section {
            LabeledTextField(label: "Re: (subject)", text: $letterReSubject, prompt: "e.g. Unpaid invoice #4471")
            VStack(alignment: .leading, spacing: 4) {
                Text("Claim / dispute").font(.supraCaption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "What is owed and why — the only facts the model may use.",
                    text: $letterClaim,
                    minLines: 3
                )
            }
            LabeledTextField(label: "Demand amount", text: $letterAmount, prompt: "e.g. $42,000")
            LabeledTextField(label: "Response deadline", text: $letterDeadline, prompt: "e.g. 14 days / July 15, 2026")
            Picker("Tone", selection: $letterTone) {
                Text("Measured").tag("measured")
                Text("Firm").tag("firm")
                Text("Final").tag("final")
            }
            LabeledTextField(label: "Delivery notation (optional)", text: $letterDelivery, prompt: "e.g. Via Certified Mail, RRR")
            routeStatus
            if let routingMessage {
                Text(routingMessage).font(.supraCaption).foregroundStyle(.orange)
            }
        } header: {
            Text("Demand")
        } footer: {
            Text("The on-device model drafts the body from these facts only — review every line before sending. Your letterhead, signature, and identity come from your Settings profile.")
        }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let routeModel {
            Text("Uses \(draftRoute.role.displayName): \(routeModel.displayName)")
                .font(.supraCaption).foregroundStyle(.secondary)
        } else {
            Text("Assign a \(draftRoute.role.displayName) model in Models to generate a letter.")
                .font(.supraCaption).foregroundStyle(.orange)
        }
    }

    private var customSection: some View {
        Section {
            BoxedLeadingTextField(placeholder: "Title (e.g. Reply brief outline)", text: $customTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text("Describe the work product").font(.supraCaption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "Describe what you want in plain language…",
                    text: $customDescription,
                    minLines: 4
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions / notes (optional)").font(.supraCaption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "Tone, length, must-include points…",
                    text: $customInstructions,
                    minLines: 2
                )
            }
        } header: {
            Text("Custom work product")
        } footer: {
            Text("Saved as a markdown description in this matter's exports — a drafting brief in your own words, not a court-ready or model-generated filing.")
        }
    }

    private var captionSection: some View {
        Section {
            ForEach($parties) { $party in
                HStack {
                    BoxedLeadingTextField(placeholder: "Party name (e.g. MCKERNON MOTORS, INC.,)", text: $party.name)
                    BoxedLeadingTextField(placeholder: "Designation", text: $party.designation)
                        .frame(width: 120)
                    if parties.count > 1 {
                        Button { parties.removeAll { $0.id == party.id } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            Button { parties.append(PartyDraft(name: "", designation: "")) } label: {
                Label("Add party", systemImage: "plus.circle")
            }.buttonStyle(.plain)
        } header: {
            Text("Caption parties")
        } footer: {
            Text("As they appear in the case caption. The court, judge where applicable, and case number come from the matter.")
        }
        .disabled(canonicalPartyDefaults != nil)
    }

    private var representedSection: some View {
        Section("Your client") {
            BoxedLeadingTextField(placeholder: "Represented-side designation", text: $partyRepresented)
            BoxedLeadingTextField(placeholder: "Represented client's full name", text: $representedPartyName)
        }
        .disabled(canonicalPartyDefaults != nil)
    }

    private var recipientsSection: some View {
        Section {
            ForEach($recipients) { $r in
                VStack(spacing: 6) {
                    HStack {
                        BoxedLeadingTextField(placeholder: "Attorney name", text: $r.name)
                        if recipients.count > 1 {
                            Button { recipients.removeAll { $0.id == r.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    BoxedLeadingTextField(placeholder: "Firm", text: $r.firm)
                    HStack {
                        BoxedLeadingTextField(placeholder: "Street", text: $r.street)
                    }
                    HStack {
                        BoxedLeadingTextField(placeholder: "City", text: $r.city)
                        BoxedLeadingTextField(placeholder: "State", text: $r.state).frame(width: 90)
                        BoxedLeadingTextField(placeholder: "ZIP", text: $r.zip).frame(width: 80)
                    }
                    BoxedLeadingTextField(placeholder: "E-mails (comma-separated)", text: $r.emails)
                    BoxedLeadingTextField(placeholder: "Service role", text: $r.role)
                }
                .padding(.vertical, 2)
            }
            Button { recipients.append(RecipientDraft()) } label: {
                Label("Add recipient", systemImage: "plus.circle")
            }.buttonStyle(.plain)
        } header: {
            Text("Service recipients (opposing counsel)")
        } footer: {
            Text("Everyone served under the certificate of service. These values come from the matter's structured representation graph.")
        }
        .disabled(canonicalPartyDefaults != nil)
    }

    private func resultSection(_ artifact: MatterDraftingController.DraftArtifact) -> some View {
        Section {
            Label("Draft generated: \(artifact.fileURL.lastPathComponent)", systemImage: "doc.fill")
                .font(.supraCaption)
                .accessibilityIdentifier("drafting.result.filename")
            if !artifact.reviewNotes.isEmpty {
                ForEach(artifact.reviewNotes, id: \.self) { note in
                    Label(note, systemImage: "flag.fill")
                        .font(.supraCaption)
                        .foregroundStyle(artifact.hasBlocking ? .orange : .secondary)
                }
            }
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                    .accessibilityIdentifier("drafting.reveal")
                Button {
                    NSWorkspace.shared.open(artifact.fileURL)
                } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    .accessibilityIdentifier("drafting.open")
                Spacer()
                ShareLink(item: artifact.fileURL) { Label("Save a copy…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("drafting.share")
            }
        } header: {
            Text("Download")
        } footer: {
            switch (artifact.format, artifact.source) {
            case (.docx, .kind(.motionToDismiss)):
                Text("Verification covers required structure and exact selected-source reproduction. It does not decide fact-to-ground applicability, legal sufficiency, or filing readiness. Review the generated document before filing.")
            case (.docx, _):
                Text("Verification covers the required checks for this draft kind. It does not determine legal sufficiency or filing readiness. Review the generated document before filing.")
            case (.markdown, _):
                Text("A work-product description in your own words — a drafting brief, not a court-ready or model-generated filing.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drafting.result")
    }

    private var isWorking: Bool { generationTask != nil || controller.isGenerating }

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            if let validationHint {
                Text(validationHint).font(.supraCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Close") { dismiss() }
                .disabled(isWorking)
                .accessibilityIdentifier("drafting.close.footer")
            if isWorking {
                Button("Cancel") { generationTask?.cancel() }
                    .accessibilityIdentifier("drafting.cancel")
            }
            Button(generateLabel) { startGeneration() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || !isReady)
                .accessibilityIdentifier("drafting.generate")
        }
        .padding()
    }

    private var generateLabel: String {
        switch selection {
        case .kind(.noticeAppearance): return "Generate Notice of Appearance"
        case .kind(.motionToDismiss): return "Generate Motion to Dismiss"
        case .kind(.letterDemand): return "Generate Demand Letter"
        case .custom: return "Generate work-product description"
        }
    }

    private var isReady: Bool {
        switch selection {
        case .kind(.noticeAppearance): return canonicalIdentityReady && noticeReady
        case .kind(.motionToDismiss):
            return canonicalIdentityReady && currentMotionReadiness.canGenerate
        case .kind(.letterDemand): return letterReady
        case .custom: return !trimmed(customDescription).isEmpty
        }
    }

    /// A short, inline reason the Generate button is disabled (nil when ready).
    private var validationHint: String? {
        guard !isReady else { return nil }
        switch selection {
        case .kind(.noticeAppearance):
            if !canonicalIdentityReady { return canonicalIdentityBlockingMessage }
            return "Add the caption parties, your client, and at least one complete service recipient."
        case .kind(.motionToDismiss):
            if !canonicalIdentityReady { return canonicalIdentityBlockingMessage }
            return currentMotionReadiness.blockingReasons.first
        case .kind(.letterDemand):
            return routeModel == nil
                ? "Assign a drafting model in Models, then fill the recipient and claim."
                : "Fill the recipient address and the claim."
        case .custom:
            return "Describe the work product to enable Generate."
        }
    }

    private var noticeReady: Bool {
        !trimmed(partyRepresented).isEmpty
            && !trimmed(representedPartyName).isEmpty
            && parties.filter { !trimmed($0.name).isEmpty && !trimmed($0.designation).isEmpty }.count >= 2
            && !completeRecipientDrafts.isEmpty
            && partialRecipientDrafts.isEmpty
    }

    private var canonicalIdentityReady: Bool {
        guard let defaults = canonicalPartyDefaults else { return false }
        let caption = parties.map {
            PartyLine(name: trimmed($0.name), designation: trimmed($0.designation))
        }
        guard caption == defaults.captionParties,
              trimmed(partyRepresented) == defaults.representedDesignation,
              trimmed(representedPartyName) == defaults.representedClientName,
              partialRecipientDrafts.isEmpty,
              completeRecipientDrafts.count == 1,
              let recipient = completeRecipientDrafts.first else {
            return false
        }
        return serviceRecipient(from: recipient) == defaults.serviceRecipient
    }

    private var canonicalIdentityBlockingMessage: String {
        partyDefaultsError
            ?? "Restore the matter's exact structured party and service identity before generating a court filing."
    }

    private var letterReady: Bool {
        routeModel != nil
            && !trimmed(letterRecipientName).isEmpty
            && !trimmed(letterStreet).isEmpty
            && !trimmed(letterCity).isEmpty
            && !trimmed(letterState).isEmpty
            && !trimmed(letterZip).isEmpty
            && !trimmed(letterClaim).isEmpty
    }

    private func startGeneration() {
        guard !isWorking else { return }
        let token = UUID()
        generationToken = token
        generationTask = Task { @MainActor in
            await generate(token: token)
            guard generationToken == token else { return }
            generationTask = nil
            generationToken = nil
        }
    }

    private func invalidateGeneration() {
        generationToken = nil
        generationTask?.cancel()
        generationTask = nil
    }

    private func generationIsCurrent(_ token: UUID, selection expected: WorkProductSelection) -> Bool {
        generationToken == token && selection == expected
    }

    private func generate(token: UUID) async {
        let requestedSelection = selection
        errorText = nil
        result = nil
        routingMessage = nil

        // The letter is LLM-backed: resolve/load the drafting model, then generate.
        if case .kind(.letterDemand) = requestedSelection {
            await generateLetter(token: token, selection: requestedSelection)
            return
        }

        let request: MatterDraftRequest
        switch requestedSelection {
        case .kind(.noticeAppearance):
            let partyLines = parties
                .filter { !trimmed($0.name).isEmpty || !trimmed($0.designation).isEmpty }
                .map { PartyLine(name: trimmed($0.name), designation: trimmed($0.designation)) }
            let serviceRecipients = completeRecipientDrafts
                .map { r in
                    ServiceRecipient(
                        name: trimmed(r.name),
                        firm: trimmed(r.firm),
                        address: OfficeBlock(
                            street: trimmed(r.street), suite: nil, city: trimmed(r.city),
                            state: trimmed(r.state), zip: trimmed(r.zip), phone: "", fax: nil
                        ),
                        emails: splitEmails(r.emails),
                        role: trimmed(r.role)
                    )
                }
            request = .noticeAppearance(NoticeAppearanceDraftInput(
                parties: partyLines,
                partyRepresented: trimmed(partyRepresented),
                representedPartyName: trimmed(representedPartyName),
                recipients: serviceRecipients
            ))
        case .kind(.motionToDismiss):
            request = .motionToDismiss(currentMotionInput)
        case .kind(.letterDemand):
            return // handled by the routed-model branch above
        case .custom:
            request = .customDescription(CustomDraftDescriptionInput(
                title: trimmed(customTitle),
                description: trimmed(customDescription),
                instructions: trimmed(customInstructions)
            ))
        }

        let outcome = await controller.draft(request, matterID: matterID)
        guard generationIsCurrent(token, selection: requestedSelection) else { return }
        switch outcome {
        case let .success(artifact):
            result = artifact
        case let .failure(error):
            errorText = error.errorDescription ?? "The draft could not be generated."
        }
    }

    private func generateLetter(token: UUID, selection requestedSelection: WorkProductSelection) async {
        let modelID: ModelID
        switch await library.ensureLoadedRoutedModelID(for: draftRoute.role, configuration: router.configuration) {
        case let .success(loaded):
            modelID = loaded
        case let .failure(issue):
            guard generationIsCurrent(token, selection: requestedSelection), !Task.isCancelled else { return }
            routingMessage = issue.message
            return
        }
        guard generationIsCurrent(token, selection: requestedSelection), !Task.isCancelled else { return }
        let input = LetterDraftInput(
            recipientName: trimmed(letterRecipientName),
            recipientFirm: trimmed(letterRecipientFirm),
            recipientStreet: trimmed(letterStreet),
            recipientCity: trimmed(letterCity),
            recipientState: trimmed(letterState),
            recipientZip: trimmed(letterZip),
            reSubject: trimmed(letterReSubject),
            salutation: "",
            claimSummary: trimmed(letterClaim),
            demandAmount: trimmed(letterAmount),
            responseDeadline: trimmed(letterDeadline),
            tone: letterTone,
            deliveryNotation: trimmed(letterDelivery)
        )
        let outcome = await controller.draftLetterDemand(
            matterID: matterID,
            input: input,
            modelID: modelID,
            route: draftRoute
        )
        guard generationIsCurrent(token, selection: requestedSelection) else { return }
        switch outcome {
        case let .success(artifact):
            result = artifact
        case let .failure(error):
            errorText = error.errorDescription ?? "The letter could not be generated."
        }
    }

    private var currentMotionInput: MotionToDismissDraftInput {
        let partyLines = parties
            .filter { !trimmed($0.name).isEmpty || !trimmed($0.designation).isEmpty }
            .map { PartyLine(name: trimmed($0.name), designation: trimmed($0.designation)) }
        let serviceRecipients = completeRecipientDrafts.map { recipient in
            ServiceRecipient(
                name: trimmed(recipient.name),
                firm: trimmed(recipient.firm),
                address: OfficeBlock(
                    street: trimmed(recipient.street),
                    suite: nil,
                    city: trimmed(recipient.city),
                    state: trimmed(recipient.state),
                    zip: trimmed(recipient.zip),
                    phone: "",
                    fax: nil
                ),
                emails: splitEmails(recipient.emails),
                role: trimmed(recipient.role)
            )
        }
        return MotionToDismissDraftInput(
            parties: partyLines,
            partyRepresented: trimmed(partyRepresented),
            representedPartyName: trimmed(representedPartyName),
            recipients: serviceRecipients,
            respondingTo: trimmed(motionRespondingTo),
            grounds: ["failure to state a claim"],
            reliefSought: trimmed(motionRelief),
            selectedFacts: motionFactSources
                .filter { selectedMotionFactIDs.contains($0.chunkID) }
                .map { source in
                    MotionDraftFactSourceSelection(
                        chunkID: source.chunkID,
                        expectedRevisionID: source.documentRevisionID,
                        expectedExcerptSHA256: source.excerptSHA256
                    )
                },
            selectedAuthorities: motionAuthoritySources
                .filter { selectedMotionAuthorityIDs.contains($0.authorityID) }
                .compactMap { source in
                    guard let bindingSHA256 = source.bindingSHA256 else { return nil }
                    return MotionDraftAuthoritySourceSelection(
                        authorityID: source.authorityID,
                        expectedBindingSHA256: bindingSHA256
                    )
                }
        )
    }

    private var currentMotionReadiness: MotionDraftReadiness {
        controller.motionReadiness(
            input: currentMotionInput,
            matterID: matterID,
            factSources: motionFactSources,
            authoritySources: motionAuthoritySources
        )
    }

    private func loadMotionSourcesIfNeeded() {
        let displayedFactBindings = Dictionary(
            uniqueKeysWithValues: motionFactSources.map { source in
                (source.chunkID, "\(source.documentRevisionID):\(source.excerptSHA256)")
            }
        )
        let displayedAuthorityBindings = Dictionary(
            uniqueKeysWithValues: motionAuthoritySources.compactMap { source in
                source.bindingSHA256.map { (source.authorityID, $0) }
            }
        )
        controller.message = nil
        let facts = controller.motionFactSources(matterID: matterID)
        motionFactLoadError = controller.message

        controller.message = nil
        let authorities = controller.motionAuthoritySources(matterID: matterID)
        motionAuthorityLoadError = controller.message
        controller.message = nil

        motionFactSources = facts
        motionAuthoritySources = authorities
        let currentFactBindings = Dictionary(
            uniqueKeysWithValues: motionFactSources.map { source in
                (source.chunkID, "\(source.documentRevisionID):\(source.excerptSHA256)")
            }
        )
        let currentAuthorityBindings = Dictionary(
            uniqueKeysWithValues: motionAuthoritySources.compactMap { source in
                source.bindingSHA256.map { (source.authorityID, $0) }
            }
        )
        selectedMotionFactIDs = Set(selectedMotionFactIDs.filter { chunkID in
            guard let displayed = displayedFactBindings[chunkID],
                  let current = currentFactBindings[chunkID] else { return false }
            return displayed == current
        })
        selectedMotionAuthorityIDs = Set(selectedMotionAuthorityIDs.filter { authorityID in
            guard let displayed = displayedAuthorityBindings[authorityID],
                  let current = currentAuthorityBindings[authorityID] else { return false }
            return displayed == current
        })
    }

    private func toggle(_ id: String, in selection: inout Set<String>) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private var completeRecipientDrafts: [RecipientDraft] {
        recipients.filter { recipientReady($0) }
    }

    private var partialRecipientDrafts: [RecipientDraft] {
        recipients.filter { !recipientReady($0) && recipientHasAnyValue($0) }
    }

    private func recipientReady(_ recipient: RecipientDraft) -> Bool {
        !trimmed(recipient.name).isEmpty
            && !trimmed(recipient.street).isEmpty
            && !trimmed(recipient.city).isEmpty
            && !trimmed(recipient.state).isEmpty
            && !trimmed(recipient.zip).isEmpty
            && !splitEmails(recipient.emails).isEmpty
            && !trimmed(recipient.role).isEmpty
    }

    private func serviceRecipient(from recipient: RecipientDraft) -> ServiceRecipient {
        ServiceRecipient(
            name: trimmed(recipient.name),
            firm: trimmed(recipient.firm),
            address: OfficeBlock(
                street: trimmed(recipient.street),
                suite: nil,
                city: trimmed(recipient.city),
                state: trimmed(recipient.state),
                zip: trimmed(recipient.zip),
                phone: "",
                fax: nil
            ),
            emails: splitEmails(recipient.emails),
            role: trimmed(recipient.role)
        )
    }

    private func recipientHasAnyValue(_ recipient: RecipientDraft) -> Bool {
        [
            recipient.name, recipient.firm, recipient.street, recipient.city,
            recipient.state, recipient.zip, recipient.emails, recipient.role
        ].contains { !trimmed($0).isEmpty }
    }

    private func splitEmails(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
