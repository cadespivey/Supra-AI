import SupraSessions
import SwiftUI

/// The matter's Authorities tab: the saved-authority library with drill-in to a
/// detail editor (spec §11).
struct MatterAuthoritiesView: View {
    @ObservedObject var controller: AuthoritiesController
    var onNewResearch: () -> Void = {}

    var body: some View {
        NavigationStack {
            Group {
                if controller.authorities.isEmpty {
                    ContentUnavailableView {
                        Label("No Authorities Saved", systemImage: "books.vertical")
                    } description: {
                        Text("Save reviewed CourtListener results to build this matter's authority library.")
                    } actions: {
                        Button("New Research Session") { onNewResearch() }
                    }
                } else {
                    List(controller.authorities) { authority in
                        NavigationLink(value: authority.id) { row(authority) }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                AuthorityDetailView(controller: controller, authorityID: id)
            }
        }
        .onAppear { controller.load() }
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
