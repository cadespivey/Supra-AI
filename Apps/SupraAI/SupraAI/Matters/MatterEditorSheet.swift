import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI

/// Canonical create/edit form for a matter. Structured parties and
/// representations are the only editable drafting identity; legacy client
/// perspective/name bytes remain visible only as read-only migration evidence.
struct MatterEditorSheet: View {
    enum Mode {
        case create
        case edit

        var title: String {
            switch self {
            case .create: "New Matter"
            case .edit: "Edit Matter"
            }
        }

        var confirmLabel: String {
            switch self {
            case .create: "Create Matter"
            case .edit: "Save"
            }
        }
    }

    let mode: Mode
    private let matterID: String
    private let expectedIdentityRevision: Int?
    @State private var draft: MatterDraft
    @State private var courtResolutionState: MatterCourtResolutionState
    @State private var canonicalJurisdictionID: CanonicalJurisdictionID?
    @State private var canonicalCourtID: CanonicalCourtID?
    @State private var parties: [MatterPartyIdentity]
    @State private var representations: [MatterRepresentationIdentity]
    /// Known practice areas from existing matters; recommends an existing
    /// spelling as one is typed.
    private let practiceAreaDirectory: PracticeAreaDirectory
    private let onSave: (MatterIdentityEditorSubmission) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showValidation = false
    @State private var selectedCourtID: String
    @State private var saveError: String?

    init(
        mode: Mode,
        submission: MatterIdentityEditorSubmission,
        practiceAreaDirectory: PracticeAreaDirectory = .empty,
        onSave: @escaping (MatterIdentityEditorSubmission) throws -> Void
    ) {
        self.mode = mode
        self.matterID = submission.matterID
        self.expectedIdentityRevision = submission.expectedIdentityRevision
        self._draft = State(initialValue: submission.draft)
        self._courtResolutionState = State(initialValue: submission.courtResolutionState)
        self._canonicalJurisdictionID = State(initialValue: submission.canonicalJurisdictionID)
        self._canonicalCourtID = State(initialValue: submission.canonicalCourtID)
        self._parties = State(initialValue: submission.parties)
        self._representations = State(initialValue: submission.representations)
        self.practiceAreaDirectory = practiceAreaDirectory
        self._selectedCourtID = State(
            initialValue: submission.canonicalCourtID?.rawValue
                ?? submission.canonicalJurisdictionID?.rawValue
                ?? ""
        )
        self.onSave = onSave
    }

    var body: some View {
        SupraSheetScaffold(mode.title, doneLabel: "Cancel", onClose: { dismiss() }) {
            editorForm
        } footer: {
            if let saveError {
                Text(saveError)
                    .font(.supraCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("matter.identity.saveError")
            }
            Spacer()
            Button(mode.confirmLabel) { save() }
                .buttonStyle(.ghost)
                .keyboardShortcut(.defaultAction)
                .disabled(showValidation && !draft.isValid)
        }
        .frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
    }

    private var editorForm: some View {
            Form {
                Section("Required") {
                    field("Matter name", text: $draft.name, invalid: nameInvalid, message: "Name is required.")
                    JurisdictionAutocompleteField(
                        jurisdiction: $draft.jurisdiction,
                        court: $draft.court,
                        selectedCourtID: $selectedCourtID,
                        courtResolutionState: $courtResolutionState,
                        canonicalJurisdictionID: $canonicalJurisdictionID,
                        canonicalCourtID: $canonicalCourtID,
                        invalid: jurisdictionInvalid
                    )
                }

                structuredPartiesSection
                structuredRepresentationsSection
                legacyIdentityEvidenceSection

                Section("Optional") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Matter description").font(.supraCaption).foregroundStyle(.secondary)
                        MultilineField(placeholder: "Matter description", text: $draft.matterDescription, minLines: 3)
                    }
                    LabeledTextField(label: "Judge", text: $draft.judge)
                    LabeledTextField(label: "Case number", text: $draft.docketNumber)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledTextField(label: "Practice area", text: $draft.practiceArea)
                        SuggestionList(
                            suggestions: practiceAreaSuggestions,
                            title: { $0.name },
                            detail: { $0.matterCount == 1 ? "1 matter" : "\($0.matterCount) matters" },
                            onSelect: { draft.practiceArea = $0.name }
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.supraCaption).foregroundStyle(.secondary)
                        MultilineField(placeholder: "Notes", text: $draft.notes, minLines: 3)
                    }
                }

