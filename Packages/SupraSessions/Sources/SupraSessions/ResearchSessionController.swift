import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// The planner form's inputs (spec §9.3). Title, issue, and jurisdiction are
/// required; the rest refine the search.
public struct ResearchPlanDraft: Sendable, Equatable {
    public var title: String
    public var issueText: String
    public var jurisdiction: String
    public var partyPerspective: String
    public var preferredCourts: [String]
    public var excludedCourts: [String]
    public var dateRangeStart: Date?
    public var dateRangeEnd: Date?

    public init(
        title: String = "",
        issueText: String = "",
        jurisdiction: String = "",
        partyPerspective: String = "neutral",
        preferredCourts: [String] = [],
        excludedCourts: [String] = [],
        dateRangeStart: Date? = nil,
        dateRangeEnd: Date? = nil
    ) {
        self.title = title
        self.issueText = issueText
        self.jurisdiction = jurisdiction
        self.partyPerspective = partyPerspective
        self.preferredCourts = preferredCourts
        self.excludedCourts = excludedCourts
        self.dateRangeStart = dateRangeStart
        self.dateRangeEnd = dateRangeEnd
    }

    public var isValid: Bool {
        [title, issueText, jurisdiction].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct ResearchSessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var issueText: String
    public var status: String
    public var updatedAt: Date

    init(record: ResearchSessionRecord) {
        self.id = record.id
        self.title = record.title
        self.issueText = record.issueText
        self.status = record.status
        self.updatedAt = record.updatedAt
    }
}

public enum ResearchSessionError: Error, Equatable, Sendable {
    case noApprovedQueries
}

/// Drives research-session planning for one matter: generates proposed queries
/// with the local model (no network), lets the user edit/approve them, and
/// persists the approved queries (spec §9 / WO 24). Running the searches is WO 25.
@MainActor
public final class ResearchSessionController: ObservableObject {
    public struct PlannedQuery: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var text: String
        public var approved: Bool
    }

    public enum PlanState: Sendable, Equatable {
        case idle
        case generating
        case ready
        /// Generation produced fewer than five queries (or none); manual entry allowed.
        case incomplete(String)
        case failed(String)
    }

    /// A saved query within an open session, plus its run state (WO 25).
    public struct SessionQuery: Identifiable, Sendable, Equatable {
        public let id: String
        public let text: String
        public let index: Int
        public var status: String
        public var resultCount: Int?
        public var nextURL: String?
        public var errorMessage: String?
    }

    /// A stored CourtListener result for display (decoupled from the GRDB record).
    public struct SessionResult: Identifiable, Sendable, Equatable {
        public let id: String
        public let caseName: String
        public let caseNameFull: String?
        public let citation: String?
        public let court: String?
        public let dateFiled: Date?
        public let docketNumber: String?
        public let snippet: String?
        public let reviewState: String
        public let absoluteURL: String?
        public let rawResultJSON: String
    }

    @Published public private(set) var sessions: [ResearchSessionSummary] = []
    @Published public private(set) var planState: PlanState = .idle
    @Published public var plannedQueries: [PlannedQuery] = []

