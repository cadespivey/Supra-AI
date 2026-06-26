import AppKit
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
    let matterID: String
    let matterName: String
    @Environment(\.dismiss) private var dismiss

    // Caption parties (e.g. "MERIDIAN CAPITAL PARTNERS, LLC," / "Plaintiff,").
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
                captionSection
                representedSection
                recipientsSection
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
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft Notice of Appearance").font(.headline)
                Text(matterName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var captionSection: some View {
        Section {
            ForEach($parties) { $party in
                HStack {
                    TextField("Party name (e.g. ACME, INC.,)", text: $party.name)
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
            TextField("Client's full name (e.g. Atlantic Ridge Holdings, Inc.)", text: $representedPartyName)
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
            Text("Review every flagged item before filing. Unverified citations appear as visible [cite] placeholders.")
        }
    }

    private var footer: some View {
        HStack {
            if controller.isGenerating { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { dismiss() }
            Button("Generate draft") { Task { await generate() } }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isGenerating || !isReady)
        }
        .padding()
    }

    private var isReady: Bool {
        !trimmed(partyRepresented).isEmpty
            && !trimmed(representedPartyName).isEmpty
            && parties.filter { !trimmed($0.name).isEmpty && !trimmed($0.designation).isEmpty }.count >= 2
            && !completeRecipientDrafts.isEmpty
            && partialRecipientDrafts.isEmpty
    }

    private func generate() async {
        errorText = nil
        result = nil
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

        let outcome = await controller.draftNoticeOfAppearance(
            matterID: matterID,
            parties: partyLines,
            partyRepresented: trimmed(partyRepresented),
            representedPartyName: trimmed(representedPartyName),
            recipients: serviceRecipients
        )
        switch outcome {
        case let .success(artifact):
            result = artifact
        case let .failure(error):
            errorText = error.errorDescription ?? "The draft could not be generated."
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
