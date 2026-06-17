import Combine
import Foundation
import SupraCore
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

    @Published public private(set) var sessions: [ResearchSessionSummary] = []
    @Published public private(set) var planState: PlanState = .idle
    @Published public var plannedQueries: [PlannedQuery] = []

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    private let planner = ResearchQueryPlanner()
    public let matterID: String

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        matterID: String,
        defaultSystemPrompt: String? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.matterID = matterID
        self.defaultSystemPrompt = defaultSystemPrompt
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

    // MARK: - Helpers

    private func collect(prompt: String, modelID: ModelID) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt,
            systemPrompt: defaultSystemPrompt,
            options: GenerationOptions()
        )
        var output = ""
        for try await event in try runtimeClient.generate(request) {
            if event.type == .token, let token = event.tokenText {
                output += token
            }
        }
        return output
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
