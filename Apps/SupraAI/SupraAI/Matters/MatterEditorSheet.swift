import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI

/// Create/edit form for a matter. Name, jurisdiction, and party perspective are
/// required (spec §8.4); the rest are optional. Save is blocked until the
/// required fields are valid, with inline messages.
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
    @State private var draft: MatterDraft
    /// Known clients from existing matters; recommends the matching number when
    /// a name is typed (and vice versa) so client identities stay consistent.
    private let clientDirectory: ClientDirectory
    /// Known practice areas from existing matters; recommends an existing
    /// spelling as one is typed.
    private let practiceAreaDirectory: PracticeAreaDirectory
    private let onSave: (MatterDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showValidation = false
    @State private var selectedCourtID: String

    init(
        mode: Mode,
        draft: MatterDraft,
        clientDirectory: ClientDirectory = .empty,
        practiceAreaDirectory: PracticeAreaDirectory = .empty,
        onSave: @escaping (MatterDraft) -> Void
    ) {
        let selected = JurisdictionCatalog.shared.bestMatch(jurisdiction: draft.jurisdiction, court: draft.court)
        self.mode = mode
        self._draft = State(initialValue: draft)
        self.clientDirectory = clientDirectory
        self.practiceAreaDirectory = practiceAreaDirectory
        self._selectedCourtID = State(initialValue: selected?.id ?? "")
        self.onSave = onSave
    }

    var body: some View {
        SupraSheetScaffold(mode.title, doneLabel: "Cancel", onClose: { dismiss() }) {
            editorForm
        } footer: {
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
                        invalid: jurisdictionInvalid
                    )
                    Picker("Client perspective", selection: $draft.partyPerspective) {
                        ForEach(PartyPerspective.allCases, id: \.self) { perspective in
                            Text(perspective.rawValue.capitalized).tag(perspective)
                        }
                    }
                }

                Section("Optional") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Client name(s)").font(.supraCaption).foregroundStyle(.secondary)
                        MultilineField(placeholder: "Client name(s)", text: $draft.clientNames, minLines: 2)
                        SuggestionList(
                            suggestions: nameSuggestions,
                            title: { $0.name ?? "" },
                            detail: { entry in
                                let parts = [entry.clientID.map { "Client ID \($0)" }, matterCountLabel(entry)]
                                return parts.compactMap(\.self).joined(separator: " · ")
                            },
                            onSelect: applyClient
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Matter description").font(.supraCaption).foregroundStyle(.secondary)
                        MultilineField(placeholder: "Matter description", text: $draft.matterDescription, minLines: 3)
                    }
                    LabeledTextField(label: "Court", text: $draft.court)
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
                        SuggestionList(
                            suggestions: numberSuggestions,
                            title: { $0.clientID ?? "" },
                            detail: { entry in
                                let parts = [entry.name, matterCountLabel(entry)]
                                return parts.compactMap(\.self).joined(separator: " · ")
                            },
                            onSelect: applyClient
                        )
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

    /// Known clients matching the typed name. The entry already carried by the
    /// fields drops out (nothing left to recommend for it), but OTHER matches
    /// stay visible — two clients sharing a name is exactly when the list must
    /// keep disambiguating.
    private var nameSuggestions: [ClientDirectoryEntry] {
        clientDirectory.suggestions(forName: draft.clientNames)
            .filter { !clientDirectory.isApplied($0, number: draft.clientID, name: draft.clientNames) }
    }

    private var numberSuggestions: [ClientDirectoryEntry] {
        clientDirectory.suggestions(forNumber: draft.clientID)
            .filter { !clientDirectory.isApplied($0, number: draft.clientID, name: draft.clientNames) }
    }

    /// Known practice areas matching the typed text; the exact spelling already
    /// in the field drops out, other matches stay visible.
    private var practiceAreaSuggestions: [PracticeAreaDirectory.Entry] {
        practiceAreaDirectory.suggestions(for: draft.practiceArea)
            .filter { !practiceAreaDirectory.isApplied($0, text: draft.practiceArea) }
    }

    /// Fills both client fields from a recommendation, leaving a field alone
    /// when the entry has nothing for it (a name-only client keeps a typed ID).
    private func applyClient(_ entry: ClientDirectoryEntry) {
        if let name = entry.name { draft.clientNames = name }
        if let number = entry.clientID { draft.clientID = number }
    }

    private func matterCountLabel(_ entry: ClientDirectoryEntry) -> String {
        entry.matterCount == 1 ? "1 matter" : "\(entry.matterCount) matters"
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
        onSave(draft)
        dismiss()
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
    let invalid: Bool
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
    var accessibilityID: String? = nil

    @State private var query: String
    /// Cached search results, refreshed off the render path by `.task(id: query)`
    /// below. Holding these in state (rather than a computed property the body reads
    /// several times per keystroke) is what keeps typing responsive.
    @State private var suggestions: [JurisdictionOption] = []

    private let catalog = JurisdictionCatalog.shared

    init(
        jurisdiction: Binding<String>,
        court: Binding<String>,
        selectedCourtID: Binding<String>,
        invalid: Bool,
        focusChain: SupraFocusChain? = nil,
        focusOrder: Int = 0,
        accessibilityID: String? = nil
    ) {
        self._jurisdiction = jurisdiction
        self._court = court
        self._selectedCourtID = selectedCourtID
        self.invalid = invalid
        self.focusChain = focusChain
        self.focusOrder = focusOrder
        self.accessibilityID = accessibilityID
        let initial = JurisdictionCatalog.shared.option(id: selectedCourtID.wrappedValue)?.displayName
            ?? court.wrappedValue.ifEmpty(jurisdiction.wrappedValue)
        self._query = State(initialValue: initial)
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
                jurisdiction = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                court = ""
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
        catalog.option(id: selectedCourtID).map(catalog.authorityScope(for:))
    }

    private func optionDetail(_ option: JurisdictionOption) -> String? {
        let parts = [option.jurisdictionName, option.level.displayName]
            .filter { !$0.isEmpty && $0 != option.displayName }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func select(_ option: JurisdictionOption) {
        query = option.displayName
        selectedCourtID = option.id
        jurisdiction = option.jurisdictionName
        court = option.level == .jurisdiction ? "" : option.displayName
    }

    private func selectNotApplicable() {
        query = "N/A"
        selectedCourtID = ""
        jurisdiction = "N/A"
        court = ""
    }

    private func clear() {
        query = ""
        selectedCourtID = ""
        jurisdiction = ""
        court = ""
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
