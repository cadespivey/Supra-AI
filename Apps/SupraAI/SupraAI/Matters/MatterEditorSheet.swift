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
    private let onSave: (MatterDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showValidation = false
    @State private var selectedCourtID: String

    init(mode: Mode, draft: MatterDraft, onSave: @escaping (MatterDraft) -> Void) {
        let selected = JurisdictionCatalog.shared.bestMatch(jurisdiction: draft.jurisdiction, court: draft.court)
        self.mode = mode
        self._draft = State(initialValue: draft)
        self._selectedCourtID = State(initialValue: selected?.id ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mode.title)
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top])

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
                    TextField("Client name(s)", text: $draft.clientNames, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Matter description", text: $draft.matterDescription, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Internal matter ID", text: $draft.internalMatterID)
                    TextField("Court", text: $draft.court)
                    TextField("Judge", text: $draft.judge)
                    TextField("Case number", text: $draft.docketNumber)
                    TextField("Practice area", text: $draft.practiceArea)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(mode.confirmLabel) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(showValidation && !draft.isValid)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
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
            TextField(label, text: text)
            if invalid {
                Text(message)
                    .font(.caption)
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

/// Single-field jurisdiction picker for the New Matter form: type to get live
/// court/jurisdiction suggestions, pick one, or mark the matter N/A when no
/// jurisdiction is relevant. Replaces the older search-box-plus-dropdown flow.
struct JurisdictionAutocompleteField: View {
    @Binding var jurisdiction: String
    @Binding var court: String
    @Binding var selectedCourtID: String
    let invalid: Bool

    @State private var query: String

    private let catalog = JurisdictionCatalog.shared

    init(
        jurisdiction: Binding<String>,
        court: Binding<String>,
        selectedCourtID: Binding<String>,
        invalid: Bool
    ) {
        self._jurisdiction = jurisdiction
        self._court = court
        self._selectedCourtID = selectedCourtID
        self.invalid = invalid
        let initial = JurisdictionCatalog.shared.option(id: selectedCourtID.wrappedValue)?.displayName
            ?? court.wrappedValue.ifEmpty(jurisdiction.wrappedValue)
        self._query = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Jurisdiction or court", text: queryBinding)
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
    }

    @ViewBuilder
    private var footer: some View {
        if invalid {
            Text("Jurisdiction is required. Choose N/A if it doesn't apply.")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let scope = selectedScope {
            VStack(alignment: .leading, spacing: 3) {
                Text(scope.mandatoryAuthorities.joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !scope.courtListenerIDs.isEmpty {
                    Text("CourtListener: \(scope.courtListenerIDs.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        } else if isNotApplicable {
            Text("No specific jurisdiction — authority scoping is disabled for this matter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Type to search courts and jurisdictions, or choose N/A.")
                .font(.caption)
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

    private var suggestions: [JurisdictionOption] {
        catalog.search(query, limit: 6)
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
