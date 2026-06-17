import SupraSessions
import SwiftUI

/// A research session's detail: run the approved queries through CourtListener
/// and show the stored results per query, with Load More for pagination (WO 25).
/// Result review actions arrive in WO 26.
struct ResearchSessionDetailView: View {
    @ObservedObject var controller: ResearchSessionController
    let sessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            runBar
            if let message = controller.runMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding([.horizontal, .bottom])
            }
            Divider()
            queriesList
        }
        .navigationTitle("Research Session")
        .onAppear { controller.openSession(sessionID) }
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            Button { Task { await controller.runApprovedSearches() } } label: {
                HStack(spacing: 6) {
                    if controller.isRunning { ProgressView().controlSize(.small) }
                    Text(controller.isRunning ? "Running…" : "Run Approved Searches")
                }
            }
            .disabled(!controller.canRunOpenSession || controller.isRunning)
            if !controller.hasCourtListenerToken {
                Text("No CourtListener token — add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var queriesList: some View {
        List {
            ForEach(controller.sessionQueries) { query in
                Section {
                    let results = controller.resultsByQuery[query.id] ?? []
                    if results.isEmpty {
                        Text(emptyText(for: query))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { resultRow($0) }
                    }
                    if query.nextURL != nil {
                        Button("Load More") { Task { await controller.loadMore(queryID: query.id) } }
                            .disabled(controller.isRunning)
                    }
                } header: {
                    HStack {
                        Text(query.text).font(.callout.weight(.medium))
                        Spacer()
                        Text(statusLabel(query)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func resultRow(_ result: ResearchSessionController.SessionResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.caseName).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let citation = result.citation { Text(citation) }
                if let court = result.court { Text(court) }
                if let date = result.dateFiled {
                    Text(date, format: .dateTime.year().month().day())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let snippet = result.snippet, !snippet.isEmpty {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusLabel(_ query: ResearchSessionController.SessionQuery) -> String {
        if let count = query.resultCount { return "\(query.status) · \(count)" }
        return query.status
    }

    private func emptyText(for query: ResearchSessionController.SessionQuery) -> String {
        switch query.status {
        case "completed": "No results."
        case "failed": query.errorMessage ?? "Query failed."
        case "running": "Running…"
        default: "Not run yet."
        }
    }
}
