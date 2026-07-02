import SupraDesignSystem
import SupraResearch
import SupraSessions
import SwiftUI

/// A research session's detail: run the approved queries through CourtListener,
/// review each stored result (Save as Authority / Skip / adverse markers), and
/// complete the session once nothing is unreviewed (WO 25–26).
struct ResearchSessionDetailView: View {
    @ObservedObject var controller: ResearchSessionController
    let sessionID: String

    @State private var selectedResult: ResearchSessionController.SessionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            runBar
            warningsBanner
            completionBar
            Divider()
            queriesList
        }
        .navigationTitle("Research Session")
        .onAppear { controller.openSession(sessionID) }
        .sheet(item: $selectedResult) { result in
            ResultDetailSheet(controller: controller, result: result)
        }
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            Button { Task { await controller.runApprovedSearches() } } label: {
                HStack(spacing: 6) {
                    if controller.isRunning { ProgressView().controlSize(.small) }
                    Text(controller.isRunning ? "Running…" : "Run Approved Searches")
                }
            }
            .disabled(!controller.canRunOpenSession || controller.isRunning || !controller.hasCourtListenerToken)
            researchStatusBadge
            Spacer()
        }
        .padding()
    }

    /// §14.2 research badges: active during a run, blocked when no token exists.
    @ViewBuilder
    private var researchStatusBadge: some View {
        if controller.isRunning {
            SupraStatusBadge("Research Network Active")
        } else if !controller.hasCourtListenerToken {
            SupraStatusBadge("Research Blocked")
        }
    }

    /// §14.3 token/network states + run errors, as §14.5 banners.
    @ViewBuilder
    private var warningsBanner: some View {
        if !controller.hasCourtListenerToken {
            SupraWarningBanner(
                .blocking, title: "No CourtListener Token",
                message: "Add a CourtListener API token in Settings to run research."
            )
            .padding([.horizontal, .bottom])
        } else if let message = controller.runMessage {
            let blocked = message.localizedCaseInsensitiveContains("blocked")
            SupraWarningBanner(
                blocked ? .blocking : .warning,
                title: blocked ? "Network Blocked" : "Run Incomplete",
                message: message
            )
            .padding([.horizontal, .bottom])
        }
    }

    @ViewBuilder
    private var completionBar: some View {
        if controller.resultCount > 0 {
            if controller.canCompleteSession {
                HStack {
                    Button("Mark Session Complete") { controller.completeSession() }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else {
                // §14.5 Warning level: completion is blocked, but it's a soft gate
                // (the user just needs to finish reviewing).
                SupraWarningBanner(
                    .warning, title: "Review Incomplete",
                    message: "\(controller.unreviewedResultCount) result(s) still unreviewed."
                )
                .padding([.horizontal, .bottom])
            }
        }
    }

    private var queriesList: some View {
        List {
            ForEach(controller.sessionQueries) { query in
                Section {
                    let results = controller.resultsByQuery[query.id] ?? []
                    if results.isEmpty {
                        Text(emptyText(for: query)).font(.supraCaption).foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { resultRow($0) }
                    }
                    if query.nextURL != nil {
                        Button("Load More") { Task { await controller.loadMore(queryID: query.id) } }
                            .disabled(controller.isRunning)
                    }
                } header: {
                    HStack {
                        Text(query.text).font(.supraHeadline)
                        Spacer()
                        Text(statusLabel(query)).font(.supraCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func resultRow(_ result: ResearchSessionController.SessionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.caseName).font(.supraHeadline)
                Spacer()
                ReviewBadge(state: result.reviewState)
            }
            HStack(spacing: 8) {
                if let citation = result.citation { Text(citation) }
                if let court = result.court { Text(court) }
                if let date = result.dateFiled { Text(date, format: .dateTime.year().month().day()) }
            }
            .font(.supraCaption)
            .foregroundStyle(.secondary)
            if let snippet = result.snippet, !snippet.isEmpty {
                Text(snippet).font(.supraCaption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 12) {
                ResultReviewMenu(controller: controller, resultID: result.id)
                Button("Details") { selectedResult = result }
                Spacer()
            }
            .font(.caption)
            .padding(.top, 2)
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

/// The five review actions (spec §10.3), reused by the row and the detail sheet.
struct ResultReviewMenu: View {
    @ObservedObject var controller: ResearchSessionController
    let resultID: String

    var body: some View {
        Menu("Review") {
            Button("Save as Authority") { controller.reviewResult(resultID, as: .saveAsAuthority) }
            Button("Skip") { controller.reviewResult(resultID, as: .skip) }
            Button("Mark Potentially Adverse") { controller.reviewResult(resultID, as: .potentiallyAdverse) }
            Button("Mark Not Adverse") { controller.reviewResult(resultID, as: .notAdverse) }
            Button("Needs Later Review") { controller.reviewResult(resultID, as: .needsLaterReview) }
        }
    }
}

struct ReviewBadge: View {
    let state: String

    var body: some View {
        Text(label)
            .font(.supraCaption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case "saved": "Saved"
        case "skipped": "Skipped"
        case "potentially_adverse": "Potentially adverse"
        case "not_adverse": "Not adverse"
        case "needs_later_review": "Needs later review"
        default: "Unreviewed"
        }
    }

    private var color: Color {
        switch state {
        case "saved": .green
        case "potentially_adverse": .orange
        case "not_adverse": .blue
        case "needs_later_review": .yellow
        default: .secondary
        }
    }
}

private struct ResultDetailSheet: View {
    @ObservedObject var controller: ResearchSessionController
    let result: ResearchSessionController.SessionResult
    @Environment(\.dismiss) private var dismiss
    @State private var opinion: CourtListenerOpinionDetailDTO?
    @State private var loadingOpinion = false
    @State private var showHTML = false

    /// The current result from the controller, so the review badge reflects an
    /// in-sheet review immediately instead of the (stale) snapshot captured when
    /// the sheet was presented.
    private var liveResult: ResearchSessionController.SessionResult {
        controller.resultsByQuery.values.flatMap { $0 }.first { $0.id == result.id } ?? result
    }

    var body: some View {
        SupraSheetScaffold(result.caseNameFull ?? result.caseName, onClose: { dismiss() }) {
            Form {
                Section {
                    if let citation = result.citation { LabeledContent("Citation", value: citation) }
                    if let court = result.court { LabeledContent("Court", value: court) }
                    if let date = result.dateFiled {
                        LabeledContent("Date filed") { Text(date, format: .dateTime.year().month().day()) }
                    }
                    if let docket = result.docketNumber { LabeledContent("Docket", value: docket) }
                    if let path = result.absoluteURL, let url = URL(string: "https://www.courtlistener.com" + path) {
                        Link("View on CourtListener", destination: url)
                    }
                    if loadingOpinion {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading opinion…").foregroundStyle(.secondary) }
                    } else if opinion?.bestHTML != nil {
                        Button { showHTML = true } label: { Label("View opinion (HTML)", systemImage: "doc.richtext") }
                    }
                }
                if let passage = enrichedPassage {
                    Section("Excerpt") { Text(passage).supraReadingBody().textSelection(.enabled) }
                } else if let snippet = result.snippet, !snippet.isEmpty {
                    Section("Snippet") {
                        Text(snippet).supraReadingBody()
                        if loadingOpinion {
                            Text("Loading a longer passage…").font(.supraCaption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Review") {
                    ReviewBadge(state: liveResult.reviewState)
                    ResultReviewMenu(controller: controller, resultID: result.id)
                }
                Section("Raw metadata") {
                    DisclosureGroup("Raw CourtListener JSON") {
                        Text(result.rawResultJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        // §14.4 inspector-panel width behavior.
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 560, minHeight: 480, idealHeight: 600)
        .sheet(isPresented: $showHTML) {
            if let html = opinion?.bestHTML {
                OpinionHTMLSheet(
                    title: result.caseName,
                    html: html,
                    suggestedFileName: AuthorityDetailView.fileName(for: result.caseName)
                )
            }
        }
        .onAppear(perform: loadOpinionIfPossible)
    }

    /// A ~50–100 word passage from the full opinion, windowed on the search snippet
    /// so it shows the relevant language. Nil until the opinion loads.
    private var enrichedPassage: String? {
        CourtListenerText.passage(from: opinion?.bodyText, around: result.snippet)
    }

    private func loadOpinionIfPossible() {
        guard opinion == nil, !loadingOpinion,
              result.opinionID != nil, controller.hasCourtListenerToken else { return }
        loadingOpinion = true
        Task { @MainActor in
            opinion = await controller.fetchOpinionDetail(opinionID: result.opinionID)
            loadingOpinion = false
        }
    }
}
