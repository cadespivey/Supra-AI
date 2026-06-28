import AppKit
import SupraCore
import SupraDraftingCore
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// The chat-side drafting sheet: the attorney confirms the caption parties and the
/// service recipients (opposing counsel) that the matter doesn't store as structured
/// data, then generates a downloadable `.docx`. The firewall (no invented identity)
/// lives in `MatterDraftingController`; this view surfaces its blocking messages and
/// the resulting file for download/preview.
struct MatterDraftingView: View {
    @ObservedObject var controller: MatterDraftingController
    @ObservedObject var library: ModelLibrary
    let matterID: String
    let matterName: String
    @Environment(\.dismiss) private var dismiss

    // Caption parties (e.g. "MCKERNON MOTORS, INC.," / "Plaintiff,").
    @State private var parties: [PartyDraft] = [
        PartyDraft(name: "", designation: "Plaintiff,"),
        PartyDraft(name: "", designation: "Defendant.")
    ]
    @State private var partyRepresented = "Defendant"
    @State private var representedPartyName = ""

    // Service recipients (opposing counsel).
    @State private var recipients: [RecipientDraft] = [RecipientDraft()]

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
        var state = "Florida"
        var zip = ""
        var emails = ""
        var role = "Counsel for Plaintiff"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                workProductSection
                selectedForm
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if let result {
                    resultSection(result)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            library.refresh()
            if availableKinds.isEmpty { availableKinds = controller.availableDraftKinds() }
        }
        // The result/error banner belongs to one work product — clear it when the
        // user switches to a different kind so a stale notice result doesn't linger
        // over the custom form (and vice versa).
        .onChange(of: selection) { _, _ in
            result = nil
            errorText = nil
            routingMessage = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft").font(.headline)
                Text(matterName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Work-product picker

    private var workProductSection: some View {
        Section {
            ForEach(availableKinds) { kind in
                Button {
                    if kind.isEnabled { selection = .kind(kind.id) }
                } label: {
                    workProductRow(
                        title: kind.title,
                        selected: selection == .kind(kind.id),
                        enabled: kind.isEnabled,
                        subtitle: kind.disabledReason
                    )
                }
                .buttonStyle(.plain)
                .disabled(!kind.isEnabled)
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
            Text("Pick what to draft. Disabled kinds aren't wired into the app yet — describe them under Custom.")
        }
    }

    private func workProductRow(title: String, selected: Bool, enabled: Bool, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(enabled ? 1 : 0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(enabled ? .primary : .secondary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
        case .kind(.letterDemand):
            letterSection
        case .kind:
            EmptyView()   // unwired kinds aren't selectable
        case .custom:
            customSection
        }
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
                Text("Claim / dispute").font(.caption).foregroundStyle(.secondary)
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
                Text(routingMessage).font(.caption).foregroundStyle(.orange)
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
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Assign a \(draftRoute.role.displayName) model in Models to generate a letter.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var customSection: some View {
        Section {
            TextField("Title (e.g. Reply brief outline)", text: $customTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text("Describe the work product").font(.caption).foregroundStyle(.secondary)
                MultilineField(
                    placeholder: "Describe what you want in plain language…",
                    text: $customDescription,
                    minLines: 4
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions / notes (optional)").font(.caption).foregroundStyle(.secondary)
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
                    TextField("Party name (e.g. MCKERNON MOTORS, INC.,)", text: $party.name)
                    TextField("Designation", text: $party.designation)
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
            Text("As they appear in the case caption. The court, division, and case number come from the matter.")
        }
    }

    private var representedSection: some View {
        Section("Your client") {
            TextField("Party you represent (e.g. Defendant)", text: $partyRepresented)
            TextField("Client's full name (e.g. Liberty Rail, LLC)", text: $representedPartyName)
        }
    }

    private var recipientsSection: some View {
        Section {
            ForEach($recipients) { $r in
                VStack(spacing: 6) {
                    HStack {
                        TextField("Attorney name", text: $r.name)
                        if recipients.count > 1 {
                            Button { recipients.removeAll { $0.id == r.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Firm", text: $r.firm)
                    HStack {
                        TextField("Street", text: $r.street)
                    }
                    HStack {
                        TextField("City", text: $r.city)
                        TextField("State", text: $r.state).frame(width: 90)
                        TextField("ZIP", text: $r.zip).frame(width: 80)
                    }
                    TextField("E-mails (comma-separated)", text: $r.emails)
                    TextField("Role (e.g. Counsel for Plaintiff)", text: $r.role)
                }
                .padding(.vertical, 2)
            }
            Button { recipients.append(RecipientDraft()) } label: {
                Label("Add recipient", systemImage: "plus.circle")
            }.buttonStyle(.plain)
        } header: {
            Text("Service recipients (opposing counsel)")
        } footer: {
            Text("Everyone served under the certificate of service. Drafting never invents these — you enter who's actually on the case.")
        }
    }

    private func resultSection(_ artifact: MatterDraftingController.DraftArtifact) -> some View {
        Section {
            Label("Draft generated: \(artifact.fileURL.lastPathComponent)", systemImage: "doc.fill")
                .font(.callout)
            if !artifact.reviewNotes.isEmpty {
                ForEach(artifact.reviewNotes, id: \.self) { note in
                    Label(note, systemImage: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(artifact.hasBlocking ? .orange : .secondary)
                }
            }
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button {
                    NSWorkspace.shared.open(artifact.fileURL)
                } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Spacer()
                ShareLink(item: artifact.fileURL) { Label("Save a copy…", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Download")
        } footer: {
            switch artifact.format {
            case .docx:
                Text("Review every flagged item before filing. Unverified citations appear as visible [cite] placeholders.")
            case .markdown:
                Text("A work-product description in your own words — a drafting brief, not a court-ready or model-generated filing.")
            }
        }
    }

    private var footer: some View {
        HStack {
            if controller.isGenerating { ProgressView().controlSize(.small) }
            if let validationHint {
                Text(validationHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Close") { dismiss() }
            Button(generateLabel) { Task { await generate() } }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isGenerating || !isReady)
        }
        .padding()
    }

    private var generateLabel: String {
        switch selection {
        case .kind(.noticeAppearance): return "Generate Notice of Appearance"
        case .kind(.letterDemand): return "Generate Demand Letter"
        case .kind: return "Generate"
        case .custom: return "Generate work-product description"
        }
    }

    private var isReady: Bool {
        switch selection {
        case .kind(.noticeAppearance): return noticeReady
        case .kind(.letterDemand): return letterReady
        case .kind: return false
        case .custom: return !trimmed(customDescription).isEmpty
        }
    }

    /// A short, inline reason the Generate button is disabled (nil when ready).
    private var validationHint: String? {
        guard !isReady else { return nil }
        switch selection {
        case .kind(.noticeAppearance):
            return "Add the caption parties, your client, and at least one complete service recipient."
        case .kind(.letterDemand):
            return routeModel == nil
                ? "Assign a drafting model in Models, then fill the recipient and claim."
                : "Fill the recipient address and the claim."
        case .kind:
            return nil
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

    private var letterReady: Bool {
        routeModel != nil
            && !trimmed(letterRecipientName).isEmpty
            && !trimmed(letterStreet).isEmpty
            && !trimmed(letterCity).isEmpty
            && !trimmed(letterState).isEmpty
            && !trimmed(letterZip).isEmpty
            && !trimmed(letterClaim).isEmpty
    }

    private func generate() async {
        errorText = nil
        result = nil
        routingMessage = nil

        // The letter is LLM-backed: resolve/load the drafting model, then generate.
        if case .kind(.letterDemand) = selection {
            await generateLetter()
            return
        }

        let request: MatterDraftRequest
        switch selection {
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
        case .kind:
            return
        case .custom:
            request = .customDescription(CustomDraftDescriptionInput(
                title: trimmed(customTitle),
                description: trimmed(customDescription),
                instructions: trimmed(customInstructions)
            ))
        }

        switch await controller.draft(request, matterID: matterID) {
        case let .success(artifact):
            result = artifact
        case let .failure(error):
            errorText = error.errorDescription ?? "The draft could not be generated."
        }
    }

    private func generateLetter() async {
        let modelID: ModelID
        switch await library.ensureLoadedRoutedModelID(for: draftRoute.role, configuration: router.configuration) {
        case let .success(loaded):
            modelID = loaded
        case let .failure(issue):
            routingMessage = issue.message
            return
        }
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
        switch await controller.draftLetterDemand(matterID: matterID, input: input, modelID: modelID, route: draftRoute) {
        case let .success(artifact):
            result = artifact
        case let .failure(error):
            errorText = error.errorDescription ?? "The letter could not be generated."
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
