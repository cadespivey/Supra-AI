import SupraCore
import SupraSessions
import SupraStore
import SwiftUI

/// A matter's Billing tab (Milestone 4 Phase 7, spec §9): the per-matter override
/// text and UTBMS code set, plus the client's uploaded billing-guideline documents.
/// These layer on top of the firm-wide ScratchPad billing settings at draft time —
/// the override and the guideline text both reach the billing-draft prompt.
struct MatterBillingView: View {
    @ObservedObject var controller: BillingProfileController
    @State private var importing = false

    var body: some View {
        MatterTabScaffold("Billing Rules", actions: {
            Button("Save") { controller.save() }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.hasUnsavedChanges)
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    codeSetSection
                    overrideSection
                    guidelinesSection
                    if let message = controller.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: controller.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { controller.importGuidelines(urls) }
        }
    }

    // MARK: - Code set

    private var codeSetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UTBMS code set").font(.headline)
            Picker("UTBMS code set", selection: codeSetBinding) {
                ForEach(BillingCodeSet.allCases, id: \.self) { set in
                    Text(set.displayLabel).tag(set)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Text("Governs the task codes proposed for this matter. Litigation uses UTBMS L-codes; transactional and advisory matters carry the firm's task codes; “No task codes” bills with a blank task code.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var codeSetBinding: Binding<BillingCodeSet> {
        Binding(
            get: { controller.codeSet },
            set: { controller.codeSet = $0; controller.markEdited() }
        )
    }

    // MARK: - Override

    private var overrideSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Override instructions").font(.headline)
            TextField(
                "Override instructions",
                text: overrideBinding,
                prompt: Text("e.g. Bill travel at 50%; no charge for filing/service tasks; this client requires task-level detail"),
                axis: .vertical
            )
            .lineLimit(3...8)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            Text("Layered on top of the firm-wide billing instructions for this matter's lines.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var overrideBinding: Binding<String> {
        Binding(
            get: { controller.overrideInstructions },
            set: { controller.overrideInstructions = $0; controller.markEdited() }
        )
    }

    // MARK: - Guidelines

    private var guidelinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Client billing guidelines").font(.headline)
                Spacer()
                Button {
                    importing = true
                } label: {
                    Label("Add guideline…", systemImage: "plus")
                }
                .disabled(!controller.importReady)
            }
            if controller.guidelineDocuments.isEmpty {
                Text(controller.importReady
                     ? "No billing-guideline documents yet. Upload the client's guidelines so their rules shape this matter's drafts."
                     : "Finish Document Intelligence setup in Settings before uploading guidelines.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(controller.guidelineDocuments) { document in
                    guidelineRow(document)
                    Divider()
                }
            }
        }
    }

    private func guidelineRow(_ document: MatterDocumentRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.displayName).lineLimit(1).truncationMode(.middle)
                Text(controller.isExtracted(document) ? "Text extracted — feeds this matter's drafts." : "Processing…")
                    .font(.caption2)
                    .foregroundStyle(controller.isExtracted(document) ? .green : .secondary)
            }
            Spacer()
            Button {
                controller.removeGuideline(documentID: document.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove from guidelines (keeps the document in the matter library)")
        }
        .padding(.vertical, 4)
    }
}
