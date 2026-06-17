import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

private struct StubTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    var token: String? = "test-token"
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { token }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { token != nil }
}

private struct StubCourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    var response: CourtListenerSearchResponse = .init(count: 0, next: nil, previous: nil, results: [])
    var shouldFail = false
    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        if shouldFail { throw CourtListenerError.serverError(statusCode: 500) }
        return response
    }
}

@MainActor
final class SupraSessionsTests: XCTestCase {

    // MARK: - GlobalChatController

    func testSendPersistsConversationAndStreamsTokens() async throws {
        let store = try makeStore()
        let modelID = ModelID()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Hel"),
                .event(request, 3, .token, token: "lo"),
                .event(request, 4, .metrics, metrics: RuntimeMetrics(generatedTokenCount: 2)),
                .event(request, 5, .generationCompleted, metrics: RuntimeMetrics(generatedTokenCount: 2))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: modelID, systemPrompt: nil, options: GenerationOptions())

        XCTAssertFalse(controller.isGenerating)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages[0].role, .user)
        XCTAssertEqual(controller.messages[0].content, "Hi")
        XCTAssertEqual(controller.messages[1].role, .assistant)
        XCTAssertEqual(controller.messages[1].content, "Hello")
        XCTAssertEqual(controller.messages[1].status, .completed)

        // Persisted across a fresh controller instance.
        let reopened = GlobalChatController(store: store, runtimeClient: stub)
        reopened.loadChats()
        XCTAssertEqual(reopened.messages.map(\.content), ["Hi", "Hello"])
        XCTAssertEqual(reopened.messages.last?.status, .completed)
    }

    func testCancelledEventPreservesPartialOutput() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Partial"),
                .event(request, 3, .generationCancelled, metrics: RuntimeMetrics(cancellationLatencyMs: 0))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Write a long thing", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.content, "Partial")
        XCTAssertEqual(controller.messages.last?.status, .cancelled)
    }

    func testFailedEventMarksAssistantFailed() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "X"),
                .event(request, 3, .generationFailed, error: RuntimeError(category: "generationFailed", message: "boom"))
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertEqual(controller.errorMessage, "boom")
    }

    func testStreamWithoutTerminalEventMarksInterrupted() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "Partial")
            ])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.last?.status, .interrupted)
        XCTAssertEqual(controller.messages.last?.content, "Partial")
    }

    func testRejectedStreamMarksAssistantFailed() async throws {
        let store = try makeStore()
        let rejection = GenerateStartResponse(
            status: .modelNotLoaded,
            generationID: GenerationID(),
            error: RuntimeError(category: "modelNotLoaded", message: "No model is loaded.")
        )
        let stub = StubRuntimeClient { _ in .reject(RuntimeClientError.generationRejected(rejection)) }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testSendCreatesChatWhenNoneSelected() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .generationCompleted)])
        }
        let controller = GlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        XCTAssertTrue(controller.chats.isEmpty)

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.chats.count, 1)
        XCTAssertNotNil(controller.selectedChatID)
    }

    // MARK: - MattersController

    func testMattersControllerCreatesMatterWithScopedChats() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = MattersController(store: store, runtimeClient: stub)
        controller.loadMatters()
        XCTAssertTrue(controller.matters.isEmpty)

        let matter = try controller.createMatter(name: "Acme v. Roe")
        XCTAssertEqual(controller.matters.count, 1)
        XCTAssertEqual(controller.selectedMatterID, matter.id)

        // Creating a matter also creates a default matter chat and a
        // matter_created audit event (WO 23 / spec §8.3).
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).count, 1)
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).first?.title, "General — Acme v. Roe")
        let auditEvents = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(auditEvents.contains { $0.eventType == "matter_created" })

        let chat = try XCTUnwrap(controller.chatController)
        _ = try chat.createChat(title: "Issue 1")

        // The chats are scoped to the matter (default + new), not the global list.
        XCTAssertEqual(chat.chats.count, 2)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).count, 2)
    }

    func testMattersControllerCreateEditDeleteFlow() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = MattersController(store: store, runtimeClient: stub)

        let matter = try controller.createMatter(
            MatterDraft(name: "Doe v. Roe", jurisdiction: "California", partyPerspective: .plaintiff)
        )
        XCTAssertEqual(controller.selectedMatter?.jurisdiction, "California")
        XCTAssertEqual(controller.selectedMatter?.partyPerspective, .plaintiff)

        var draft = try XCTUnwrap(controller.draft(forMatter: matter.id))
        draft.partyPerspective = .defendant
        draft.court = "N.D. Cal."
        try controller.updateMatter(id: matter.id, draft: draft)
        XCTAssertEqual(controller.selectedMatter?.partyPerspective, .defendant)
        XCTAssertEqual(controller.draft(forMatter: matter.id)?.court, "N.D. Cal.")

        controller.deleteMatter(id: matter.id)
        XCTAssertTrue(controller.matters.isEmpty)
        XCTAssertNil(controller.selectedMatterID)
    }

    // MARK: - ResearchSessionController

    func testResearchPlannerGeneratesParsesAndPersistsApprovedQueries() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California", partyPerspective: .plaintiff)
        let markdown = """
        # Research Queries
        ## Query 1
        first
        ## Query 2
        second
        ## Query 3
        third
        ## Query 4
        fourth
        ## Query 5
        fifth
        """
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: markdown),
                .event(request, 3, .generationCompleted)
            ])
        }
        let controller = ResearchSessionController(store: store, runtimeClient: stub, matterID: matter.id)

        let draft = ResearchPlanDraft(title: "Plan A", issueText: "Issue", jurisdiction: "California", partyPerspective: "plaintiff")
        await controller.generatePlan(draft: draft, modelID: ModelID())
        XCTAssertEqual(controller.plannedQueries.count, 5)
        XCTAssertEqual(controller.planState, .ready)
        XCTAssertTrue(controller.canSavePlan)

        // Unapprove one query; only approved queries persist.
        controller.setApproved(false, for: controller.plannedQueries[0].id)
        let sessionID = try controller.savePlan(draft: draft)

        XCTAssertEqual(try store.research.fetchQueries(sessionID: sessionID).count, 4)
        XCTAssertEqual(controller.sessions.count, 1)
        XCTAssertTrue(controller.plannedQueries.isEmpty, "plan resets after save")
        let audit = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(audit.contains { $0.eventType == "research_queries_approved" })
    }

    func testResearchPlannerWithoutModelAllowsManualEntry() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = ResearchSessionController(store: store, runtimeClient: stub, matterID: matter.id)

        await controller.generatePlan(
            draft: ResearchPlanDraft(title: "P", issueText: "I", jurisdiction: "CA"),
            modelID: nil
        )
        guard case .incomplete = controller.planState else {
            return XCTFail("Expected .incomplete without a loaded model, got \(controller.planState)")
        }
        XCTAssertFalse(controller.canSavePlan)

        controller.addQuery()
        controller.updateText("manual query", for: controller.plannedQueries[0].id)
        XCTAssertTrue(controller.canSavePlan)
        let sessionID = try controller.savePlan(draft: ResearchPlanDraft(title: "P", issueText: "I", jurisdiction: "CA"))
        XCTAssertEqual(try store.research.fetchQueries(sessionID: sessionID).count, 1)
    }

    // MARK: - Research run (WO 25)

    private func seedApprovedSession(_ store: SupraStore, matterID: String) throws -> String {
        let session = try store.research.createSession(
            matterID: matterID, title: "S", issueText: "I", jurisdiction: "CA", status: .approved
        )
        _ = try store.research.createQuery(researchSessionID: session.id, queryText: "q1", queryIndex: 0, status: .approved)
        _ = try store.research.createQuery(researchSessionID: session.id, queryText: "q2", queryIndex: 1, status: .approved)
        return session.id
    }

    private func makeRunController(
        store: SupraStore, matterID: String,
        client: StubCourtListenerClient, token: String? = "test-token"
    ) -> ResearchSessionController {
        ResearchSessionController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in .events([]) },
            matterID: matterID,
            tokenStore: StubTokenStore(token: token),
            courtListenerClient: client
        )
    }

    func testRunApprovedSearchesStoresResultsAndMarksResultsReady() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)

        let dto = CourtListenerSearchResultDTO(
            caseName: "Roe v. Doe", citation: ["1 U.S. 1"], court: "SCOTUS",
            dateFiled: "2020-01-15",
            opinions: [CourtListenerOpinionDTO(id: 9, type: nil, snippet: "snippet", downloadURL: nil, localPath: nil, authorID: nil, perCuriam: nil, sha1: nil)],
            rawResultJSON: "{\"x\":1}"
        )
        let client = StubCourtListenerClient(response: .init(count: 1, next: nil, previous: nil, results: [dto]))
        let controller = makeRunController(store: store, matterID: matter.id, client: client)

        controller.openSession(sessionID)
        XCTAssertTrue(controller.canRunOpenSession)
        await controller.runApprovedSearches()

        XCTAssertEqual(
            try store.research.fetchSessions(matterID: matter.id).first { $0.id == sessionID }?.status,
            ResearchSessionStatus.resultsReady.rawValue
        )
        let q1 = controller.sessionQueries[0]
        XCTAssertEqual(q1.status, ResearchQueryStatus.completed.rawValue)
        XCTAssertEqual(controller.resultsByQuery[q1.id]?.first?.caseName, "Roe v. Doe")
        XCTAssertEqual(controller.resultsByQuery[q1.id]?.first?.citation, "1 U.S. 1")
        let audit = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(audit.contains { $0.eventType == "courtlistener_search_started" })
        XCTAssertTrue(audit.contains { $0.eventType == "courtlistener_search_completed" })
    }

    func testRunMarksSessionFailedWhenEveryQueryFails() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let controller = makeRunController(
            store: store, matterID: matter.id,
            client: StubCourtListenerClient(shouldFail: true)
        )

        controller.openSession(sessionID)
        await controller.runApprovedSearches()

        XCTAssertEqual(
            try store.research.fetchSessions(matterID: matter.id).first { $0.id == sessionID }?.status,
            ResearchSessionStatus.failed.rawValue
        )
        XCTAssertTrue(controller.sessionQueries.allSatisfy { $0.status == ResearchQueryStatus.failed.rawValue })
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "courtlistener_search_failed" })
    }

    func testRunWithoutTokenDoesNotRunAndSurfacesMessage() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let controller = makeRunController(
            store: store, matterID: matter.id,
            client: StubCourtListenerClient(), token: nil
        )

        controller.openSession(sessionID)
        await controller.runApprovedSearches()

        XCTAssertNotNil(controller.runMessage)
        XCTAssertEqual(controller.sessionQueries[0].status, ResearchQueryStatus.approved.rawValue, "queries stay approved when no token")
    }

    // MARK: - Result review (WO 26)

    func testReviewActionsCreateAuthoritiesAndGateCompletion() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Roe v. Doe", citation: ["1 U.S. 1"], rawResultJSON: "{}")
        let client = StubCourtListenerClient(response: .init(count: 1, next: nil, previous: nil, results: [dto]))
        let controller = makeRunController(store: store, matterID: matter.id, client: client)

        controller.openSession(sessionID)
        await controller.runApprovedSearches()
        XCTAssertEqual(controller.resultCount, 2)            // one result per query
        XCTAssertEqual(controller.unreviewedResultCount, 2)
        XCTAssertFalse(controller.canCompleteSession, "blocked while results are unreviewed")

        let results = controller.resultsByQuery.values.flatMap { $0 }
        controller.reviewResult(results[0].id, as: .saveAsAuthority)
        XCTAssertFalse(controller.canCompleteSession, "still one unreviewed")
        controller.reviewResult(results[1].id, as: .potentiallyAdverse)

        let authorities = try store.authorities.fetchAuthorities(matterID: matter.id)
        XCTAssertEqual(authorities.count, 2, "both review actions created authorities")
        XCTAssertTrue(authorities.contains { $0.useStatus == AuthorityUseStatus.retrievedFromCourtListener.rawValue })
        XCTAssertTrue(authorities.contains { $0.useStatus == AuthorityUseStatus.needsCitatorCheck.rawValue })

        XCTAssertEqual(controller.unreviewedResultCount, 0)
        XCTAssertTrue(controller.canCompleteSession)
        controller.completeSession()
        XCTAssertEqual(
            try store.research.fetchSessions(matterID: matter.id).first { $0.id == sessionID }?.status,
            ResearchSessionStatus.complete.rawValue
        )
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "authority_saved" })
    }

    func testSkipDoesNotCreateAuthority() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Roe v. Doe", rawResultJSON: "{}")
        let client = StubCourtListenerClient(response: .init(count: 1, next: nil, previous: nil, results: [dto]))
        let controller = makeRunController(store: store, matterID: matter.id, client: client)

        controller.openSession(sessionID)
        await controller.runApprovedSearches()
        for result in controller.resultsByQuery.values.flatMap({ $0 }) {
            controller.reviewResult(result.id, as: .skip)
        }
        XCTAssertTrue(try store.authorities.fetchAuthorities(matterID: matter.id).isEmpty)
        XCTAssertTrue(controller.canCompleteSession)
    }

    // MARK: - Authority library (WO 27)

    func testAuthorityUseStatusTransitionsEnforcedAndAudited() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "CA", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Roe"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Roe", useStatus: AuthorityUseStatus.retrievedFromCourtListener.rawValue
        ))

        let controller = AuthoritiesController(store: store, matterID: matter.id)
        controller.load()
        let id = try XCTUnwrap(controller.authorities.first?.id)

        // Disallowed: retrieved_from_courtlistener → unverified.
        XCTAssertFalse(controller.changeUseStatus(authorityID: id, to: .unverified))
        XCTAssertEqual(controller.authorities[0].useStatus, .retrievedFromCourtListener)

        // Allowed: retrieved_from_courtlistener → needs_citator_check (+ audit).
        XCTAssertTrue(controller.changeUseStatus(authorityID: id, to: .needsCitatorCheck))
        XCTAssertEqual(controller.authorities[0].useStatus, .needsCitatorCheck)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "authority_status_changed" })

        // Preferred citation + notes edits persist.
        controller.updatePreferredCitation(authorityID: id, "1 U.S. 1")
        controller.updateUserNotes(authorityID: id, "key holding")
        XCTAssertEqual(controller.authorities[0].preferredCitation, "1 U.S. 1")
        XCTAssertEqual(controller.authorities[0].userNotes, "key holding")
    }

    // MARK: - Structured outputs (WO 28)

    func testCreateOutputCompleteWhenAllSectionsPresent() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)
        let markdown = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        let ok = await controller.createOutput(type: .ruleSynthesis, context: "issue + authorities", modelID: ModelID())
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.outputs.count, 1)
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(controller.outputs[0].missingCount, 0)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "structured_output_created" })
    }

    func testCreateOutputNeedsReviewWhenSectionsMissing() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: "# Rule Synthesis\n## Rule Statement\nonly one section"), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        _ = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: ModelID())
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertGreaterThan(controller.outputs[0].missingCount, 0)
        // version 1 stored with the missing sections
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).count, 1)
    }

    func testCreateOutputWithoutModelDoesNothing() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let stub = StubRuntimeClient { _ in .events([]) }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)
        let ok = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(controller.outputs.isEmpty)
        XCTAssertNotNil(controller.message)
    }

    // MARK: - ModelLibrary

    func testAddAndActivateLoadsModel() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient(loadResult: LoadModelResponse(status: .loaded, modelID: ModelID(), metrics: RuntimeMetrics(loadTimeMs: 5)))
        let library = ModelLibrary(store: store, runtimeClient: stub)

        let summary = try library.addModel(displayName: "Local 32B", path: "/tmp/model", bookmarkData: nil)
        XCTAssertEqual(library.models.count, 1)

        await library.activateAndLoad(modelID: summary.id)

        XCTAssertEqual(library.loadState, .loaded(modelID: summary.id))
        XCTAssertEqual(library.activeModel?.id, summary.id)
        XCTAssertNotNil(library.loadedModelID)
    }

    func testActivateSurfacesLoadFailure() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient(loadResult: LoadModelResponse(
            status: .failed,
            error: RuntimeError(category: "modelLoadFailed", message: "missing weights")
        ))
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let summary = try library.addModel(displayName: "Broken", path: "/tmp/broken", bookmarkData: nil)

        await library.activateAndLoad(modelID: summary.id)

        XCTAssertEqual(library.loadState, .failed(message: "missing weights"))
    }

    func testActivateFailsWhenBookmarkCannotBeAccessed() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient() // would return .loaded if it were ever reached
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let summary = try library.addModel(
            displayName: "Bookmarked",
            path: "/tmp/model",
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        await library.activateAndLoad(modelID: summary.id)

        guard case let .failed(message) = library.loadState else {
            return XCTFail("Expected a failed load state when the bookmark cannot be accessed.")
        }
        XCTAssertTrue(message.contains("Could not access"))
    }

    // MARK: - Helpers

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

