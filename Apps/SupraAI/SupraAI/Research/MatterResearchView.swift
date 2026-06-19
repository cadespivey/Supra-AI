import SupraSessions
import SwiftUI

/// The matter's Research tab: lists research sessions and opens the planner.
/// Running searches and reviewing results happen in the session detail view.
struct MatterResearchView: View {
    @ObservedObject var controller: ResearchSessionController
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @State private var showPlanner = false

    var body: some View {
        NavigationStack {
            MatterTabScaffold("Research Sessions") {
                Button { showPlanner = true } label: {
                    Label("New Research Session", systemImage: "plus")
                }
                .accessibilityIdentifier("research.newSession")
            } content: {
                content
            }
            .navigationDestination(for: String.self) { sessionID in
                ResearchSessionDetailView(controller: controller, sessionID: sessionID)
            }
        }
        .sheet(isPresented: $showPlanner) {
            ResearchPlannerView(controller: controller, library: library, matter: matter)
        }
        .onAppear { controller.loadSessions() }
    }

    @ViewBuilder
    private var content: some View {
        if controller.sessions.isEmpty {
            ContentUnavailableView {
                Label("No Research Sessions", systemImage: "magnifyingglass")
            } description: {
                Text("Plan and run CourtListener research for this matter.")
            } actions: {
                Button("New Research Session") { showPlanner = true }
                    .accessibilityIdentifier("research.newSession.empty")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("research.empty")
        } else {
            List(controller.sessions) { session in
                NavigationLink(value: session.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(session.title).font(.body.weight(.medium))
                            Spacer()
                            Text(session.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(session.issueText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
