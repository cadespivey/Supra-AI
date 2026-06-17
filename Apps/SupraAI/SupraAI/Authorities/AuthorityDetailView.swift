import SupraCore
import SupraSessions
import SwiftUI

/// Authority detail: metadata, editable preferred citation + notes, and a
/// use-status changer limited to the permitted transitions (spec §11.3–§11.4).
struct AuthorityDetailView: View {
    @ObservedObject var controller: AuthoritiesController
    let authorityID: String

    @State private var citation = ""
    @State private var notes = ""

    var body: some View {
        Group {
            if let authority = controller.authorities.first(where: { $0.id == authorityID }) {
                form(authority)
            } else {
                ContentUnavailableView("Authority not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Authority")
    }

    private func form(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        Form {
            Section {
                Text(authority.caseNameFull ?? authority.caseName).font(.headline)
                if let court = authority.court { LabeledContent("Court", value: court) }
                if let date = authority.dateFiled {
                    LabeledContent("Date filed") { Text(date, format: .dateTime.year().month().day()) }
                }
                if let docket = authority.docketNumber { LabeledContent("Docket", value: docket) }
                if let path = authority.absoluteURL, let url = URL(string: "https://www.courtlistener.com" + path) {
                    Link("View on CourtListener", destination: url)
                }
            }

            Section("Citations") {
                ForEach(authority.citations, id: \.self) { Text($0).font(.callout) }
                TextField("Preferred citation", text: $citation)
                Button("Save Citation") { controller.updatePreferredCitation(authorityID: authorityID, citation) }
            }

            Section("Status") {
                LabeledContent("Review") { ReviewBadge(state: authority.reviewState) }
                LabeledContent("Use status", value: authority.useStatus.rawValue)
                let allowed = authority.useStatus.allowedTransitions
                if allowed.isEmpty {
                    Text("No further transitions available.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu("Change Use Status") {
                        ForEach(allowed, id: \.self) { target in
                            Button(target.rawValue) { controller.changeUseStatus(authorityID: authorityID, to: target) }
                        }
                    }
                }
            }

            Section("Notes") {
                TextField("User notes", text: $notes, axis: .vertical).lineLimit(2...5)
                Button("Save Notes") { controller.updateUserNotes(authorityID: authorityID, notes) }
            }

            Section("Raw metadata") {
                DisclosureGroup("Raw CourtListener JSON") {
                    Text(authority.rawMetadataJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            citation = authority.preferredCitation ?? ""
            notes = authority.userNotes ?? ""
        }
    }
}