    // Open-session run/detail state (WO 25).
    @Published public private(set) var openSessionID: String?
    @Published public private(set) var sessionQueries: [SessionQuery] = []
    @Published public private(set) var resultsByQuery: [String: [SessionResult]] = [:]
    @Published public private(set) var isRunning = false
    @Published public private(set) var runMessage: String?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    private let planner = ResearchQueryPlanner()
    private let tokenStore: any APIKeyStoreProtocol
    private let courtListenerClient: any CourtListenerClientProtocol
    public let matterID: String

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        matterID: String,
        defaultSystemPrompt: String? = nil,
        tokenStore: (any APIKeyStoreProtocol)? = nil,
        courtListenerClient: (any CourtListenerClientProtocol)? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.matterID = matterID
        self.defaultSystemPrompt = defaultSystemPrompt
        let resolvedTokenStore = tokenStore ?? KeychainTokenStore()
        self.tokenStore = resolvedTokenStore
        // Build the default CourtListener stack from the store; every request is
        // allowlisted, rate-limited, and logged to network_requests by the client.
        self.courtListenerClient = courtListenerClient ?? CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: resolvedTokenStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests)
            )
        )
    }

    public var hasCourtListenerToken: Bool {
        (try? tokenStore.hasCourtListenerToken()) ?? false
    }

    public func loadSessions() {
        sessions = (try? store.research.fetchSessions(matterID: matterID))?.map(ResearchSessionSummary.init) ?? []
    }

    public var approvedQueryCount: Int {
        plannedQueries.filter { $0.approved && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// At least one approved, non-empty query is required to save/run (spec §9.4).
    public var canSavePlan: Bool { approvedQueryCount >= 1 }

    public func resetPlan() {
        plannedQueries = []
        planState = .idle
    }

    public func addQuery() {
        plannedQueries.append(PlannedQuery(id: UUID(), text: "", approved: true))
    }

    public func deleteQuery(id: UUID) {
        plannedQueries.removeAll { $0.id == id }
    }

    public func setApproved(_ approved: Bool, for id: UUID) {
        guard let index = plannedQueries.firstIndex(where: { $0.id == id }) else { return }
        plannedQueries[index].approved = approved
    }

    public func updateText(_ text: String, for id: UUID) {
        guard let index = plannedQueries.firstIndex(where: { $0.id == id }) else { return }
        plannedQueries[index].text = text
    }

    /// Generates proposed queries through the local model. Falls back to
    /// `incomplete` (manual entry) when no model is loaded or the model returns
    /// fewer than five — never throws to the UI (spec §9.4 parser rule).
    public func generatePlan(draft: ResearchPlanDraft, modelID: ModelID?) async {
        guard let modelID else {
            plannedQueries = []
            planState = .incomplete("Load a model in the Models tab to generate queries, or add them manually.")
            return
        }
        planState = .generating
        do {
            let prompt = try planner.buildPrompt(
                issueText: draft.issueText,
                jurisdiction: draft.jurisdiction,
                partyPerspective: draft.partyPerspective,
                preferredCourts: draft.preferredCourts,
                excludedCourts: draft.excludedCourts,
                dateRange: formatDateRange(start: draft.dateRangeStart, end: draft.dateRangeEnd)
            )
            let output = try await collect(prompt: prompt, modelID: modelID)
            let parsed = planner.parseQueries(from: output)
            plannedQueries = parsed.map { PlannedQuery(id: UUID(), text: $0, approved: true) }
            if parsed.isEmpty {
                planState = .incomplete("Query generation didn't return any queries. Add them manually below.")
            } else if parsed.count < ResearchQueryPlanner.expectedQueryCount {
                planState = .incomplete("Query generation incomplete (\(parsed.count) of \(ResearchQueryPlanner.expectedQueryCount)). Edit or add queries as needed.")
            } else {
                planState = .ready
            }
        } catch {
            plannedQueries = []
            planState = .failed(error.localizedDescription)
        }
    }

    /// Persists the approved queries as a new research session (status
    /// `approved`) and writes a `research_queries_approved` audit event.
    @discardableResult
    public func savePlan(draft: ResearchPlanDraft) throws -> String {
        let approved = plannedQueries.filter {
            $0.approved && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !approved.isEmpty else { throw ResearchSessionError.noApprovedQueries }

        let session = try store.research.createSession(
            matterID: matterID,
            title: draft.title,
            issueText: draft.issueText,
            jurisdiction: draft.jurisdiction,
            preferredCourts: draft.preferredCourts,
            excludedCourts: draft.excludedCourts,
            dateRangeStart: draft.dateRangeStart,
            dateRangeEnd: draft.dateRangeEnd,
            status: .approved
        )
        for (index, query) in approved.enumerated() {
            _ = try store.research.createQuery(
                researchSessionID: session.id,
                queryText: query.text.trimmingCharacters(in: .whitespacesAndNewlines),
                queryIndex: index,
                status: .approved
            )
        }
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: "research_queries_approved",
            actor: "user",
            summary: "Approved \(approved.count) research quer\(approved.count == 1 ? "y" : "ies") for “\(draft.title)”",
            relatedTable: "research_sessions",
            relatedID: session.id
        )
        resetPlan()
        loadSessions()
        return session.id
    }

    // MARK: - Run (WO 25)

    /// Loads a saved session's queries + stored results into the detail state.
    public func openSession(_ sessionID: String) {
        openSessionID = sessionID
        runMessage = nil
        reloadOpenSession()
    }

    public func closeSession() {
        openSessionID = nil
        sessionQueries = []
        resultsByQuery = [:]
        runMessage = nil
    }

    /// Runnable while any approved (not-yet-run) query remains.
    public var canRunOpenSession: Bool {
        sessionQueries.contains { $0.status == ResearchQueryStatus.approved.rawValue }
    }

    /// Runs the open session's approved queries sequentially through
    /// CourtListener (spec §9.5). Continues past individual failures; session
    /// ends results_ready if any query succeeded, else failed.
    public func runApprovedSearches() async {
        guard let sessionID = openSessionID, !isRunning else { return }
        guard hasCourtListenerToken else {
            runMessage = "Add a CourtListener API token in Settings to run searches."
            return
        }
        let approved = sessionQueries
            .filter { $0.status == ResearchQueryStatus.approved.rawValue }
            .sorted { $0.index < $1.index }
        guard !approved.isEmpty else {
            runMessage = "No approved queries to run."
            return
        }

        isRunning = true
        runMessage = nil
        try? store.research.updateSessionStatus(sessionID: sessionID, status: .running)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "courtlistener_search_started", actor: "user",
            summary: "Started CourtListener search (\(approved.count) quer\(approved.count == 1 ? "y" : "ies"))",
            relatedTable: "research_sessions", relatedID: sessionID
        )

        var anySuccess = false
        var lastFailureMessage: String?
        for query in approved {
            let requestMeta = Self.jsonString(["q": query.text, "type": "o", "highlight": "true"])
            try? store.research.updateQueryExecution(queryID: query.id, status: .running, executedAt: nil)
            do {
                let response = try await courtListenerClient.searchOpinions(
                    CourtListenerSearchRequest(query: query.text, highlight: true),
                    relatedResearchSessionID: sessionID
                )
                for dto in response.results {
                    _ = try? store.research.insertResult(makeResultRecord(dto, queryID: query.id))
                }
                try? store.research.updateQueryExecution(
                    queryID: query.id, status: .completed,
                    resultCount: response.count, nextURL: response.next, executedAt: Date(),
                    requestMetadataJSON: requestMeta,
                    responseMetadataJSON: Self.responseMeta(response)
                )
                anySuccess = true
            } catch {
                try? store.research.updateQueryExecution(
                    queryID: query.id, status: .failed, executedAt: Date(),
                    requestMetadataJSON: requestMeta,
                    errorMessage: error.localizedDescription
                )
                recordNetworkDiagnostic(error, queryText: query.text)
                lastFailureMessage = error.localizedDescription
            }
        }

        let finalStatus: ResearchSessionStatus = anySuccess ? .resultsReady : .failed
        try? store.research.updateSessionStatus(
            sessionID: sessionID, status: finalStatus,
            completedAt: anySuccess ? nil : Date()
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: anySuccess ? "courtlistener_search_completed" : "courtlistener_search_failed",
            actor: "network",
            summary: anySuccess ? "CourtListener search completed" : "All CourtListener queries failed",
            relatedTable: "research_sessions", relatedID: sessionID
        )
        if !anySuccess {
            // Surface the specific reason (e.g. the §3.2 blocked / §3.4 rate-limit
            // message) rather than a generic fallback.
            runMessage = lastFailureMessage ?? "Every query failed — check your token and connection."
        }
        isRunning = false
        loadSessions()
        reloadOpenSession()
    }

    /// Fetches the next page for a completed query using its stored cursor URL
    /// (spec §9.6); host is validated by CourtListenerEndpoint before sending.
    public func loadMore(queryID: String) async {
        guard let sessionID = openSessionID, !isRunning,
              let query = sessionQueries.first(where: { $0.id == queryID }),
              let next = query.nextURL, let cursorURL = URL(string: next)
        else { return }

        isRunning = true
        runMessage = nil
        do {
            let response = try await courtListenerClient.searchOpinions(
                CourtListenerSearchRequest(query: query.text, cursorURL: cursorURL),
                relatedResearchSessionID: sessionID
            )
            for dto in response.results {
                _ = try? store.research.insertResult(makeResultRecord(dto, queryID: queryID))
            }
            let total = (try? store.research.fetchResults(queryID: queryID).count) ?? response.count
            try? store.research.updateQueryExecution(
                queryID: queryID, status: .completed,
                resultCount: total, nextURL: response.next, executedAt: Date(),
                requestMetadataJSON: Self.jsonString(["cursor": "true", "type": "o"]),
                responseMetadataJSON: Self.responseMeta(response)
            )
        } catch {
            recordNetworkDiagnostic(error, queryText: query.text)
            runMessage = "Load more failed: \(error.localizedDescription)"
        }
        isRunning = false
        reloadOpenSession()
    }

    /// Records a network/research diagnostic warning for policy/auth failures
    /// (spec §3.2 step 3). Transport/server/decode errors are not policy warnings.
    private func recordNetworkDiagnostic(_ error: Error, queryText: String) {
        guard let courtListenerError = error as? CourtListenerError else { return }
        let category: String
        switch courtListenerError {
        case .blockedByNetworkPolicy, .localRateLimitExceeded, .invalidCursorHost:
            category = "network"
        case .missingToken, .authenticationFailed:
            category = "research"
        default:
            return
        }
        try? store.diagnostics.recordDiagnosticEvent(
            DiagnosticEventRecord(
                severity: "warning",
                category: category,
                message: courtListenerError.localizedDescription,
                technicalDetails: "Query: \(queryText)"
            )
        )
    }

    private static func responseMeta(_ response: CourtListenerSearchResponse) -> String? {
        jsonString(["count": String(response.count), "has_next": String(response.next != nil)])
    }

    /// Encodes a tokenless string map to JSON for research_queries metadata
    /// (§9.5 5c) — never includes the Authorization header or token.
    private static func jsonString(_ dict: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Review & completion (WO 26)

    public enum ResultReviewAction: Sendable {
        case saveAsAuthority
        case skip
        case potentiallyAdverse
        case notAdverse
        case needsLaterReview
    }

    public var resultCount: Int {
        resultsByQuery.values.reduce(0) { $0 + $1.count }
    }

    public var unreviewedResultCount: Int {
        resultsByQuery.values.flatMap { $0 }
            .filter { $0.reviewState == ResearchResultReviewState.unreviewed.rawValue }
            .count
    }

    /// A session can be completed only once it has results and none remain
    /// unreviewed (spec §10.4).
    public var canCompleteSession: Bool {
        resultCount > 0 && unreviewedResultCount == 0
    }

    /// Applies a review action to a result: updates its review state, creates or
    /// updates the matter authority as the action dictates, and audits it. No
    /// result is ever saved automatically (spec §10.3).
    public func reviewResult(_ resultID: String, as action: ResultReviewAction) {
        guard let sessionID = openSessionID,
              let result = try? store.research.fetchResult(resultID: resultID) else { return }

        switch action {
        case .saveAsAuthority:
            try? store.research.updateResultReviewState(resultID: resultID, reviewState: .saved)
            upsertAuthority(from: result, sessionID: sessionID, reviewState: .saved, useStatus: .retrievedFromCourtListener)
            recordReviewAudit("authority_saved", result: result, summary: "Saved authority “\(result.caseName)”")
        case .skip:
            try? store.research.updateResultReviewState(resultID: resultID, reviewState: .skipped)
            recordReviewAudit("research_result_reviewed", result: result, summary: "Skipped “\(result.caseName)”")
        case .potentiallyAdverse:
            try? store.research.updateResultReviewState(resultID: resultID, reviewState: .potentiallyAdverse)
            upsertAuthority(from: result, sessionID: sessionID, reviewState: .potentiallyAdverse, useStatus: .needsCitatorCheck)
            recordReviewAudit("authority_saved", result: result, summary: "Flagged potentially adverse: “\(result.caseName)”")
        case .needsLaterReview:
            try? store.research.updateResultReviewState(resultID: resultID, reviewState: .needsLaterReview)
            upsertAuthority(from: result, sessionID: sessionID, reviewState: .needsLaterReview, useStatus: .unverified)
            recordReviewAudit("authority_saved", result: result, summary: "Marked needs-later-review: “\(result.caseName)”")
        case .notAdverse:
            try? store.research.updateResultReviewState(resultID: resultID, reviewState: .notAdverse)
            // §10.3: only update an existing authority — do not create one.
            if let existing = try? store.authorities.fetchAuthority(researchResultID: resultID) {
                try? store.authorities.updateReviewState(authorityID: existing.id, reviewState: .notAdverse)
            }
            recordReviewAudit("research_result_reviewed", result: result, summary: "Marked not adverse: “\(result.caseName)”")
        }
        reloadOpenSession()
    }

    /// Marks the open session complete; no-op (UI also blocks) when any result
    /// is still unreviewed.
    public func completeSession() {
        guard let sessionID = openSessionID, canCompleteSession else { return }
        try? store.research.updateSessionStatus(sessionID: sessionID, status: .complete, completedAt: Date())
        loadSessions()
        reloadOpenSession()
    }

    private func upsertAuthority(
        from result: ResearchResultRecord, sessionID: String,
        reviewState: ResearchResultReviewState, useStatus: AuthorityUseStatus
    ) {
        if let existing = try? store.authorities.fetchAuthority(researchResultID: result.id) {
            // The review classification (review_state) always reflects the latest
            // action. Use-status, however, is library-managed: on an existing
            // authority it may only change along the §11.4 transition graph, so a
            // re-review never silently downgrades a user-set status (e.g.
            // user_marked_verified → unverified). Legal changes are audited like
            // any other status change; illegal ones are preserved.
            try? store.authorities.updateReviewState(authorityID: existing.id, reviewState: reviewState)
            let current = AuthorityUseStatus(rawValue: existing.useStatus) ?? .unverified
            if current != useStatus, current.canTransition(to: useStatus) {
                try? store.authorities.updateUseStatus(authorityID: existing.id, useStatus: useStatus)
                _ = try? store.auditEvents.recordEvent(
                    matterID: matterID, eventType: "authority_status_changed", actor: "user",
                    summary: "“\(existing.caseName)”: \(current.rawValue) → \(useStatus.rawValue)",
                    relatedTable: "authorities", relatedID: existing.id
                )
            }
            return
        }
        let authority = AuthorityRecord(
            matterID: matterID,
            researchSessionID: sessionID,
            researchResultID: result.id,
            courtlistenerID: result.courtlistenerID,
            clusterID: result.clusterID,
            opinionID: result.opinionID,
            caseName: result.caseName,
            caseNameFull: result.caseNameFull,
            citationJSON: result.citationJSON,
            preferredCitation: result.preferredCitation,
            court: result.court,
            courtID: result.courtID,
            dateFiled: result.dateFiled,
            docketNumber: result.docketNumber,
            absoluteURL: result.absoluteURL,
            reviewState: reviewState.rawValue,
            useStatus: useStatus.rawValue,
            rawMetadataJSON: result.rawResultJSON
        )
        _ = try? store.authorities.insertAuthority(authority)
    }

    private func recordReviewAudit(_ eventType: String, result: ResearchResultRecord, summary: String) {
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: eventType, actor: "user",
            summary: summary, relatedTable: "research_results", relatedID: result.id
        )
    }

    private func reloadOpenSession() {
        guard let sessionID = openSessionID else { return }
        let queries = ((try? store.research.fetchQueries(sessionID: sessionID)) ?? [])
            .sorted { $0.queryIndex < $1.queryIndex }
        sessionQueries = queries.map {
            SessionQuery(
                id: $0.id, text: $0.queryText, index: $0.queryIndex, status: $0.status,
                resultCount: $0.resultCount, nextURL: $0.nextURL, errorMessage: $0.errorMessage
            )
        }
        var grouped: [String: [SessionResult]] = [:]
        for query in queries {
            grouped[query.id] = ((try? store.research.fetchResults(queryID: query.id)) ?? []).map { record in
                SessionResult(
                    id: record.id, caseName: record.caseName, caseNameFull: record.caseNameFull,
                    citation: record.preferredCitation, court: record.court, dateFiled: record.dateFiled,
                    docketNumber: record.docketNumber, snippet: record.snippet,
                    reviewState: record.reviewState, absoluteURL: record.absoluteURL,
                    rawResultJSON: record.rawResultJSON
                )
            }
        }
        resultsByQuery = grouped
    }

    private func makeResultRecord(_ dto: CourtListenerSearchResultDTO, queryID: String) -> ResearchResultRecord {
        let citationJSON = (try? JSONEncoder().encode(dto.citation))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ResearchResultRecord(
            researchQueryID: queryID,
            clusterID: dto.clusterID.map(String.init),
            opinionID: dto.opinions.first?.id.map(String.init),
            caseName: dto.caseName ?? dto.caseNameFull ?? "Untitled case",
            caseNameFull: dto.caseNameFull,
            citationJSON: citationJSON,
            preferredCitation: CourtListenerMapper.preferredCitation(for: dto),
            court: dto.court,
            courtID: dto.courtID,
            dateFiled: Self.parseDate(dto.dateFiled),
            docketNumber: dto.docketNumber,
            snippet: dto.opinions.first?.snippet,
            absoluteURL: dto.absoluteURL,
            rawResultJSON: dto.rawResultJSON
        )
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(string.prefix(10)))
    }

    // MARK: - Helpers

    private func collect(prompt: String, modelID: ModelID) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt,
            // Base prompt only: the output is machine-parsed into `## Query N`
            // blocks, so a free-form profile ("write only prose", "no headings")
            // must not override the required structure.
            systemPrompt: defaultSystemPrompt,
            options: GenerationOptions()
        )
        return try await runtimeClient.collectGeneratedText(request)
    }

    private func formatDateRange(start: Date?, end: Date?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        switch (start, end) {
        case (nil, nil):
            return "Any"
        case let (start?, nil):
            return "After \(formatter.string(from: start))"
        case let (nil, end?):
            return "Before \(formatter.string(from: end))"
        case let (start?, end?):
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
    }
}