                Section {
                    LabeledTextField(label: "Firm matter ID", text: $draft.internalMatterID, prompt: "LAW_FIRM_MATTER_ID")
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledTextField(label: "Client ID", text: $draft.clientID, prompt: "CLIENT_ID")
                    }
                    LabeledTextField(label: "Client matter ID", text: $draft.clientMatterID, prompt: "CLIENT_MATTER_ID")
                } header: {
                    Text("E-billing (LEDES)")
                } footer: {
                    Text("Required to export this matter's ScratchPad billing to LEDES 1998B. Your firm's billing department or the client's e-billing portal supplies these IDs.")
                }
            }
            .formStyle(.grouped)
    }

    private var structuredPartiesSection: some View {
        Section {
            if parties.isEmpty {
                Text("No structured parties yet. Add the parties needed for captions and represented-side drafting.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(parties.enumerated()), id: \.element.id) { index, party in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Party \(index + 1)").font(.supraHeadline)
                        Spacer()
                        Button {
                            removeParty(id: party.id)
                        } label: {
                            Label("Remove party", systemImage: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("matter.identity.party.remove.\(party.id)")
                    }
                    LabeledTextField(
                        label: "Display name",
                        text: partyTextBinding(at: index, field: .displayName)
                    )
                    LabeledTextField(
                        label: "Caption name",
                        text: partyTextBinding(at: index, field: .captionName)
                    )
                    HStack {
                        Picker("Case role", selection: partyRoleBinding(at: index)) {
                            ForEach(MatterPartyBaseRole.allCases, id: \.self) { role in
                                Text(identityLabel(role.rawValue)).tag(role)
                            }
                        }
                        Picker("Firm relationship", selection: partyStatusBinding(at: index)) {
                            ForEach(MatterPartyClientStatus.allCases, id: \.self) { status in
                                Text(identityLabel(status.rawValue)).tag(status)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("matter.identity.party.\(party.id)")
            }
            Button {
                addParty()
            } label: {
                Label("Add structured party", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("matter.identity.party.add")
        } header: {
            Text("Structured parties")
        } footer: {
            Text("Mark exactly one client as Represented and one opposing party as Not Represented for court drafting. Legacy client-name and perspective fields remain compatibility evidence only.")
        }
    }

    private var structuredRepresentationsSection: some View {
        Section {
            if representations.isEmpty {
                Text("No structured counsel or service recipient yet.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(representations.enumerated()), id: \.element.id) { index, representation in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Counsel / service \(index + 1)").font(.supraHeadline)
                        Spacer()
                        Button {
                            representations.removeAll { $0.id == representation.id }
                        } label: {
                            Label("Remove representation", systemImage: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "matter.identity.representation.remove.\(representation.id)"
                        )
                    }
                    Picker(
                        "Represents",
                        selection: representedPartyBinding(at: index)
                    ) {
                        Text("Choose party").tag("")
                        ForEach(parties, id: \.id) { party in
                            Text(party.displayName.ifEmpty("Unnamed party"))
                                .tag(party.id)
                        }
                    }
                    Picker(
                        "Relationship",
                        selection: representationRelationshipBinding(at: index)
                    ) {
                        ForEach(MatterRepresentationRelationshipKind.allCases, id: \.self) { kind in
                            Text(identityLabel(kind.rawValue)).tag(kind)
                        }
                    }
                    LabeledTextField(
                        label: "Representative name",
                        text: representationTextBinding(at: index, field: .representativeName)
                    )
                    LabeledTextField(
                        label: "Firm",
                        text: representationTextBinding(at: index, field: .firmName)
                    )
                    LabeledTextField(
                        label: "Service street",
                        text: representationTextBinding(at: index, field: .street)
                    )
                    HStack {
                        LabeledTextField(
                            label: "City",
                            text: representationTextBinding(at: index, field: .city)
                        )
                        LabeledTextField(
                            label: "State",
                            text: representationTextBinding(at: index, field: .state)
                        )
                        .frame(width: 100)
                        LabeledTextField(
                            label: "Postal code",
                            text: representationTextBinding(at: index, field: .postalCode)
                        )
                        .frame(width: 110)
                    }
                    LabeledTextField(
                        label: "Service emails",
                        text: representationTextBinding(at: index, field: .serviceEmails),
                        prompt: "Comma-separated"
                    )
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(
                    "matter.identity.representation.\(representation.id)"
                )
            }
            Button {
                addRepresentation()
            } label: {
                Label("Add counsel / service", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .disabled(parties.isEmpty)
            .accessibilityIdentifier("matter.identity.representation.add")
        } header: {
            Text("Counsel and service")
        } footer: {
            Text("Court drafting requires one complete Counsel record for the opposing party. The represented party is selected by its stable structured-party ID.")
        }
    }

    private var legacyIdentityEvidenceSection: some View {
        Section {
            LabeledContent("Prior client perspective") {
                Text(identityLabel(draft.partyPerspective.rawValue))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("matter.identity.legacy.perspective")
            }
            LabeledContent("Prior client name text") {
                Text(draft.clientNames.ifEmpty("None preserved"))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("matter.identity.legacy.clientNames")
            }
        } header: {
            Text("Legacy compatibility evidence")
        } footer: {
            Text("Read-only migration evidence. These values are preserved unchanged for compatibility and never select caption parties, the represented client, opposing counsel, or service recipients.")
        }
    }

    /// Known practice areas matching the typed text; the exact spelling already
    /// in the field drops out, other matches stay visible.
    private var practiceAreaSuggestions: [PracticeAreaDirectory.Entry] {
        practiceAreaDirectory.suggestions(for: draft.practiceArea)
            .filter { !practiceAreaDirectory.isApplied($0, text: draft.practiceArea) }
    }

    private enum PartyTextField {
        case displayName
        case captionName
    }

    private enum RepresentationTextField {
        case representativeName
        case firmName
        case street
        case city
        case state
        case postalCode
        case serviceEmails
    }

    private func addParty() {
        parties.append(MatterPartyIdentity(
            id: "party:\(matterID):\(UUID().uuidString)",
            matterID: matterID,
            displayName: "",
            captionName: "",
            baseRole: .other,
            captionOrder: parties.count,
            clientStatus: .unresolved
        ))
    }

    private func removeParty(id: String) {
        parties.removeAll { $0.id == id }
        representations.removeAll { $0.representedPartyID == id }
        parties = parties.enumerated().map { index, party in
            MatterPartyIdentity(
                id: party.id,
                matterID: matterID,
                displayName: party.displayName,
                captionName: party.captionName,
                baseRole: party.baseRole,
                captionOrder: index,
                clientStatus: party.clientStatus
            )
        }
    }

    private func addRepresentation() {
        representations.append(MatterRepresentationIdentity(
            id: "representation:\(matterID):\(UUID().uuidString)",
            matterID: matterID,
            representedPartyID: "",
            relationshipKind: .counsel,
            representativeName: "",
            firmName: nil,
            serviceAddress: nil,
            serviceEmails: [],
            serviceOrder: representations.count
        ))
    }

    private func partyTextBinding(
        at index: Int,
        field: PartyTextField
    ) -> Binding<String> {
        Binding(
            get: {
                guard parties.indices.contains(index) else { return "" }
                switch field {
                case .displayName: return parties[index].displayName
                case .captionName: return parties[index].captionName
                }
            },
            set: { value in
                guard parties.indices.contains(index) else { return }
                let current = parties[index]
                parties[index] = MatterPartyIdentity(
                    id: current.id,
                    matterID: matterID,
                    displayName: field == .displayName ? value : current.displayName,
                    captionName: field == .captionName ? value : current.captionName,
                    baseRole: current.baseRole,
                    captionOrder: current.captionOrder,
                    clientStatus: current.clientStatus
                )
            }
        )
    }

    private func partyRoleBinding(at index: Int) -> Binding<MatterPartyBaseRole> {
        Binding(
            get: {
                parties.indices.contains(index) ? parties[index].baseRole : .other
            },
            set: { role in
                guard parties.indices.contains(index) else { return }
                let current = parties[index]
                parties[index] = MatterPartyIdentity(
                    id: current.id,
                    matterID: matterID,
                    displayName: current.displayName,
                    captionName: current.captionName,
                    baseRole: role,
                    captionOrder: current.captionOrder,
                    clientStatus: current.clientStatus
                )
            }
        )
    }

    private func partyStatusBinding(
        at index: Int
    ) -> Binding<MatterPartyClientStatus> {
        Binding(
            get: {
                parties.indices.contains(index)
                    ? parties[index].clientStatus : .unresolved
            },
            set: { status in
                guard parties.indices.contains(index) else { return }
                let current = parties[index]
                parties[index] = MatterPartyIdentity(
                    id: current.id,
                    matterID: matterID,
                    displayName: current.displayName,
                    captionName: current.captionName,
                    baseRole: current.baseRole,
                    captionOrder: current.captionOrder,
                    clientStatus: status
                )
            }
        )
    }

    private func representedPartyBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                representations.indices.contains(index)
                    ? representations[index].representedPartyID : ""
            },
            set: { partyID in
                replaceRepresentation(at: index, representedPartyID: partyID)
            }
        )
    }

    private func representationRelationshipBinding(
        at index: Int
    ) -> Binding<MatterRepresentationRelationshipKind> {
        Binding(
            get: {
                representations.indices.contains(index)
                    ? representations[index].relationshipKind : .counsel
            },
            set: { relationship in
                replaceRepresentation(at: index, relationshipKind: relationship)
            }
        )
    }

    private func representationTextBinding(
        at index: Int,
        field: RepresentationTextField
    ) -> Binding<String> {
        Binding(
            get: {
                guard representations.indices.contains(index) else { return "" }
                let representation = representations[index]
                switch field {
                case .representativeName: return representation.representativeName
                case .firmName: return representation.firmName ?? ""
                case .street: return representation.serviceAddress?.street ?? ""
                case .city: return representation.serviceAddress?.city ?? ""
                case .state: return representation.serviceAddress?.state ?? ""
                case .postalCode: return representation.serviceAddress?.postalCode ?? ""
                case .serviceEmails:
                    return representation.serviceEmails.joined(separator: ", ")
                }
            },
            set: { value in
                guard representations.indices.contains(index) else { return }
                let current = representations[index]
                var representativeName = current.representativeName
                var firmName = current.firmName
                var street = current.serviceAddress?.street ?? ""
                var city = current.serviceAddress?.city ?? ""
                var state = current.serviceAddress?.state ?? ""
                var postalCode = current.serviceAddress?.postalCode ?? ""
                var serviceEmails = current.serviceEmails
                switch field {
                case .representativeName: representativeName = value
                case .firmName: firmName = value.isEmpty ? nil : value
                case .street: street = value
                case .city: city = value
                case .state: state = value
                case .postalCode: postalCode = value
                case .serviceEmails:
                    serviceEmails = value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                let addressValues = [street, city, state, postalCode]
                let address = addressValues.allSatisfy(\.isEmpty)
                    ? nil
                    : MatterServiceAddress(
                        street: street,
                        city: city,
                        state: state,
                        postalCode: postalCode
                    )
                representations[index] = MatterRepresentationIdentity(
                    id: current.id,
                    matterID: matterID,
                    representedPartyID: current.representedPartyID,
                    relationshipKind: current.relationshipKind,
                    representativeName: representativeName,
                    firmName: firmName,
                    serviceAddress: address,
                    serviceEmails: serviceEmails,
                    serviceOrder: current.serviceOrder
                )
            }
        )
    }

    private func replaceRepresentation(
        at index: Int,
        representedPartyID: String? = nil,
        relationshipKind: MatterRepresentationRelationshipKind? = nil
    ) {
        guard representations.indices.contains(index) else { return }
        let current = representations[index]
        representations[index] = MatterRepresentationIdentity(
            id: current.id,
            matterID: matterID,
            representedPartyID: representedPartyID ?? current.representedPartyID,
            relationshipKind: relationshipKind ?? current.relationshipKind,
            representativeName: current.representativeName,
            firmName: current.firmName,
            serviceAddress: current.serviceAddress,
            serviceEmails: current.serviceEmails,
            serviceOrder: current.serviceOrder
        )
    }

    private func identityLabel(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var nameInvalid: Bool {
        showValidation && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var jurisdictionInvalid: Bool {
        showValidation && draft.jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, invalid: Bool, message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledTextField(label: label, text: text)
            if invalid {
                Text(message)
                    .font(.supraCaption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard draft.isValid else {
            showValidation = true
            return
        }
        do {
            try onSave(MatterIdentityEditorSubmission(
                matterID: matterID,
                expectedIdentityRevision: expectedIdentityRevision,
                draft: draft,
                courtResolutionState: courtResolutionState,
                canonicalJurisdictionID: canonicalJurisdictionID,
                canonicalCourtID: canonicalCourtID,
                parties: parties,
                representations: representations
            ))
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

}

/// Click-to-fill recommendations under a form field (known clients, practice
/// areas), styled after the jurisdiction suggestion list.
private struct SuggestionList<Item: Identifiable>: View {
    let suggestions: [Item]
    let title: (Item) -> String
    let detail: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    Button { onSelect(entry) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(entry))
                                .foregroundStyle(.primary)
                            let detailText = detail(entry)
                            if !detailText.isEmpty {
                                Text(detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.08)))
        }
    }
}

/// Single-field jurisdiction picker for the New Matter form: type to get live
/// court/jurisdiction suggestions, pick one, or mark the matter N/A when no
/// jurisdiction is relevant. Replaces the older search-box-plus-dropdown flow.
struct JurisdictionAutocompleteField: View {
    @Binding var jurisdiction: String
    @Binding var court: String
    @Binding var selectedCourtID: String
    @Binding var courtResolutionState: MatterCourtResolutionState
    @Binding var canonicalJurisdictionID: CanonicalJurisdictionID?
    @Binding var canonicalCourtID: CanonicalCourtID?
    let invalid: Bool
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
    var accessibilityID: String? = nil

    @State private var query: String
    /// The jurisdiction bytes that predated this edit. When a user replaces a
    /// selected court with unresolved free text, those bytes remain migration
    /// evidence; the field never manufactures a synthetic jurisdiction label.
    @State private var unresolvedJurisdictionEvidence: String
    /// Cached search results, refreshed off the render path by `.task(id: query)`
    /// below. Holding these in state (rather than a computed property the body reads
    /// several times per keystroke) is what keeps typing responsive.
    @State private var suggestions: [JurisdictionOption] = []

    private let catalog = JurisdictionCatalog.shared

    init(
        jurisdiction: Binding<String>,
        court: Binding<String>,
        selectedCourtID: Binding<String>,
        courtResolutionState: Binding<MatterCourtResolutionState>,
        canonicalJurisdictionID: Binding<CanonicalJurisdictionID?>,
        canonicalCourtID: Binding<CanonicalCourtID?>,
        invalid: Bool,
        focusChain: SupraFocusChain? = nil,
        focusOrder: Int = 0,
        accessibilityID: String? = nil
    ) {
        self._jurisdiction = jurisdiction
        self._court = court
        self._selectedCourtID = selectedCourtID
        self._courtResolutionState = courtResolutionState
        self._canonicalJurisdictionID = canonicalJurisdictionID
        self._canonicalCourtID = canonicalCourtID
        self.invalid = invalid
        self.focusChain = focusChain
        self.focusOrder = focusOrder
        self.accessibilityID = accessibilityID
        let initial = JurisdictionCatalog.shared.option(id: selectedCourtID.wrappedValue)?.displayName
            ?? court.wrappedValue.ifEmpty(jurisdiction.wrappedValue)
        self._query = State(initialValue: initial)
        self._unresolvedJurisdictionEvidence = State(
            initialValue: jurisdiction.wrappedValue
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BoxedLeadingTextField(
                    placeholder: "Jurisdiction or court",
                    text: queryBinding,
                    focusChain: focusChain,
                    focusOrder: focusOrder,
                    accessibilityID: accessibilityID
                )
                if isNotApplicable {
                    Button("Clear") { clear() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                } else {
                    Button("N/A") { selectNotApplicable() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("This matter has no relevant jurisdiction")
                }
            }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Divider() }
                        Button { select(option) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.displayName)
                                    .foregroundStyle(.primary)
                                if let detail = optionDetail(option) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.08)))
            }

            footer
        }
        .task(id: query) {
            // Debounce so a burst of keystrokes recomputes once, then refresh
            // suggestions off the render path. `.task(id:)` cancels the prior run on
            // each change, so only the latest query's results land.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestions = trimmed.isEmpty ? [] : catalog.search(query, limit: 6)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if invalid {
            Text("Jurisdiction is required. Choose N/A if it doesn't apply.")
                .font(.supraCaption)
                .foregroundStyle(.red)
        } else if let scope = selectedScope {
            VStack(alignment: .leading, spacing: 3) {
                Text(scope.mandatoryAuthorities.joined(separator: "; "))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !scope.courtListenerIDs.isEmpty {
                    Text("CourtListener: \(scope.courtListenerIDs.joined(separator: ", "))")
                        .font(.supraCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        } else if isNotApplicable {
            Text("No specific jurisdiction — authority scoping is disabled for this matter.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        } else if courtResolutionState == .unresolved,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Saved text is unresolved. Choose Court from the canonical results before court-dependent work can continue.")
                .font(.supraCaption)
                .foregroundStyle(.orange)
        } else {
            Text("Type to search courts and jurisdictions, or choose N/A.")
                .font(.supraCaption)
                .foregroundStyle(.tertiary)
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { query },
            set: { newValue in
                query = newValue
                selectedCourtID = ""
                canonicalJurisdictionID = nil
                canonicalCourtID = nil
                courtResolutionState = .unresolved
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if unresolvedJurisdictionEvidence.isEmpty {
                    jurisdiction = newValue
                } else {
                    jurisdiction = unresolvedJurisdictionEvidence
                }
                court = trimmed.isEmpty ? "" : newValue
            }
        )
    }

    private var showSuggestions: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNotApplicable else { return false }
        if let selected = catalog.option(id: selectedCourtID), selected.displayName == query { return false }
        return !suggestions.isEmpty
    }

    private var isNotApplicable: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("N/A") == .orderedSame
    }

    private var selectedScope: JurisdictionAuthorityScope? {
        guard courtResolutionState == .court || courtResolutionState == .jurisdictionOnly else {
            return nil
        }
        return catalog.option(id: selectedCourtID).map(catalog.authorityScope(for:))
    }

    private func optionDetail(_ option: JurisdictionOption) -> String? {
        let parts = [option.jurisdictionName, option.level.displayName]
            .filter { !$0.isEmpty && $0 != option.displayName }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func select(_ option: JurisdictionOption) {
        guard let canonicalJurisdiction = catalog.canonicalJurisdictionOption(
            forSelectedOptionID: option.id
        ) else {
            selectedCourtID = ""
            canonicalJurisdictionID = nil
            canonicalCourtID = nil
            courtResolutionState = .unresolved
            return
        }
        query = option.displayName
        selectedCourtID = option.id
        canonicalJurisdictionID = CanonicalJurisdictionID(
            rawValue: canonicalJurisdiction.id
        )
        jurisdiction = canonicalJurisdiction.jurisdictionName
        if option.level == .jurisdiction {
            canonicalCourtID = nil
            courtResolutionState = .jurisdictionOnly
            court = ""
        } else {
            canonicalCourtID = CanonicalCourtID(rawValue: option.id)
            courtResolutionState = .court
            court = option.displayName
        }
    }

    private func selectNotApplicable() {
        query = "N/A"
        selectedCourtID = ""
        canonicalJurisdictionID = nil
        canonicalCourtID = nil
        courtResolutionState = .notApplicable
        jurisdiction = "N/A"
        court = ""
    }

    private func clear() {
        query = ""
        selectedCourtID = ""
        canonicalJurisdictionID = nil
        canonicalCourtID = nil
        courtResolutionState = .unresolved
        jurisdiction = ""
        court = ""
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
