import SupraSessions
import SwiftUI

/// The matter's Authorities tab: the saved-authority library with drill-in to a
/// detail editor (spec §11).
struct MatterAuthoritiesView: View {
    @ObservedObject var controller: AuthoritiesController
    var onNewResearch: () -> Void = {}
    @State private var pendingDelete: AuthoritiesController.AuthorityItem?

    var body: some View {
        NavigationStack {
            MatterTabScaffold("Authorities") {
                Button { onNewResearch() } label: {
                    Label("New Research Session", systemImage: "plus")
                }
                .accessibilityIdentifier("authorities.newResearch.header")
            } content: {
                if controller.authorities.isEmpty {
                    ContentUnavailableView {
                        Label("No Authorities Saved", systemImage: "books.vertical")
                    } description: {
                        Text("Save reviewed CourtListener results to build this matter's authority library.")
                    } actions: {
                        Button("New Research Session") { onNewResearch() }
                            .accessibilityIdentifier("authorities.newResearch")
                    }
                    .accessibilityIdentifier("authorities.empty")
                } else {
                    List(controller.authorities) { authority in
                        NavigationLink(value: authority.id) { row(authority) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = authority } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = authority } label: {
                                    Label("Delete Authority", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                AuthorityDetailView(controller: controller, authorityID: id)
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Remove “\($0.caseName)”?" } ?? "Remove authority?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Remove Authority", role: .destructive) {
                if let authority = pendingDelete { controller.deleteAuthority(id: authority.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from the matter's authority library. You can re-add it by saving the result again from Research.")
        }
        .onAppear { controller.load() }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func row(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(authority.caseName).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let citation = authority.preferredCitation ?? authority.citations.first { Text(citation) }
                if let court = authority.court { Text(court) }
                if let date = authority.dateFiled { Text(date, format: .dateTime.year().month().day()) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ReviewBadge(state: authority.reviewState)
                Text(authority.useStatus.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
