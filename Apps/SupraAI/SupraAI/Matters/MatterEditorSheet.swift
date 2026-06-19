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
    @State private var jurisdictionSearch: String

    init(mode: Mode, draft: MatterDraft, onSave: @escaping (MatterDraft) -> Void) {
        let selected = JurisdictionCatalog.shared.bestMatch(jurisdiction: draft.jurisdiction, court: draft.court)
        self.mode = mode
        self._draft = State(initialValue: draft)
        self._selectedCourtID = State(initialValue: selected?.id ?? "")
        self._jurisdictionSearch = State(initialValue: selected?.displayName ?? draft.court.ifEmpty(draft.jurisdiction))
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
                    JurisdictionSelectionField(
                        title: "Jurisdiction",
                        selectedCourtID: $selectedCourtID,
                        searchText: $jurisdictionSearch,
                        onSelect: applyJurisdiction
                    )
                    field("Governing jurisdiction", text: $draft.jurisdiction, invalid: jurisdictionInvalid, message: "Jurisdiction is required.")
                        .onChange(of: draft.jurisdiction) { _, newValue in
                            clearSelectionIfManualJurisdiction(newValue)
                        }
                    Picker("Party perspective", selection: $draft.partyPerspective) {
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
                    TextField("Internal matter ID number", text: $draft.internalMatterID)
                    TextField("Court", text: $draft.court)
                    TextField("Judge", text: $draft.judge)
                    TextField("Docket number", text: $draft.docketNumber)
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

    private func applyJurisdiction(_ option: JurisdictionOption?) {
        guard let option else { return }
        draft.jurisdiction = option.jurisdictionName
        draft.court = option.level == .jurisdiction ? "" : option.displayName
    }

    private func clearSelectionIfManualJurisdiction(_ value: String) {
        guard let option = JurisdictionCatalog.shared.option(id: selectedCourtID) else { return }
        if option.jurisdictionName.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            selectedCourtID = ""
        }
    }
}

struct JurisdictionSelectionField: View {
    let title: String
    @Binding var selectedCourtID: String
    @Binding var searchText: String
    var onSelect: (JurisdictionOption?) -> Void

    private let catalog = JurisdictionCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search courts or jurisdictions", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Picker(title, selection: selection) {
                Text("Manual / custom jurisdiction").tag("")
                ForEach(pickerOptions, id: \.id) { option in
                    Text(option.menuTitle).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            if let selectedOption {
                let scope = catalog.authorityScope(for: selectedOption)
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
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { selectedCourtID },
            set: { newValue in
                selectedCourtID = newValue
                guard let option = catalog.option(id: newValue) else {
                    onSelect(nil)
                    return
                }
                searchText = option.displayName
                onSelect(option)
            }
        )
    }

    private var selectedOption: JurisdictionOption? {
        catalog.option(id: selectedCourtID)
    }

    private var pickerOptions: [JurisdictionOption] {
        var options: [JurisdictionOption] = []
        if let selectedOption {
            options.append(selectedOption)
        }
        for option in catalog.search(searchText, limit: 80) where !options.contains(where: { $0.id == option.id }) {
            options.append(option)
        }
        return options
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
