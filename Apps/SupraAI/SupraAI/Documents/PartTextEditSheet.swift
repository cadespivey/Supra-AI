import AppKit
import SupraSessions
import SwiftUI

/// Focused correction workspace: editable selected text beside an immutable
/// revision ledger. The visual hierarchy mirrors a legal redline review rather
/// than presenting history as incidental metadata.
struct PartTextEditSheet: View {
    let draft: DocumentPartCorrectionDraft
    let onSave: (String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var reason = ""
    @State private var errorMessage: String?

    init(
        draft: DocumentPartCorrectionDraft,
        onSave: @escaping (String, String) throws -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                editorPane
                    .frame(minWidth: 430, maxWidth: .infinity)
                Divider()
                historyPane
                    .frame(width: 310)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Correct extracted text")
                    .font(.supraTitle)
                Text("\(draft.documentName) · Part \(draft.partIndex + 1)")
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Original revisions are preserved", systemImage: "lock.doc")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected text")
                .font(.supraHeadline)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }
                .accessibilityIdentifier("documents.partEditor")

            VStack(alignment: .leading, spacing: 5) {
                Text("Reason for correction")
                    .font(.supraHeadline)
                TextField("Describe what changed", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("documents.editReason")
                Text("The reason is stored with this revision for later review.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.supraCaption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Revision history (\(draft.history.count))")
                .font(.supraHeadline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(draft.history.reversed())) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(revision.origin == "user_edit" ? "User correction" : "Extracted")
                                    .font(.supraCaption.weight(.medium))
                                    .foregroundStyle(revision.origin == "user_edit" ? Color.accentColor : .secondary)
                                Spacer()
                                Text(revision.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.supraCaption)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(revision.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = revision.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.supraCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.045))
    }

    private var actionBar: some View {
        HStack {
            Text("Saving starts reindexing. Citations already bound to older revisions do not move.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save correction") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("documents.saveCorrection")
        }
        .padding(12)
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text != draft.text
    }

    private func save() {
        do {
            try onSave(text, reason)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
