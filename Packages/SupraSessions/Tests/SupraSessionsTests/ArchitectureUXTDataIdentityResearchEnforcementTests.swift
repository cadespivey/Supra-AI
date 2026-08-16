import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// T-DATA-COURT-02 controller wire — unresolved identity must stop planning,
/// saving, and provider execution before any model, transport, or Store effect.
/// Caller-provided `ResearchPlanDraft` strings are presentation input, not a
/// replacement authority for the Store-owned matter snapshot.
///
/// Expected RED: all three public paths currently trust the draft or persisted
/// query filters without checking `MatterIdentitySnapshot`; recognizable legacy
/// Florida strings therefore authorize model and CourtListener work.
@MainActor
final class ArchitectureUXTDataIdentityResearchEnforcementTests: XCTestCase {
    func testUnresolvedCourtBlocksPlannerBeforeModelOrStoreEffects() async throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "research-plan")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unresolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            state: .unresolved,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(unresolvedSnapshot.courtResolutionState, .unresolved)
        XCTAssertEqual(
            unresolvedSnapshot.matterID,
            ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        )
        let runtimeCapture = ArchitectureUXIdentityRuntimeCapture()
        let transport = ArchitectureUXIdentityCourtListenerCapture()
        let controller = ResearchSessionController(
            store: fixture.store,
            runtimeClient: planningRuntime(capture: runtimeCapture),
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            tokenStore: ArchitectureUXIdentityTokenStore(),
            courtListenerClient: transport
        )
        let baselineSessions = try researchSessionOwners(store: fixture.store)
        let baselineAudits = try auditOwners(store: fixture.store)

        await controller.generatePlan(
            draft: forgedResolvedDraft(),
            modelID: ModelID(),
            route: ModelRouter().route(for: .legalResearch)
        )

        XCTAssertTrue(runtimeCapture.requests.isEmpty, "unresolved court reached the model")
        XCTAssertTrue(transport.requests.isEmpty, "planning is local and must not reach transport")
        XCTAssertTrue(controller.plannedQueries.isEmpty)
        let state = String(describing: controller.planState)
        XCTAssertTrue(
            state.localizedCaseInsensitiveContains("choose court"),
            "blocked state must name the attorney's exact recovery action: \(state)"
        )
        XCTAssertFalse(state.contains(ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt))
        XCTAssertFalse(state.contains(ArchitectureUXIdentityEnforcementWire.legacyClientCanary))
        XCTAssertFalse(state.contains(ArchitectureUXIdentityEnforcementWire.forbiddenDefault))
        XCTAssertEqual(
            try researchSessionOwners(store: fixture.store),
            baselineSessions
        )
        XCTAssertEqual(
            try auditOwners(store: fixture.store),
            baselineAudits
        )
    }

    func testUnresolvedCourtBlocksManualPlanSaveBeforeAggregateWrite() throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "research-save")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unresolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            state: .unresolved,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(unresolvedSnapshot.courtResolutionState, .unresolved)
        XCTAssertEqual(
            unresolvedSnapshot.matterID,
            ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        )
        let controller = ResearchSessionController(
            store: fixture.store,
            runtimeClient: StubRuntimeClient(),
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            tokenStore: ArchitectureUXIdentityTokenStore(),
            courtListenerClient: ArchitectureUXIdentityCourtListenerCapture()
        )
        controller.addQuery()
        let queryID = try XCTUnwrap(controller.plannedQueries.first?.id)
        controller.updateText(ArchitectureUXIdentityEnforcementWire.researchQuery, for: queryID)
        let baselineAudits = try auditOwners(store: fixture.store)

        var observedError: Error?
        do {
            let unexpectedSessionID = try controller.savePlan(draft: forgedResolvedDraft())
            XCTFail("unresolved court unexpectedly saved session \(unexpectedSessionID)")
        } catch {
            observedError = error
        }

        let error = try XCTUnwrap(observedError, "unresolved court must reject manual save")
        XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("court"))
        XCTAssertTrue(
            try fixture.store.research.fetchSessions(
                matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
            ).isEmpty
        )
        XCTAssertEqual(
            try auditOwners(store: fixture.store),
            baselineAudits
        )
        XCTAssertEqual(controller.plannedQueries.map(\.text), [
            ArchitectureUXIdentityEnforcementWire.researchQuery,
        ])
        XCTAssertFalse(String(describing: error).contains(
            ArchitectureUXIdentityEnforcementWire.forbiddenDefault
        ))
    }

    func testUnresolvedCourtBlocksApprovedRunBeforeTransportOrStateChange() async throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "research-run")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unresolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            state: .unresolved,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(unresolvedSnapshot.courtResolutionState, .unresolved)
        XCTAssertEqual(
            unresolvedSnapshot.matterID,
            ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        )
        let session = try fixture.store.research.createSession(
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            title: ArchitectureUXIdentityEnforcementWire.researchTitle,
            issueText: ArchitectureUXIdentityEnforcementWire.researchIssue,
            jurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            preferredCourts: [ArchitectureUXIdentityEnforcementWire.courtName],
            status: .approved
        )
        let query = try fixture.store.research.createQuery(
            researchSessionID: session.id,
            queryText: ArchitectureUXIdentityEnforcementWire.researchQuery,
            queryIndex: 0,
            courtFilter: "flsd,ca11,scotus",
            status: .approved
        )
        let transport = ArchitectureUXIdentityCourtListenerCapture()
        let runtimeCapture = ArchitectureUXIdentityRuntimeCapture()
        let controller = ResearchSessionController(
            store: fixture.store,
            runtimeClient: planningRuntime(capture: runtimeCapture),
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            tokenStore: ArchitectureUXIdentityTokenStore(),
            courtListenerClient: transport
        )
        controller.openSession(session.id)
        let baselineAudits = try auditOwners(store: fixture.store)

        await controller.runApprovedSearches()

        XCTAssertTrue(runtimeCapture.requests.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty, "unresolved court reached CourtListener")
        let persistedSession = try XCTUnwrap(
            fixture.store.research.fetchSessions(
                matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
            ).first { $0.id == session.id }
        )
        XCTAssertEqual(persistedSession.status, ResearchSessionStatus.approved.rawValue)
        let persistedQuery = try XCTUnwrap(
            fixture.store.research.fetchQueries(sessionID: session.id).first { $0.id == query.id }
        )
        XCTAssertEqual(persistedQuery.status, ResearchQueryStatus.approved.rawValue)
        XCTAssertNil(persistedQuery.requestMetadataJSON)
        XCTAssertNil(persistedQuery.responseMetadataJSON)
        XCTAssertEqual(
            try auditOwners(store: fixture.store),
            baselineAudits
        )
        let message = try XCTUnwrap(controller.runMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("choose court"))
        XCTAssertTrue(
            controller.requiresCourtSelection,
            "the UI needs a typed recovery state to open the exact Matter editor"
        )
        XCTAssertFalse(message.contains(ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt))
        XCTAssertFalse(message.contains(ArchitectureUXIdentityEnforcementWire.forbiddenDefault))
    }

    private func forgedResolvedDraft() -> ResearchPlanDraft {
        ResearchPlanDraft(
            title: ArchitectureUXIdentityEnforcementWire.researchTitle,
            issueText: ArchitectureUXIdentityEnforcementWire.researchIssue,
            jurisdiction: ArchitectureUXIdentityEnforcementWire.jurisdictionName,
            partyPerspective: "plaintiff",
            preferredCourts: [ArchitectureUXIdentityEnforcementWire.courtName],
            jurisdictionContext:
                "Structured jurisdiction scope: synthetic caller-forged scope 821",
            courtFilterIDs: ["flsd", "ca11", "scotus"]
        )
    }

    private func researchSessionOwners(store: SupraStore) throws -> [String] {
        try store.research.fetchSessions(
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        ).map {
            [$0.id, $0.title, $0.issueText, $0.jurisdiction, $0.status]
                .joined(separator: "\u{1F}")
        }
    }

    private func auditOwners(store: SupraStore) throws -> [String] {
        try store.auditEvents.fetchEvents(
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        ).map {
            [
                $0.id, $0.eventType, $0.actor, $0.summary,
                $0.relatedTable ?? "<nil>", $0.relatedID ?? "<nil>",
            ].joined(separator: "\u{1F}")
        }
    }

    private func planningRuntime(
        capture: ArchitectureUXIdentityRuntimeCapture
    ) -> StubRuntimeClient {
        StubRuntimeClient { request in
            capture.record(request)
            return .events([
                .event(request, 1, .token, token: """
                ## Query 1
                identity wire query 1
                ## Query 2
                identity wire query 2
                ## Query 3
                identity wire query 3
                ## Query 4
                identity wire query 4
                ## Query 5
                identity wire query 5
                """),
                .event(request, 2, .generationCompleted),
            ])
        }
    }
}

final class ArchitectureUXIdentityRuntimeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [GenerateRequest] = []

    var requests: [GenerateRequest] { lock.withLock { storedRequests } }

    func record(_ request: GenerateRequest) {
        lock.withLock { storedRequests.append(request) }
    }
}

private struct ArchitectureUXIdentityTokenStore: APIKeyStoreProtocol, Sendable {
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { "identity-token-827" }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { true }
}

final class ArchitectureUXIdentityCourtListenerCapture:
    CourtListenerClientProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequests: [CourtListenerSearchRequest] = []

    var requests: [CourtListenerSearchRequest] { lock.withLock { storedRequests } }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        lock.withLock { storedRequests.append(request) }
        return CourtListenerSearchResponse(count: 0, next: nil, previous: nil, results: [])
    }
}
