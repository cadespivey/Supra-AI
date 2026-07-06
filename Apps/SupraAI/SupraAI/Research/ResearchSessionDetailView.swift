import AppKit
import SupraDesignSystem
import SupraResearch
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// A research session's detail: run the approved queries through CourtListener,
/// review each stored result (Save as Authority / Skip / adverse markers), and
/// complete the session once nothing is unreviewed (WO 25–26).
struct ResearchSessionDetailView: View {
    @ObservedObject var controller: ResearchSessionController
    let sessionID: String

    @State private var selectedResult: ResearchSessionController.SessionResult?
    @State private var readerWidth: CGFloat = 760

    /// The panel must never outgrow the pane it slides over (narrow windows).
    private func clampedReaderWidth(container: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: { min(readerWidth, max(420, container - 24)) },
            set: { readerWidth = $0 }
        )
    }

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
        // The case opens as a wide, resizable READER sliding over the result
        // list (same inspector pattern as the chat's [A#] reader) instead of a
        // small modal sheet — opinions are for reading, not peeking.
        .overlay(alignment: .trailing) {
            if let result = selectedResult {
                GeometryReader { geo in
                SlideOverPanel(
                    width: clampedReaderWidth(container: geo.size.width),
                    minWidth: 420,
                    onClose: { selectedResult = nil }
                ) {
                    ResearchCaseReader(controller: controller, result: result) {
                        selectedResult = nil
                    }
                    // Fresh identity per result: opening a DIFFERENT case while
                    // the reader is up must reset every bit of reader state
                    // (fetched opinion, format picker) — never show case A's
                    // opinion under case B's title.
                    .id(result.id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: selectedResult != nil)
        .closesOnEscape(when: selectedResult != nil) { selectedResult = nil }
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
                    EditableQueryHeader(controller: controller, query: query)
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

    private func emptyText(for query: ResearchSessionController.SessionQuery) -> String {
        switch query.status {
        case "completed": "No results."
        case "failed": query.errorMessage ?? "Query failed."
        case "running": "Running…"
        default: "Not run yet."
        }
    }
}

/// The query row header in the results list. Review now lives with the results
/// (not a pre-run gate in the planner), so this shows the query + its run status and
/// lets the user edit the query text and re-run it in place.
private struct EditableQueryHeader: View {
    @ObservedObject var controller: ResearchSessionController
    let query: ResearchSessionController.SessionQuery

    @State private var isEditing = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                TextField("Query", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .accessibilityIdentifier("session.query.edit")
                Button("Save & Re-run", action: commit)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isRunning)
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.plain)
            } else {
                Text(query.text).font(.supraHeadline)
                Spacer()
                Text(statusLabel).font(.supraCaption).foregroundStyle(.secondary)
                Button { text = query.text; isEditing = true } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit this query")
                .accessibilityIdentifier("session.query.editButton")
                Button { Task { await controller.rerunQuery(queryID: query.id) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(controller.isRunning || !controller.hasCourtListenerToken)
                .help("Re-run this query")
            }
        }
    }

    /// Commits the edited text (which resets the query to approved and clears its old
    /// results) and immediately re-runs it.
    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.updateSessionQueryText(queryID: query.id, text: trimmed)
        isEditing = false
        Task { await controller.rerunQuery(queryID: query.id) }
    }

    private var statusLabel: String {
        if let count = query.resultCount { return "\(query.status) · \(count)" }
        return query.status
    }
}

/// The five review actions (spec §10.3), reused by the row and the detail sheet.
struct ResultReviewMenu: View {
    @ObservedObject var controller: ResearchSessionController
    let resultID: String

    var body: some View {
        Menu("Review") {
            Button { controller.reviewResult(resultID, as: .saveAsAuthority) } label: {
                Label("Save as Authority", systemImage: "bookmark")
            }
            Button { controller.reviewResult(resultID, as: .skip) } label: {
                Label("Skip", systemImage: "forward")
            }
            Button { controller.reviewResult(resultID, as: .potentiallyAdverse) } label: {
                Label("Mark Potentially Adverse", systemImage: "exclamationmark.triangle")
            }
            Button { controller.reviewResult(resultID, as: .notAdverse) } label: {
                Label("Mark Not Adverse", systemImage: "checkmark.shield")
            }
            Button { controller.reviewResult(resultID, as: .needsLaterReview) } label: {
                Label("Needs Later Review", systemImage: "clock")
            }
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

/// The research result as a full READER: case header, review actions, and the
/// opinion in the richest available format (official HTML, else full text
/// scrolled to the matching passage). Hosted in the session view's slideover.
private struct ResearchCaseReader: View {
    @ObservedObject var controller: ResearchSessionController
    let result: ResearchSessionController.SessionResult
    let onClose: () -> Void

    @State private var opinion: CourtListenerOpinionDetailDTO?
    @State private var loadingOpinion = false
    @State private var exportingHTML = false

    /// The current result from the controller, so the review badge reflects an
    /// in-reader review immediately instead of the (stale) snapshot captured
    /// when the reader was presented.
    private var liveResult: ResearchSessionController.SessionResult {
        controller.resultsByQuery.values.flatMap { $0 }.first { $0.id == result.id } ?? result
    }

    var body: some View {
        CaseReaderPanel(
            title: result.caseNameFull ?? result.caseName,
            subtitle: subtitle,
            courtListenerURL: result.absoluteURL.flatMap(AuthorityReaderView.courtListenerURL),
            html: opinion?.bestHTML,
            text: opinion?.bodyText ?? result.snippet,
            highlight: result.snippet,
            bluebook: BluebookCitation(
                caseName: result.caseNameFull ?? result.caseName,
                citation: result.citation,
                court: result.court,
                year: result.dateFiled.map { Calendar.current.component(.year, from: $0) }
            ),
            isLoading: loadingOpinion,
            onClose: onClose
        ) {
            ReviewBadge(state: liveResult.reviewState)
            ResultReviewMenu(controller: controller, resultID: result.id)
                .fixedSize()
            if opinion?.bestHTML != nil {
                Button { exportingHTML = true } label: {
                    Label("Download HTML…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.ghost)
            }
            Menu {
                Button("Copy Raw CourtListener JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.rawResultJSON, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .task(id: result.id) {
            // Belt-and-braces with the call site's `.id(result.id)`: reset any
            // stale state, and never let a cancelled (superseded) fetch land.
            opinion = nil
            loadingOpinion = false
            guard result.opinionID != nil, controller.hasCourtListenerToken else { return }
            loadingOpinion = true
            let fetched = await controller.fetchOpinionDetail(opinionID: result.opinionID)
            if !Task.isCancelled {
                opinion = fetched
                loadingOpinion = false
            }
        }
        .fileExporter(
            isPresented: $exportingHTML,
            document: (opinion?.bestHTML).map { HTMLFileDocument(text: OpinionWebView.document(for: $0)) },
            contentType: .html,
            defaultFilename: AuthorityDetailView.fileName(for: result.caseName)
        ) { _ in }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let citation = result.citation { parts.append(citation) }
        if let court = result.court { parts.append(court) }
        if let date = result.dateFiled { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let docket = result.docketNumber { parts.append("No. " + docket) }
        return parts.joined(separator: " · ")
    }
}