// MARK: - Stub runtime client

enum GenerationOutcome {
    case events([GenerationEvent])
    case reject(Error)
}

final class StubRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let loadResult: LoadModelResponse
    private let outcome: @Sendable (GenerateRequest) -> GenerationOutcome
    private let lock = NSLock()
    private var _cancelledGenerationIDs: [GenerationID] = []

    var cancelledGenerationIDs: [GenerationID] {
        lock.withLock { _cancelledGenerationIDs }
    }

    init(
        loadResult: LoadModelResponse = LoadModelResponse(status: .loaded, modelID: ModelID()),
        outcome: @escaping @Sendable (GenerateRequest) -> GenerationOutcome = { _ in .events([]) }
    ) {
        self.loadResult = loadResult
        self.outcome = outcome
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        loadResult
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let outcome = outcome(request)
        return AsyncThrowingStream { continuation in
            switch outcome {
            case let .events(events):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            case let .reject(error):
                continuation.finish(throwing: error)
            }
        }
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        lock.withLock { _cancelledGenerationIDs.append(generationID) }
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        loadResult
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(state: .modelLoaded, loadedModelID: loadResult.modelID, activeGenerationID: nil, message: nil, metrics: nil)
    }

    func restartRuntimeService() async throws {}
}

extension GenerationEvent {
    static func event(
        _ request: GenerateRequest,
        _ sequenceNumber: Int,
        _ type: GenerationEventType,
        token: String? = nil,
        metrics: RuntimeMetrics? = nil,
        error: RuntimeError? = nil
    ) -> GenerationEvent {
        GenerationEvent(
            generationID: request.generationID,
            sequenceNumber: sequenceNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceNumber)),
            type: type,
            tokenText: token,
            message: nil,
            metrics: metrics,
            error: error
        )
    }
}
