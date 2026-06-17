import SupraCore
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

    init(mode: Mode, draft: MatterDraft, onSave: @escaping (MatterDraft) -> Void) {
        self.mode = mode
        self._draft = State(initialValue: draft)
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
                    field("Jurisdiction", text: $draft.jurisdiction, invalid: jurisdictionInvalid, message: "Jurisdiction is required.")
                    Picker("Party perspective", selection: $draft.partyPerspective) {
                        ForEach(PartyPerspective.allCases, id: \.self) { perspective in
                            Text(perspective.rawValue.capitalized).tag(perspective)
                        }
                    }
                }

                Section("Optional") {
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
        .frame(width: 460, height: 540)
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
