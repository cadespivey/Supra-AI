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
    var failure: CourtListenerError?
    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        if let failure { throw failure }
        if shouldFail { throw CourtListenerError.serverError(statusCode: 500) }
        return response
    }
}

private final class CapturingCourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let response: CourtListenerSearchResponse
    private let lock = NSLock()
    private var _requests: [CourtListenerSearchRequest] = []
    private var _relatedSessionIDs: [String?] = []

    var requests: [CourtListenerSearchRequest] { lock.withLock { _requests } }
    var relatedSessionIDs: [String?] { lock.withLock { _relatedSessionIDs } }

    init(response: CourtListenerSearchResponse) {
        self.response = response
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        lock.withLock {
            _requests.append(request)
            _relatedSessionIDs.append(relatedResearchSessionID)
        }
        return response
    }
}

private final class SequencedCourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [CourtListenerSearchResponse]

    init(responses: [CourtListenerSearchResponse]) {
        self.responses = responses
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        lock.withLock {
            if responses.isEmpty {
                return CourtListenerSearchResponse(count: 0, results: [])
            }
            return responses.removeFirst()
        }
    }
}

/// Search stub that also serves a full opinion body from `fetchOpinion`, so the
/// top-authority hydration path can be exercised.
private final class HydratingCourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let response: CourtListenerSearchResponse
    private let opinionBody: String
    private let lock = NSLock()
    private var _fetchedOpinionIDs: [Int] = []
    var fetchedOpinionIDs: [Int] { lock.withLock { _fetchedOpinionIDs } }

    init(response: CourtListenerSearchResponse, opinionBody: String) {
        self.response = response
        self.opinionBody = opinionBody
    }

    func searchOpinions(_ request: CourtListenerSearchRequest, relatedResearchSessionID: String?) async throws -> CourtListenerSearchResponse {
        response
    }

    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        lock.withLock { _fetchedOpinionIDs.append(id) }
        return CourtListenerOpinionDetailDTO(plainText: opinionBody)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let reopened = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
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
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        XCTAssertTrue(controller.chats.isEmpty)

        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        XCTAssertEqual(controller.chats.count, 1)
        XCTAssertNotNil(controller.selectedChatID)
    }

    // MARK: - Chat history (rename / delete / move) + auto-title

    func testFirstSendAutoTitlesChatFromPrompt() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(
            prompt: "What are the elements of negligence?",
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions()
        )

        XCTAssertEqual(controller.chats.first?.title, "What are the elements of negligence?")
        XCTAssertNotEqual(controller.chats.first?.title, "New Chat")
    }

    func testAutoTitleUsesRoutedPromptNotRawSlashCommand() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        // The view sends the routed (slash-stripped) prompt plus the raw text as
        // displayPrompt. The title should come from the routed prompt.
        await controller.performSend(
            prompt: "draft a tolling agreement",
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions(),
            displayPrompt: "/draft a tolling agreement"
        )

        XCTAssertEqual(controller.chats.first?.title, "draft a tolling agreement")
        XCTAssertFalse(controller.chats.first?.title.hasPrefix("/") ?? true)
    }

    func testDerivedTitleTruncatesOnWordBoundary() {
        let long = "Please draft a comprehensive demand letter regarding unpaid invoices owed by a former client"
        let title = GlobalChatController.derivedTitle(from: long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 49)
        XCTAssertFalse(title.dropLast().hasSuffix(" "))
        XCTAssertEqual(GlobalChatController.derivedTitle(from: "   "), "New Chat")
        XCTAssertEqual(GlobalChatController.derivedTitle(from: "Short one"), "Short one")
    }

    func testStartNewChatClearsSelectionWithoutCreatingEmptyRow() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        XCTAssertNotNil(controller.selectedChatID)

        controller.startNewChat()
        XCTAssertNil(controller.selectedChatID)
        XCTAssertTrue(controller.messages.isEmpty)
        // The prior chat is preserved; no empty placeholder was created.
        XCTAssertEqual(controller.chats.count, 1)
    }

    func testRenameChatUpdatesTitle() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        let chatID = try XCTUnwrap(controller.selectedChatID)

        controller.renameChat(chatID: chatID, title: "Negligence research")
        XCTAssertEqual(controller.chats.first { $0.id == chatID }?.title, "Negligence research")
        // Blank rename is a no-op.
        controller.renameChat(chatID: chatID, title: "   ")
        XCTAssertEqual(controller.chats.first { $0.id == chatID }?.title, "Negligence research")
    }

    func testDeleteChatRemovesFromListAndDeselects() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        let chatID = try XCTUnwrap(controller.selectedChatID)

        controller.deleteChat(chatID: chatID)
        XCTAssertTrue(controller.chats.isEmpty)
        XCTAssertNil(controller.selectedChatID)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
    }

    func testMoveChatToMatterRemovesFromGlobalAndRecordsAudit() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        let chatID = try XCTUnwrap(controller.selectedChatID)

        controller.moveChat(chatID: chatID, toMatter: matter.id)

        XCTAssertTrue(controller.chats.isEmpty)
        XCTAssertNil(controller.selectedChatID)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        let matterChats = try store.chats.fetchMatterChats(matterID: matter.id)
        XCTAssertTrue(matterChats.contains { $0.id == chatID })
        let audits = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(audits.contains { $0.eventType == "chat_moved_to_matter" })
    }

    func testMoveToMissingMatterSurfacesErrorAndRecordsNoAudit() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        let chatID = try XCTUnwrap(controller.selectedChatID)

        controller.moveChat(chatID: chatID, toMatter: "nonexistent-matter-id")

        // The move failed cleanly: the chat stays in the global list and NO phantom
        // "moved" audit event is recorded against the missing matter.
        XCTAssertEqual(controller.chats.map(\.id), [chatID])
        XCTAssertEqual(controller.selectedChatID, chatID)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(try store.auditEvents.fetchEvents(relatedTable: "chats", relatedID: chatID).isEmpty)
    }

    func testMatterStartNewChatThenSendCreatesMatterScopedTitledChat() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id))
        controller.loadChats()
        let initialCount = controller.chats.count   // the default "General — Acme" chat

        // "New Chat" in a matter clears selection; the chat is created lazily on send.
        controller.startNewChat()
        XCTAssertNil(controller.selectedChatID)

        await controller.performSend(
            prompt: "Draft a tolling agreement",
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions()
        )

        let matterChats = try store.chats.fetchMatterChats(matterID: matter.id)
        XCTAssertEqual(matterChats.count, initialCount + 1)         // a new matter-scoped chat exists
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)   // it is NOT global
        XCTAssertEqual(controller.chats.first?.title, "Draft a tolling agreement")  // auto-titled, not "New Chat"
    }

    func testChatSuggestionsSampleIsDistinctAndSized() {
        let four = ChatSuggestions.sample(count: 4)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(Set(four.map(\.id)).count, 4)

        // Requesting more than the catalog returns the whole catalog, de-duplicated.
        let everything = ChatSuggestions.sample(count: ChatSuggestions.all.count + 10)
        XCTAssertEqual(everything.count, ChatSuggestions.all.count)
        XCTAssertEqual(Set(ChatSuggestions.all.map(\.id)).count, ChatSuggestions.all.count)
        XCTAssertGreaterThanOrEqual(ChatSuggestions.all.count, 30)
        XCTAssertTrue(ChatSuggestions.sample(count: 0).isEmpty)
    }

    func testDraftRouteUsesDraftingPresetAndPromptWithoutResearch() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(draftingModel: "Draft")).route(for: .drafting)
        let stub = StubRuntimeClient { request in
            XCTAssertEqual(request.options.preset, .drafting)
            XCTAssertEqual(request.options.thinkingBudget, .lowOrOff)
            XCTAssertTrue(request.systemPrompt?.contains("legal drafting assistant") ?? false)
            return .events([
                .event(request, 1, .token, token: "Drafted letter."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let court = StubCourtListenerClient(shouldFail: true)
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()

        await controller.performSend(
            prompt: "Write a demand letter",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(controller.messages.last?.content, "Drafted letter.")
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testLegalResearchWithoutJurisdictionAsksClarifyingQuestion() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let stub = StubRuntimeClient { _ in
            XCTFail("Runtime should not run until jurisdiction is supplied.")
            return .events([])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        await controller.performSend(
            prompt: "What are the elements of promissory estoppel?",
            modelID: nil,
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertTrue(controller.messages.last?.content.contains("I need the jurisdiction") ?? false)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    /// An explicit jurisdiction selection in a global chat must bind CourtListener
    /// (so research proceeds instead of asking) and bound the query's court IDs.
    func testGlobalChatExplicitJurisdictionBoundsCourtListenerQuery() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer with sources."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()
        controller.jurisdictionOverrideID = "federal-courts"

        // The prompt names no jurisdiction; the explicit selection must bind it.
        await controller.performSend(
            prompt: "What are the elements of promissory estoppel?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(controller.messages.last?.content, "Answer with sources.")
        XCTAssertFalse(court.requests.isEmpty)
        // Federal selection → SCOTUS + circuits, never an unbounded (empty) query.
        XCTAssertTrue(court.requests.allSatisfy { !$0.courtIDs.isEmpty })
        XCTAssertTrue(court.requests.contains { $0.courtIDs.contains("scotus") })
    }

    /// Auto-detect must infer a jurisdiction the classifier's built-in shortlist
    /// misses (Wyoming), so research is still bounded rather than asking.
    func testGlobalChatAutoDetectsJurisdictionFromPrompt() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()
        // jurisdictionOverrideID stays "" (auto-detect).

        await controller.performSend(
            prompt: "Research the Wyoming promissory estoppel doctrine.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(controller.messages.last?.content, "Answer.")
        XCTAssertFalse(court.requests.isEmpty)
        XCTAssertTrue(court.requests.allSatisfy { !$0.courtIDs.isEmpty })
    }

    /// A federal reporter citation in the prompt ("123 F.3d 456") must auto-detect
    /// federal jurisdiction, so case-law research proceeds (CourtListener is bounded)
    /// instead of asking for jurisdiction.
    func testGlobalChatAutoDetectsFederalJurisdictionFromCitation() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()
        // jurisdictionOverrideID stays "" (auto-detect).

        await controller.performSend(
            prompt: "Summarize the holding in 123 F.3d 456.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(controller.messages.last?.content, "Answer.")
        XCTAssertFalse(court.requests.isEmpty)
        // The cited case pins itself: the citation-first request is deliberately
        // UNBOUNDED (no court/date filter) with the reporter cite as a filter;
        // any topical requests stay forum-bounded.
        let citationRequest = try XCTUnwrap(court.requests.first { $0.citation == "123 F.3d 456" })
        XCTAssertTrue(citationRequest.courtIDs.isEmpty)
        XCTAssertNil(citationRequest.dateFiledAfter)
        XCTAssertTrue(court.requests.filter { $0.citation == nil && $0.caseName == nil }.allSatisfy { !$0.courtIDs.isEmpty })
        XCTAssertFalse(controller.messages.last?.content.contains("I need the jurisdiction") ?? true)
    }

    /// A follow-up that names no jurisdiction ("the statute") must inherit the federal
    /// jurisdiction established by an earlier turn's citation, rather than asking.
    func testGlobalChatInheritsFederalJurisdictionFromPriorTurn() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        // The statutory question needs citable primary law to proceed; ground it in a
        // canned offline provision (the point under test is jurisdiction inheritance).
        let provision = StatutoryProvision(
            sourceID: "stub-statutes",
            sourceName: "Stub Statutes",
            weightTier: .currencyVerifiable,
            jurisdictionID: "us-code",
            jurisdictionName: "United States Code",
            citation: "18 U.S.C. § 1001",
            heading: "Statements or entries generally",
            text: "Whoever, in any matter within the jurisdiction of the executive, legislative, or judicial branch, knowingly and willfully falsifies, conceals, or covers up a material fact shall be fined or imprisoned.",
            url: "https://example.test/usc/18/1001",
            effectiveDate: "2024-01-01"
        )
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            courtListenerClient: court,
            statutoryOrchestrator: StatutorySourceOrchestrator(
                sources: [StubStatutorySource(result: StatutoryLookupResult(provisions: [provision]))]
            )
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What is 18 U.S.C. § 1001?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )
        await controller.performSend(
            prompt: "What is the exact language of the statute?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(controller.messages.last?.content, "Answer.")
        XCTAssertFalse(controller.messages.last?.content.contains("I need the jurisdiction") ?? true)
        XCTAssertFalse(court.requests.isEmpty)
    }

    func testRequiresRuntimeModelInheritsJurisdictionFromPriorTurn() async throws {
        let store = try makeStore()
        let config = LegalModelConfiguration(jurisdictionRequired: true)
        let route = ModelRouter(configuration: config).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()

        // Turn 1 establishes federal jurisdiction via a U.S.C. citation.
        await controller.performSend(
            prompt: "What is 18 U.S.C. § 1001?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        // The follow-up carries no citation of its own. The model-preload preflight
        // must still report that a model is required, because the send path infers
        // the federal jurisdiction from the prior turn — otherwise the UI sends with
        // no model loaded and the answer is replaced by a "load a model" error.
        let routed = ModelRouter(configuration: config)
            .routePrompt("/research What is the exact language of the statute?")
        XCTAssertEqual(routed.route.mode, .legalResearch)
        XCTAssertTrue(
            controller.requiresRuntimeModel(for: routed),
            "Preflight should require a model because the follow-up inherits the prior turn's federal jurisdiction"
        )
    }

    func testExportTranscriptMarkdownLabelsTurnsAndStripsReasoning() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "<think>musing</think>Hello there."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()
        await controller.performSend(prompt: "Hi", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        let chatID = try XCTUnwrap(controller.selectedChatID)
        let markdown = controller.exportTranscriptMarkdown(chatID: chatID, title: "My Chat")

        XCTAssertTrue(markdown.hasPrefix("# My Chat"))
        XCTAssertTrue(markdown.contains("**You:**"))
        XCTAssertTrue(markdown.contains("Hi"))
        XCTAssertTrue(markdown.contains("**Assistant:**"))
        XCTAssertTrue(markdown.contains("Hello there."))
        XCTAssertFalse(markdown.contains("musing"))  // chain-of-thought stripped
    }

    func testChatGenerationOptionsArePerChatAndIndependentOfGlobalDefault() throws {
        let store = try makeStore()
        try store.appSettings.setSetting(
            SettingsController.generationDefaultsKey,
            value: GenerationOptions(preset: .balanced, temperature: 0.5)
        )
        let controller = makeGlobalChatController(store: store, runtimeClient: StubRuntimeClient { _ in .events([]) })
        controller.loadChats()

        // A new chat starts from the app-wide default.
        let chatA = try controller.createChat(title: "A")
        XCTAssertEqual(controller.activeChatOptions.temperature, 0.5, accuracy: 0.0001)

        // Customizing scopes to that chat and persists across reselection.
        controller.setActiveChatTemperature(0.9)
        controller.select(chatID: nil)
        XCTAssertEqual(controller.activeChatOptions.temperature, 0.5, accuracy: 0.0001)
        controller.select(chatID: chatA.id)
        XCTAssertEqual(controller.activeChatOptions.temperature, 0.9, accuracy: 0.0001)

        // Changing the global default leaves an already-customized chat untouched...
        try store.appSettings.setSetting(
            SettingsController.generationDefaultsKey,
            value: GenerationOptions(preset: .precise, temperature: 0.3)
        )
        controller.select(chatID: chatA.id)
        XCTAssertEqual(controller.activeChatOptions.temperature, 0.9, accuracy: 0.0001)

        // ...but a brand-new chat follows the new default.
        _ = try controller.createChat(title: "B")
        XCTAssertEqual(controller.activeChatOptions.temperature, 0.3, accuracy: 0.0001)
    }

    func testNewChatAdoptsPreSendTemperatureCustomization() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Hi."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub)
        controller.loadChats()

        // Customize a brand-new (not-yet-created) chat, then send.
        controller.startNewChat()
        controller.setActiveChatTemperature(0.85)
        await controller.performSend(
            prompt: "Hello",
            modelID: ModelID(),
            systemPrompt: nil,
            options: controller.activeChatOptions
        )

        // The created chat kept the customization; a fresh controller reloads it.
        let chatID = try XCTUnwrap(controller.selectedChatID)
        let reloaded = makeGlobalChatController(store: store, runtimeClient: stub)
        reloaded.loadChats()
        reloaded.select(chatID: chatID)
        XCTAssertEqual(reloaded.activeChatOptions.temperature, 0.85, accuracy: 0.0001)
    }

    func testChatAutoPurgeRemovesExpiredChatsKeepsRecent() throws {
        let store = try makeStore()
        let maintenance = DocumentMaintenance(store: store)
        maintenance.setAutoPurgeDays(30)
        let old = try store.chats.createGlobalChat(title: "Old")
        let recent = try store.chats.createGlobalChat(title: "Recent")
        _ = try store.chats.softDeleteChat(id: old.id, deletedAt: Date(timeIntervalSinceNow: -40 * 86_400))
        _ = try store.chats.softDeleteChat(id: recent.id, deletedAt: Date(timeIntervalSinceNow: -5 * 86_400))

        XCTAssertEqual(maintenance.purgeExpiredChats(), 1)
        XCTAssertEqual(try store.chats.fetchSoftDeletedChats().map(\.id), [recent.id])

        // A retention of 0 disables the purge.
        maintenance.setAutoPurgeDays(0)
        _ = try store.chats.softDeleteChat(id: recent.id, deletedAt: Date(timeIntervalSinceNow: -90 * 86_400))
        XCTAssertEqual(maintenance.purgeExpiredChats(), 0)
    }

    func testRecycleBinListsAndRestoresMatterAndChat() throws {
        let store = try makeStore()
        let bin = RecycleBinController(store: store)
        let matter = try store.matters.createMatter(name: "Acme v. Roe", jurisdiction: "FL")
        let chat = try store.chats.createGlobalChat(title: "Notes")
        try store.matters.softDeleteMatter(id: matter.id)
        _ = try store.chats.softDeleteChat(id: chat.id)

        bin.reload()
        XCTAssertEqual(bin.matters.map(\.id), [matter.id])
        XCTAssertEqual(bin.chats.map(\.id), [chat.id])
        XCTAssertFalse(bin.isEmpty)

        bin.restoreMatter(id: matter.id)
        bin.restoreChat(id: chat.id)
        XCTAssertTrue(bin.isEmpty)
        XCTAssertEqual(try store.matters.fetchMatters().map(\.id), [matter.id])
        XCTAssertEqual(try store.chats.fetchGlobalChats().map(\.id), [chat.id])
    }

    func testPermanentlyDeleteMatterCascadesItsChatsAndMessages() throws {
        let store = try makeStore()
        let bin = RecycleBinController(store: store)
        let matter = try store.matters.createMatter(name: "Doomed", jurisdiction: "FL", defaultChatTitle: "Intake")
        let matterChat = try XCTUnwrap(try store.chats.fetchMatterChats(matterID: matter.id).first)
        _ = try store.chats.appendUserMessage(chatID: matterChat.id, content: "hello")
        XCTAssertFalse(try store.chats.fetchMessages(chatID: matterChat.id).isEmpty)

        try store.matters.softDeleteMatter(id: matter.id)
        bin.reload()
        XCTAssertEqual(bin.matters.map(\.id), [matter.id])

        bin.permanentlyDeleteMatter(id: matter.id)
        bin.reload()
        XCTAssertTrue(bin.matters.isEmpty)
        // Matter, its chat, and the chat's messages are all hard-deleted (FK cascade).
        XCTAssertTrue(try store.chats.fetchMessages(chatID: matterChat.id).isEmpty)
        XCTAssertTrue(try store.matters.fetchSoftDeletedMatters().isEmpty)
    }

    func testMentionsFederalCitationMatchesStatutesRegulationsAndReporters() {
        XCTAssertTrue(GlobalChatController.mentionsFederalCitation("see 18 u.s.c. § 1001"))
        XCTAssertTrue(GlobalChatController.mentionsFederalCitation("18 usc 1001"))
        XCTAssertTrue(GlobalChatController.mentionsFederalCitation("32 c.f.r. § 1100"))
        XCTAssertTrue(GlobalChatController.mentionsFederalCitation("123 f.3d 456"))
        XCTAssertTrue(GlobalChatController.mentionsFederalCitation("410 u.s. 113"))
        // Prose mentions without a citation shape must not trigger it.
        XCTAssertFalse(GlobalChatController.mentionsFederalCitation("the u.s. economy"))
        XCTAssertFalse(GlobalChatController.mentionsFederalCitation("what are the elements of negligence?"))
    }

    func testCitationLabelsExtractsDistinctMarkers() {
        let labels = GlobalChatController.citationLabels(in: "Per [A1] and [S2]; again [A1]. Not [B3] or [A].")
        XCTAssertEqual(labels, ["A1", "S2"])
    }

    /// `[A#]` markers present in the answer are persisted as clickable authority
    /// citations carrying the CourtListener URL.
    func testGlobalChatPersistsAuthorityCitations() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "The Ninth Circuit recognized the claim [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()
        controller.jurisdictionOverrideID = "federal-courts"

        await controller.performSend(
            prompt: "Did the Ninth Circuit recognize the claim?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        let citations = controller.messages.last?.citations ?? []
        XCTAssertEqual(citations.map(\.label), ["A1"])
        XCTAssertEqual(citations.first?.kind, .authority)
        XCTAssertNotNil(citations.first?.url)

        // The citation carries the in-app reader's pointer (spec §2.5): hydration key,
        // case header, and the snippet that anchors the passage highlight.
        let ref = try XCTUnwrap(citations.first?.authorityRef)
        XCTAssertEqual(ref.opinionID, "99")
        XCTAssertEqual(ref.citation, "1 F.4th 1")
        XCTAssertTrue(ref.court?.contains("Ninth Circuit") ?? false)
        XCTAssertTrue(citations.first?.matchText?.contains("A claim was recognized") ?? false)
    }

    private static let singleResultResponse = CourtListenerSearchResponse(
        count: 1,
        results: [
            CourtListenerSearchResultDTO(
                absoluteURL: "/opinion/1/foo-v-bar/",
                caseName: "Foo v. Bar",
                citation: ["1 F.4th 1"],
                clusterID: 1,
                court: "United States Court of Appeals for the Ninth Circuit",
                courtID: "ca9",
                dateFiled: "2024-02-03",
                opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A claim was recognized.")],
                status: "Published"
            )
        ]
    )

    func testConversationHistoryStripsReasoningDropsSystemAndOrdersChronologically() {
        let messages: [ChatMessage] = [
            ChatMessage(id: "1", role: .user, content: "First question", status: .completed),
            ChatMessage(id: "2", role: .assistant, content: "<think>pondering</think>The answer.", status: .completed),
            ChatMessage(id: "3", role: .system, content: "a system note", status: .completed),
            ChatMessage(id: "4", role: .user, content: "Second question", status: .completed)
        ]
        let history = GlobalChatController.conversationHistory(from: messages, budget: 16_000)

        XCTAssertEqual(history.map(\.role), [.user, .assistant, .user])  // system dropped
        XCTAssertEqual(history[0].content, "First question")
        XCTAssertFalse(history[1].content.contains("pondering"))        // chain-of-thought stripped
        XCTAssertTrue(history[1].content.contains("The answer."))
        XCTAssertEqual(history[2].content, "Second question")
    }

    func testConversationHistoryRespectsBudgetKeepingNewest() {
        let messages: [ChatMessage] = [
            ChatMessage(id: "1", role: .user, content: String(repeating: "a", count: 100), status: .completed),
            ChatMessage(id: "2", role: .user, content: String(repeating: "b", count: 100), status: .completed)
        ]
        let history = GlobalChatController.conversationHistory(from: messages, budget: 120)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.content.first, "b")  // the newest turn is the one kept
    }

    func testMatterLegalResearchPersistsSourcePacketAndVerifyUsesItWithoutModel() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let researchRoute = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let verifyRoute = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalVerify)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/1/foo-v-bar/",
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        clusterID: 1,
                        court: "California Court of Appeal",
                        courtID: "calctapp",
                        dateFiled: "2024-02-03",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")],
                        status: "Published"
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            // The planner query-generation runs first (no SOURCE PACKET); return no
            // parseable queries so retrieval falls back to the deterministic query.
            guard request.prompt.contains("SOURCE PACKET") else {
                return .events([
                    .event(request, 1, .token, token: "no queries"),
                    .event(request, 2, .generationCompleted)
                ])
            }
            return .events([
                .event(request, 1, .token, token: "Foo v. Bar, 123 Cal. App. 5th 456 held the term unenforceable."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        await controller.performSend(
            prompt: "Foo v. Bar, 123 Cal. App. 5th 456 held the term unenforceable.",
            modelID: nil,
            systemPrompt: verifyRoute.systemPrompt,
            options: verifyRoute.options,
            route: verifyRoute
        )

        let sessions = try store.research.fetchSessions(matterID: matter.id)
        XCTAssertEqual(sessions.count, 1)
        let queries = try store.research.fetchQueries(sessionID: sessions[0].id)
        XCTAssertEqual(try store.research.fetchResults(queryID: queries[0].id).count, 1)
        XCTAssertTrue(controller.messages.last?.content.contains("Verified against the latest source packet") ?? false)
        XCTAssertFalse(controller.messages.last?.content.contains("no_retrieved_authorities") ?? true)

        let audits = try store.auditEvents.fetchEvents(matterID: matter.id).filter { $0.eventType == "legal_model_route" }
        XCTAssertFalse(audits.isEmpty)
        let metadata = try XCTUnwrap(audits.last?.metadataJSON)
        XCTAssertTrue(metadata.contains("courtListenerQueryFingerprints"))
        XCTAssertFalse(metadata.contains("Research California contract unenforceability"))
    }

    func testEffectiveOptionsHonorsUIControlsWithoutLooseningLegalRoutes() {
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let research = router.route(for: .legalResearch)   // legal authority route, tuned temp 0.15
        let verify = router.route(for: .legalVerify)        // legal authority route, greedy temp 0
        let drafting = router.route(for: .drafting)         // non-legal route, temp 0.45
        var user = GenerationOptions(preset: .balanced, temperature: 0.8, maxOutputTokens: 1024)

        // Legal authority routes keep their tuned temperature (the user's looser global
        // default must not raise it), but the output budget is extend-only so the
        // general default (1024) can't truncate the route's tuned budget; thinking kept.
        let r = GlobalChatController.effectiveOptions(userOptions: user, route: research, fallback: GenerationOptions())
        XCTAssertEqual(r.temperature, research.options.temperature, accuracy: 0.0001)
        XCTAssertEqual(r.maxOutputTokens, research.options.maxOutputTokens)
        XCTAssertEqual(r.thinkingBudget, research.options.thinkingBudget)

        // Verify stays greedy.
        XCTAssertEqual(GlobalChatController.effectiveOptions(userOptions: user, route: verify, fallback: GenerationOptions()).temperature, 0.0, accuracy: 0.0001)

        // A non-legal route (drafting) honors the user's temperature.
        XCTAssertEqual(GlobalChatController.effectiveOptions(userOptions: user, route: drafting, fallback: GenerationOptions()).temperature, 0.8, accuracy: 0.0001)

        // Output budget is extend-only on a legal route.
        user.maxOutputTokens = 9000
        XCTAssertEqual(GlobalChatController.effectiveOptions(userOptions: user, route: research, fallback: GenerationOptions()).maxOutputTokens, 9000)

        // No route → the user's options pass straight through.
        XCTAssertEqual(GlobalChatController.effectiveOptions(userOptions: user, route: nil, fallback: GenerationOptions()).temperature, 0.8, accuracy: 0.0001)
    }

    func testLegalResearchHydratesTopAuthorityWithFullOpinionText() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let researchRoute = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let fullBody = "FULL OPINION BODY — the indemnification clause was held unenforceable as against public policy."
        let court = HydratingCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/1/foo-v-bar/",
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        clusterID: 1,
                        court: "California Court of Appeal",
                        courtID: "calctapp",
                        dateFiled: "2024-02-03",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "short search snippet")],
                        status: "Published"
                    )
                ]
            ),
            opinionBody: fullBody
        )
        final class PromptBox: @unchecked Sendable { var prompt = "" }
        let box = PromptBox()
        let stub = StubRuntimeClient { request in
            box.prompt = request.prompt
            return .events([
                .event(request, 1, .token, token: "The clause is unenforceable [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(), systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options, route: researchRoute
        )

        XCTAssertEqual(court.fetchedOpinionIDs, [99], "the top authority's opinion should be fetched")
        XCTAssertTrue(box.prompt.contains("FULL OPINION BODY"), "the packet should carry the hydrated full opinion text, not just the snippet")
    }

    func testLegalFollowUpCarriesPriorTurnsAsHistory() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let researchRoute = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/1/foo-v-bar/", caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"], clusterID: 1, court: "California Court of Appeal",
                        courtID: "calctapp", dateFiled: "2024-02-03",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "snippet")], status: "Published"
                    )
                ]
            )
        )
        final class HistoryBox: @unchecked Sendable { var histories: [[GenerateRequest.Turn]] = [] }
        let box = HistoryBox()
        let stub = StubRuntimeClient { request in
            box.histories.append(request.history)
            return .events([
                .event(request, 1, .token, token: "The clause is enforceable [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Is the indemnity clause enforceable?",
            modelID: ModelID(), systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options, route: researchRoute
        )
        await controller.performSend(
            prompt: "Now narrow that to the 9th Circuit.",
            modelID: ModelID(), systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options, route: researchRoute
        )

        // Each legal turn now runs a planner query-generation (no prior turns) plus the
        // answer generation; only the follow-up answer replays the prior user turn.
        let answersWithHistory = box.histories.filter { !$0.isEmpty }
        XCTAssertEqual(answersWithHistory.count, 1, "only the follow-up answer carries prior turns")
        XCTAssertTrue(
            answersWithHistory[0].contains { $0.role == .user && $0.content.contains("indemnity clause enforceable") },
            "the follow-up should replay the prior user turn so the model can resolve \"narrow that\""
        )
    }

    func testLegalAnswerSelfRepairsOnHardVerificationFailure() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let researchRoute = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/1/foo-v-bar/", caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"], clusterID: 1, court: "California Court of Appeal",
                        courtID: "calctapp", dateFiled: "2024-02-03",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "snippet")], status: "Published"
                    )
                ]
            )
        )
        final class CallBox: @unchecked Sendable { var n = 0 }
        let box = CallBox()
        let stub = StubRuntimeClient { request in
            box.n += 1
            // First answer fabricates an out-of-packet citation (hard fail); the
            // self-repair revision cites only the in-packet label [A1].
            let token = box.n == 1
                ? "The rule applies, see Made Up v. Fake, 999 U.S. 1."
                : "The rule applies [A1]."
            return .events([.event(request, 1, .token, token: token), .event(request, 2, .generationCompleted)])
        }
        let controller = makeGlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Is the rule applicable?",
            modelID: ModelID(), systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options, route: researchRoute
        )

        XCTAssertEqual(box.n, 2, "a hard verification failure should trigger exactly one self-repair pass")
        let answer = controller.messages.last?.content ?? ""
        XCTAssertFalse(answer.contains("UNVERIFIED DRAFT"), "the repaired, packet-cited answer should clear the quarantine banner")
        XCTAssertTrue(answer.contains("[A1]"))
    }

    func testMatterVerifyAfterReopenUsesChatBoundPacketNotNewestMatterResearchSession() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let researchRoute = router.route(for: .legalResearch)
        let verifyRoute = router.route(for: .legalVerify)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        clusterID: 1,
                        courtID: "calctapp",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")]
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Foo v. Bar, 123 Cal. App. 5th 456."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        let chatID = try XCTUnwrap(controller.selectedChatID)

        let unrelated = try store.research.createSession(
            matterID: matter.id,
            title: "Unrelated newer packet",
            issueText: "Different issue",
            jurisdiction: "California",
            status: .resultsReady
        )
        let unrelatedQuery = try store.research.createQuery(
            researchSessionID: unrelated.id,
            queryText: "different issue",
            queryIndex: 0,
            status: .completed
        )
        _ = try store.research.insertResult(
            ResearchResultRecord(
                researchQueryID: unrelatedQuery.id,
                clusterID: "999",
                opinionID: "1000",
                caseName: "Different v. Packet",
                citationJSON: #"["999 F.4th 1000"]"#,
                preferredCitation: "999 F.4th 1000",
                courtID: "ca9",
                snippet: "Different packet text."
            )
        )

        let reopened = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in
                XCTFail("Verify should not call the runtime.")
                return .events([])
            },
            scope: .matter(id: matter.id),
            courtListenerClient: StubCourtListenerClient()
        )
        reopened.loadChats()
        reopened.select(chatID: chatID)

        await reopened.performSend(
            prompt: "Foo v. Bar, 123 Cal. App. 5th 456 held the term unenforceable.",
            modelID: nil,
            systemPrompt: verifyRoute.systemPrompt,
            options: verifyRoute.options,
            route: verifyRoute
        )

        let output = try XCTUnwrap(reopened.messages.last?.content)
        XCTAssertTrue(output.contains("Verified against the latest source packet"))
        XCTAssertFalse(output.contains("unsupported_citation"), output)
        XCTAssertFalse(output.contains("No source packet is available"))
    }

    func testNoResultResearchBlocksFallbackToOlderSourcePacketAfterReopen() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let researchRoute = router.route(for: .legalResearch)
        let verifyRoute = router.route(for: .legalVerify)
        let court = SequencedCourtListenerClient(
            responses: [
                CourtListenerSearchResponse(
                    count: 1,
                    results: [
                        CourtListenerSearchResultDTO(
                            caseName: "Foo v. Bar",
                            citation: ["123 Cal. App. 5th 456"],
                            clusterID: 1,
                            courtID: "calctapp",
                            opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")]
                        )
                    ]
                ),
                CourtListenerSearchResponse(count: 0, results: [])
            ]
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Foo v. Bar, 123 Cal. App. 5th 456."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        await controller.performSend(
            prompt: "Research California issue with no available authority.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        let chatID = try XCTUnwrap(controller.selectedChatID)

        let reopened = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in
                XCTFail("Verify should not call the runtime.")
                return .events([])
            },
            scope: .matter(id: matter.id),
            courtListenerClient: StubCourtListenerClient()
        )
        reopened.loadChats()
        reopened.select(chatID: chatID)

        await reopened.performSend(
            prompt: "Foo v. Bar, 123 Cal. App. 5th 456 held the term unenforceable.",
            modelID: nil,
            systemPrompt: verifyRoute.systemPrompt,
            options: verifyRoute.options,
            route: verifyRoute
        )

        let output = try XCTUnwrap(reopened.messages.last?.content)
        XCTAssertTrue(output.contains("No source packet is available"), output)
        XCTAssertTrue(output.contains("no_retrieved_authorities"), output)
        XCTAssertFalse(output.contains("Verification passed"), output)
    }

    func testGlobalLegalResearchAuditRehydratesSourcePacketAfterReopen() async throws {
        let store = try makeStore()
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let researchRoute = router.route(for: .legalResearch)
        let verifyRoute = router.route(for: .legalVerify)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        clusterID: 1,
                        courtID: "calctapp",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")]
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Foo v. Bar, 123 Cal. App. 5th 456."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, courtListenerClient: court)
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        let chatID = try XCTUnwrap(controller.selectedChatID)

        let reopened = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in
                XCTFail("Verify should not call the runtime.")
                return .events([])
            },
            courtListenerClient: StubCourtListenerClient()
        )
        reopened.loadChats()
        reopened.select(chatID: chatID)

        await reopened.performSend(
            prompt: "Foo v. Bar, 123 Cal. App. 5th 456 held the term unenforceable.",
            modelID: nil,
            systemPrompt: verifyRoute.systemPrompt,
            options: verifyRoute.options,
            route: verifyRoute
        )

        let output = try XCTUnwrap(reopened.messages.last?.content)
        XCTAssertTrue(output.contains("Verified against the latest source packet"))
        XCTAssertFalse(output.contains("No source packet is available"))
        XCTAssertFalse(output.contains("no_retrieved_authorities"))

        let generations = try store.generation.fetchGenerationSessions(chatID: chatID)
        let researchGeneration = try XCTUnwrap(generations.last)
        let audits = try store.auditEvents.fetchEvents(
            relatedTable: "generation_sessions",
            relatedID: researchGeneration.id,
            eventType: "legal_model_route"
        )
        let metadata = try XCTUnwrap(audits.first?.metadataJSON)
        XCTAssertTrue(metadata.contains("Foo v. Bar"))
        XCTAssertFalse(metadata.contains("A contract term was unenforceable."))
    }

    func testStoredSourcePacketRehydratesRawCourtListenerTextAfterReopen() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let researchRoute = router.route(for: .legalResearch)
        let verifyRoute = router.route(for: .legalVerify)
        let sourceQuote = "the buyer may revoke acceptance after latent defects are discovered"
        let rawResultJSON = """
        {"absolute_url":"/opinion/12/full-text-v-case/","caseName":"Full Text v. Case","citation":["321 Cal. App. 5th 654"],"cluster_id":12,"court":"California Court of Appeal","court_id":"calctapp","dateFiled":"2023-01-02","opinions":[{"id":44,"snippet":"short snippet"}],"syllabus":"The court explained that \(sourceQuote)."}
        """
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/12/full-text-v-case/",
                        caseName: "Full Text v. Case",
                        citation: ["321 Cal. App. 5th 654"],
                        clusterID: 12,
                        courtID: "calctapp",
                        opinions: [CourtListenerOpinionDTO(id: 44, snippet: "short snippet")],
                        rawResultJSON: rawResultJSON
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Full Text v. Case, 321 Cal. App. 5th 654."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California buyer revocation authority.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        let chatID = try XCTUnwrap(controller.selectedChatID)

        let reopened = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in
                XCTFail("Verify should not call the runtime.")
                return .events([])
            },
            scope: .matter(id: matter.id),
            courtListenerClient: StubCourtListenerClient()
        )
        reopened.loadChats()
        reopened.select(chatID: chatID)

        await reopened.performSend(
            prompt: #"Full Text v. Case says "\#(sourceQuote)." 321 Cal. App. 5th 654."#,
            modelID: nil,
            systemPrompt: verifyRoute.systemPrompt,
            options: verifyRoute.options,
            route: verifyRoute
        )

        let output = try XCTUnwrap(reopened.messages.last?.content)
        XCTAssertTrue(output.contains("Verification passed"), output)
        XCTAssertFalse(output.contains("unsupported_quote"), output)
    }

    func testAutomaticAdverseResultsRemainUnreviewed() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        caseName: "Roe v. Doe",
                        citation: ["1 Cal. App. 5th 2"],
                        courtID: "calctapp",
                        opinions: [CourtListenerOpinionDTO(id: 7, snippet: "Adverse authority snippet.")]
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Roe v. Doe, 1 Cal. App. 5th 2."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Find adverse California authority on contract defenses.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        let session = try XCTUnwrap(try store.research.fetchSessions(matterID: matter.id).first)
        let queries = try store.research.fetchQueries(sessionID: session.id)
        XCTAssertEqual(queries.count, 2)
        let reviewStates = try queries.flatMap { query in
            try store.research.fetchResults(queryID: query.id).map(\.reviewState)
        }
        XCTAssertEqual(reviewStates, [
            ResearchResultReviewState.unreviewed.rawValue,
            ResearchResultReviewState.unreviewed.rawValue
        ])
    }

    func testLegalResearchUsesCourtAndDateFilters() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let court = CapturingCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        caseName: "Roe v. Doe",
                        citation: ["1 F.4th 1"],
                        courtID: "ca9",
                        opinions: [CourtListenerOpinionDTO(id: 7, snippet: "snippet")]
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: "Roe v. Doe, 1 F.4th 1."), .event(request, 2, .generationCompleted)])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Find binding 9th Cir. and N.D. Cal. authority after 2020 on employee non-compete agreements.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        let request = try XCTUnwrap(court.requests.first)
        XCTAssertTrue(request.courtIDs.contains("ca9"))
        XCTAssertTrue(request.courtIDs.contains("cand"))
        XCTAssertEqual(request.dateFiledAfter, "2020-01-01")
        XCTAssertFalse(request.query.localizedCaseInsensitiveContains("after 2020"))
        XCTAssertNotNil(court.relatedSessionIDs.first ?? nil)
    }

    func testCritiqueUsesPriorAssistantDraftAndLatestSourcePacket() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "California")
        let router = ModelRouter(configuration: LegalModelConfiguration())
        let researchRoute = router.route(for: .legalResearch)
        let critiqueRoute = router.route(for: .legalCritique)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        courtID: "calctapp",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")]
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            if request.prompt.contains("DRAFT TO CRITIQUE") {
                XCTAssertTrue(request.prompt.contains("Foo v. Bar"))
                XCTAssertTrue(request.prompt.contains("123 Cal. App. 5th 456"))
                return .events([.event(request, 1, .token, token: "Critique complete."), .event(request, 2, .generationCompleted)])
            }
            return .events([
                .event(request, 1, .token, token: "Foo v. Bar, 123 Cal. App. 5th 456 supports the draft."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: researchRoute.systemPrompt,
            options: researchRoute.options,
            route: researchRoute
        )
        await controller.performSend(
            prompt: "",
            modelID: ModelID(),
            systemPrompt: critiqueRoute.systemPrompt,
            options: critiqueRoute.options,
            route: critiqueRoute,
            displayPrompt: "/critique"
        )

        XCTAssertEqual(controller.messages.last?.content, "Critique complete.")
    }

    func testLegalResearchAppendsVerificationWarningsForInventedCitation() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let court = StubCourtListenerClient(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: "/opinion/1/foo-v-bar/",
                        caseName: "Foo v. Bar",
                        citation: ["123 Cal. App. 5th 456"],
                        clusterID: 1,
                        court: "California Court of Appeal",
                        courtID: "calctapp",
                        dateFiled: "2024-02-03",
                        opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A contract term was unenforceable.")],
                        status: "Published"
                    )
                ]
            )
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "California law requires this result. Fake v. Madeup, 999 F.3d 1234."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research California contract unenforceability.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertTrue(controller.messages.last?.content.contains("Verification warnings") ?? false)
        XCTAssertTrue(controller.messages.last?.content.contains("unsupported_citation") ?? false)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    /// A statutory question must be grounded in the injected (offline) statutory
    /// source: the canned provision enters the SOURCE PACKET as citable [A1]
    /// authority and the answer completes without any live statutory provider.
    func testStatutoryQuestionGroundsInStubProvisionOffline() async throws {
        let store = try makeStore()
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let provision = StatutoryProvision(
            sourceID: "stub-statutes",
            sourceName: "Stub Statutes",
            weightTier: .currencyVerifiable,
            jurisdictionID: "fl-statutes",
            jurisdictionName: "Florida Statutes",
            citation: "§ 672.201",
            heading: "Formal requirements; statute of frauds",
            text: "A contract for the sale of goods for the price of $500 or more is not enforceable unless there is some writing sufficient to indicate that a contract for sale has been made.",
            url: "https://example.test/fl/672.201",
            effectiveDate: "2024-01-01"
        )
        final class PromptBox: @unchecked Sendable { var prompt = "" }
        let box = PromptBox()
        let stub = StubRuntimeClient { request in
            box.prompt = request.prompt
            return .events([
                .event(request, 1, .token, token: "A writing is required for a $600 sale of goods [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: stub,
            statutoryOrchestrator: StatutorySourceOrchestrator(
                sources: [StubStatutorySource(result: StatutoryLookupResult(provisions: [provision]))]
            )
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Under the Florida statute of frauds, is a $600 oral contract for the sale of goods enforceable?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertTrue(box.prompt.contains("SOURCE PACKET"))
        XCTAssertTrue(box.prompt.contains("§ 672.201"), "the canned provision must enter the packet")
        XCTAssertEqual(controller.messages.last?.status, .completed)
        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("[A1]"), answer)
        XCTAssertFalse(answer.contains("UNVERIFIED DRAFT"), answer)
    }

    // MARK: - MattersController

    func testMattersControllerCreatesMatterWithScopedChats() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient { request in .events([.event(request, 1, .generationCompleted)]) }
        let controller = MattersController(store: store, runtimeClient: stub)
        controller.loadMatters()
        XCTAssertTrue(controller.matters.isEmpty)

        let matter = try controller.createMatter(name: "McKernon Motors v. Liberty Rail")
        XCTAssertEqual(controller.matters.count, 1)
        XCTAssertEqual(controller.selectedMatterID, matter.id)

        // Creating a matter also creates a default matter chat and a
        // matter_created audit event (WO 23 / spec §8.3).
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).count, 1)
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).first?.title, "General — McKernon Motors v. Liberty Rail")
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
            MatterDraft(name: "Hessington Oil v. Gillis Industries", jurisdiction: "California", partyPerspective: .plaintiff)
        )
        XCTAssertEqual(controller.selectedMatter?.jurisdiction, "California")
        XCTAssertEqual(controller.selectedMatter?.partyPerspective, .plaintiff)

        var draft = try XCTUnwrap(controller.draft(forMatter: matter.id))
        draft.partyPerspective = .defendant
        draft.court = "N.D. Cal."
        draft.clientNames = #"Doe & Sons, LLC / María-José"#
        draft.matterDescription = #"Contract dispute involving § 2.4(a), "special" escrow terms, and ACME#42."#
        draft.internalMatterID = #"INT-2026/CA#001&A"#
        try controller.updateMatter(id: matter.id, draft: draft)
        XCTAssertEqual(controller.selectedMatter?.partyPerspective, .defendant)
        XCTAssertEqual(controller.draft(forMatter: matter.id)?.court, "N.D. Cal.")
        XCTAssertEqual(controller.selectedMatter?.clientNames, #"Doe & Sons, LLC / María-José"#)
        XCTAssertEqual(controller.draft(forMatter: matter.id)?.matterDescription, #"Contract dispute involving § 2.4(a), "special" escrow terms, and ACME#42."#)
        XCTAssertEqual(controller.draft(forMatter: matter.id)?.internalMatterID, #"INT-2026/CA#001&A"#)

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

    func testResearchPlannerForcesThinkingOffOnLegalResearchRoute() async throws {
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
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let stub = StubRuntimeClient { request in
            // Query planning inherits the legalResearch context/model but must NOT inherit
            // its `.high` thinking budget — that crowded out the `## Query N` output and
            // produced "no recommended queries". Thinking is forced off and output capped.
            XCTAssertEqual(request.options.preset, .legalResearch)
            XCTAssertEqual(request.options.thinkingBudget, .off)
            XCTAssertLessThanOrEqual(request.options.maxOutputTokens, 1024)
            XCTAssertEqual(request.options.maxContextTokens, route.options.maxContextTokens)
            XCTAssertNil(request.systemPrompt)
            return .events([
                .event(request, 1, .token, token: markdown),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = ResearchSessionController(store: store, runtimeClient: stub, matterID: matter.id)

        let draft = ResearchPlanDraft(title: "Plan A", issueText: "Issue", jurisdiction: "California", partyPerspective: "plaintiff")
        await controller.generatePlan(draft: draft, modelID: ModelID(), route: route)

        XCTAssertEqual(controller.plannedQueries.count, 5)
        XCTAssertEqual(controller.planState, .ready)
    }

    func testResearchPlannerPromptIncludesStructuredJurisdictionContext() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "Florida", partyPerspective: .plaintiff)
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let scope = try XCTUnwrap(
            JurisdictionCatalog.shared.authorityScope(
                jurisdiction: "Florida",
                court: "Circuit Court of the Fourth Judicial Circuit in and for Duval County"
            )
        )
        let stub = StubRuntimeClient { request in
            XCTAssertTrue(request.prompt.contains("Structured jurisdiction scope"))
            XCTAssertTrue(request.prompt.contains("Fifth District Court of Appeal of Florida"))
            XCTAssertTrue(request.prompt.contains("Supreme Court of Florida"))
            return .events([
                .event(request, 1, .token, token: """
                ## Query 1
                premises liability notice
                ## Query 2
                negligent security duty
                ## Query 3
                open and obvious condition
                ## Query 4
                comparative fault
                ## Query 5
                summary judgment premises liability
                """),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = ResearchSessionController(store: store, runtimeClient: stub, matterID: matter.id)
        let draft = ResearchPlanDraft(
            title: "Plan A",
            issueText: "Issue",
            jurisdiction: "Florida",
            partyPerspective: "plaintiff",
            preferredCourts: scope.preferredCourtNames,
            jurisdictionContext: scope.modelContext,
            courtFilterIDs: scope.courtListenerIDs
        )

        await controller.generatePlan(draft: draft, modelID: ModelID(), route: route)

        XCTAssertEqual(controller.plannedQueries.count, 5)
        controller.setApproved(true, for: controller.plannedQueries[0].id)
        let sessionID = try controller.savePlan(draft: draft)
        let query = try XCTUnwrap(try store.research.fetchQueries(sessionID: sessionID).first)
        XCTAssertEqual(query.courtFilter, "fla,fladistctapp,scotus")
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
            caseName: "Specter v. Hardman", citation: ["1 U.S. 1"], court: "SCOTUS",
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
        XCTAssertEqual(controller.resultsByQuery[q1.id]?.first?.caseName, "Specter v. Hardman")
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

    func testRunPopulatesTokenlessQueryMetadata() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Roe", rawResultJSON: "{}")
        let controller = makeRunController(
            store: store, matterID: matter.id,
            client: StubCourtListenerClient(response: .init(count: 3, next: "https://www.courtlistener.com/x", previous: nil, results: [dto]))
        )
        controller.openSession(sessionID)
        await controller.runApprovedSearches()

        let query = try XCTUnwrap(store.research.fetchQueries(sessionID: sessionID).first)
        let requestMeta = try XCTUnwrap(query.requestMetadataJSON)
        XCTAssertTrue(requestMeta.contains("\"type\":\"o\""))
        XCTAssertFalse(requestMeta.lowercased().contains("authorization"), "metadata must be tokenless")
        XCTAssertFalse(requestMeta.lowercased().contains("token"))
        XCTAssertTrue(try XCTUnwrap(query.responseMetadataJSON).contains("\"count\":\"3\""))
    }

    func testRunApprovedSearchesAppliesSavedCourtAndDateFilters() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "Florida")
        let session = try store.research.createSession(
            matterID: matter.id,
            title: "S",
            issueText: "I",
            jurisdiction: "Florida",
            preferredCourts: ["Supreme Court of Florida"],
            status: .approved
        )
        let after = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2020, month: 1, day: 1)))
        let before = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: 12, day: 31)))
        _ = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "premises liability notice",
            queryIndex: 0,
            courtFilter: "fla,fladistctapp,scotus",
            dateFiledAfter: after,
            dateFiledBefore: before,
            status: .approved
        )
        let client = CapturingCourtListenerClient(
            response: CourtListenerSearchResponse(count: 0, next: nil, previous: nil, results: [])
        )
        let controller = ResearchSessionController(
            store: store,
            runtimeClient: StubRuntimeClient { _ in .events([]) },
            matterID: matter.id,
            tokenStore: StubTokenStore(),
            courtListenerClient: client
        )

        controller.openSession(session.id)
        await controller.runApprovedSearches()

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.courtIDs, ["fla", "fladistctapp", "scotus"])
        XCTAssertEqual(request.dateFiledAfter, "2020-01-01")
        XCTAssertEqual(request.dateFiledBefore, "2024-12-31")
        let storedQuery = try XCTUnwrap(try store.research.fetchQueries(sessionID: session.id).first)
        let metadata = try XCTUnwrap(storedQuery.requestMetadataJSON)
        XCTAssertTrue(metadata.contains("\"court\":\"fla,fladistctapp,scotus\""))
        XCTAssertTrue(metadata.contains("\"filed_after\":\"2020-01-01\""))
    }

    func testRunSurfacesSpecificErrorAndRecordsNetworkDiagnostic() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let controller = makeRunController(
            store: store, matterID: matter.id,
            client: StubCourtListenerClient(failure: .localRateLimitExceeded)
        )
        controller.openSession(sessionID)
        await controller.runApprovedSearches()

        XCTAssertEqual(controller.runMessage, CourtListenerError.localRateLimitExceeded.localizedDescription)
        let diagnostics = try store.diagnostics.fetchRecentDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.category == "network" && $0.severity == "warning" })
    }

    // MARK: - Result review (WO 26)

    func testReviewActionsCreateAuthoritiesAndGateCompletion() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Specter v. Hardman", citation: ["1 U.S. 1"], rawResultJSON: "{}")
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

    func testDeleteAuthorityRemovesItAndReSaveRevivesIt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Specter v. Hardman", citation: ["1 U.S. 1"], rawResultJSON: "{}")
        let client = StubCourtListenerClient(response: .init(count: 1, next: nil, previous: nil, results: [dto]))
        let runController = makeRunController(store: store, matterID: matter.id, client: client)
        runController.openSession(sessionID)
        await runController.runApprovedSearches()
        let results = runController.resultsByQuery.values.flatMap { $0 }
        let resultID = results[0].id
        runController.reviewResult(resultID, as: .saveAsAuthority)

        let authorities = AuthoritiesController(store: store, matterID: matter.id)
        authorities.load()
        let authorityID = try XCTUnwrap(authorities.authorities.first?.id)
        XCTAssertEqual(authorities.authorities.count, 1)

        authorities.deleteAuthority(id: authorityID)
        XCTAssertTrue(authorities.authorities.isEmpty)
        XCTAssertTrue(try store.authorities.fetchAuthorities(matterID: matter.id).isEmpty)
        XCTAssertTrue(
            try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "authority_soft_deleted" }
        )

        // Re-saving the same result revives the soft-deleted authority (the unique
        // (matter, research_result) slot is reused, not duplicated).
        runController.reviewResult(resultID, as: .saveAsAuthority)
        authorities.load()
        XCTAssertEqual(authorities.authorities.count, 1)
        XCTAssertEqual(authorities.authorities.first?.id, authorityID)
    }

    func testSkipDoesNotCreateAuthority() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Specter v. Hardman", rawResultJSON: "{}")
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

    // MARK: - Local-first research (tiered retrieval spec §4)

    func testLocalFirstResearchAnswersFromSavedAuthoritiesAndOffersNetwork() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Smith v. Jones"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Smith v. Jones",
            citationJSON: #"["100 So. 3d 200"]"#,
            court: "Florida Supreme Court", courtID: "fla",
            opinionText: "A liquidated damages clause is enforceable in Florida unless it operates as a penalty."
        ))

        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        final class PromptBox: @unchecked Sendable { var prompt = "" }
        let box = PromptBox()
        let runtime = StubRuntimeClient { request in
            if request.prompt.contains("SOURCE PACKET") { box.prompt = request.prompt }
            return .events([
                .event(request, 1, .token, token: "Liquidated damages are enforceable unless a penalty [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        // The offline CourtListener client returns nothing — a grounded [A1] answer
        // proves the packet came from the saved library, with no network search.
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id))
        controller.loadChats()

        await controller.performSend(
            prompt: "Are liquidated damages clauses enforceable in Florida?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )

        XCTAssertTrue(box.prompt.contains("Smith v. Jones"), "the saved authority grounds the packet")
        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("Preliminary — answered from this matter's saved authorities"), answer)
        XCTAssertEqual(controller.deeperSearchOffer?.kind, .research)

        // The deeper tier skips the local pass and searches CourtListener (which is
        // empty here), and the offer is retired by the new send.
        await controller.performSend(
            prompt: "Are liquidated damages clauses enforceable in Florida?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route,
            researchDepth: .deep
        )
        let deepAnswer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertFalse(deepAnswer.contains("Preliminary — answered from this matter's saved authorities"), deepAnswer)
        XCTAssertNil(controller.deeperSearchOffer)
    }

    func testHoldingQuestionAboutSavedSupremeCourtCaseIsNotJurisdictionBlocked() async throws {
        // Regression: "What is the holding of Rush v. Savchuk?" in a Florida matter
        // was quarantined as a jurisdiction mismatch — SCOTUS binds everywhere, and a
        // question that names its case is about that case wherever it sits.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Adams", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Rush v. Savchuk"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Rush v. Savchuk",
            citationJSON: #"["444 U.S. 320"]"#,
            preferredCitation: "444 U.S. 320",
            court: "Supreme Court of the United States", courtID: "scotus",
            opinionText: "The Court held that a defendant's insurer's obligation to defend and indemnify is not a contact of the defendant for quasi in rem jurisdiction purposes."
        ))

        let route = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true)).route(for: .legalResearch)
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Rush v. Savchuk held that quasi in rem jurisdiction cannot rest on the defendant's insurer's obligation [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id))
        controller.loadChats()

        await controller.performSend(
            prompt: "What is the holding of Rush v. Savchuk?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertFalse(answer.contains("I cannot provide a source-grounded legal answer"), answer)
        XCTAssertFalse(answer.contains("jurisdiction_mismatch"), answer)
        XCTAssertTrue(answer.contains("quasi in rem"), answer)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testLocalFirstSkippedWhenSavedAuthoritiesHaveNoText() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Smith v. Jones"))
        // Saved but metadata-only (no persisted opinion text) — too thin to ground a
        // local answer (spec §4.4), so research falls through to the network.
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Smith v. Jones"
        ))
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id))
        controller.loadChats()

        await controller.performSend(
            prompt: "Are liquidated damages clauses enforceable in Florida?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )
        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertFalse(answer.contains("answered from this matter's saved authorities"), answer)
        XCTAssertNil(controller.deeperSearchOffer)
    }

    func testNamedCaseSavedWithoutTextGoesToNetworkNotLocalTier() async throws {
        // Regression: a saved-but-TEXTLESS named case passed the holds-the-cite
        // gate, then the grounded filter silently dropped it — the local tier
        // answered "from the library" without the very case the user asked about.
        // The library also holds another case WITH text, which used to make the
        // local tier look viable.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Adams", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let peacock = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Peacock v. Thomas"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: peacock.id,
            caseName: "Peacock v. Thomas",
            citationJSON: #"["516 U.S. 349"]"#,
            preferredCitation: "516 U.S. 349",
            court: "Supreme Court of the United States", courtID: "scotus"
            // No opinionText — metadata-only save.
        ))
        let other = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "MacKey v. Lanier Collection Agency"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: other.id,
            caseName: "MacKey v. Lanier Collection Agency & Service, Inc.",
            citationJSON: #"["486 U.S. 825"]"#,
            court: "Supreme Court of the United States", courtID: "scotus",
            opinionText: "ERISA does not bar garnishment of welfare benefit plans."
        ))

        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Answer."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), courtListenerClient: court)
        controller.loadChats()

        await controller.performSend(
            prompt: "What is the holding of Peacock v. Thomas?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )

        // The send must fall through to the network (which retrieves + hydrates
        // the named case) instead of answering locally without it.
        XCTAssertFalse(court.requests.isEmpty, "expected a network search, got a local-tier answer")
        // And the citation-first request must target the named case, unbounded.
        let named = try XCTUnwrap(court.requests.first { $0.caseName?.contains("Peacock") == true })
        XCTAssertTrue(named.courtIDs.isEmpty)
        XCTAssertNil(named.dateFiledAfter)
        XCTAssertNil(named.dateFiledBefore)
    }

    func testNamedCaseHeldWithTextStillAnswersLocally() async throws {
        // The complement: when the named case IS saved with opinion text, the
        // local tier answers with no network call, and short-name matching finds
        // the full stored caption.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Adams", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Sniadach"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Sniadach v. Family Finance Corp. of Bay View",
            citationJSON: #"["395 U.S. 337"]"#,
            court: "Supreme Court of the United States", courtID: "scotus",
            opinionText: "Prejudgment wage garnishment without notice and a prior hearing violates procedural due process."
        ))
        let court = CapturingCourtListenerClient(response: Self.singleResultResponse)
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Sniadach held prejudgment garnishment without a hearing unconstitutional [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), courtListenerClient: court)
        controller.loadChats()

        await controller.performSend(
            prompt: "What is the holding of Sniadach v. Family Finance?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )

        XCTAssertTrue(court.requests.isEmpty, "local-first answer must not touch the network")
        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("Sniadach"), answer)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testDeepTierFallsBackToSavedAuthoritiesWhenNetworkFails() async throws {
        // Deep tier skips the local library by design — but when CourtListener is
        // down or rate-limited, a grounded local answer beats a dead send.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Adams", jurisdiction: "Florida")
        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Rush v. Savchuk"))
        _ = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id,
            caseName: "Rush v. Savchuk",
            citationJSON: #"["444 U.S. 320"]"#,
            court: "Supreme Court of the United States", courtID: "scotus",
            opinionText: "Quasi in rem jurisdiction cannot rest on the presence of the defendant's insurer."
        ))
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 1, .token, token: "Rush v. Savchuk rejected insurer-based quasi in rem jurisdiction [A1]."),
                .event(request, 2, .generationCompleted)
            ])
        }
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id),
            courtListenerClient: StubCourtListenerClient(shouldFail: true)
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What is the holding of Rush v. Savchuk?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route,
            researchDepth: .deep
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertEqual(controller.messages.last?.status, .completed, answer)
        XCTAssertTrue(answer.contains("quasi in rem"), answer)
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

    func testReReviewDoesNotIllegallyDowngradeVerifiedAuthority() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let sessionID = try seedApprovedSession(store, matterID: matter.id)
        let dto = CourtListenerSearchResultDTO(caseName: "Roe", rawResultJSON: "{}")
        let client = StubCourtListenerClient(response: .init(count: 1, next: nil, previous: nil, results: [dto]))
        let controller = makeRunController(store: store, matterID: matter.id, client: client)
        controller.openSession(sessionID)
        await controller.runApprovedSearches()

        let resultID = controller.resultsByQuery.values.flatMap { $0 }[0].id
        controller.reviewResult(resultID, as: .saveAsAuthority)
        let authority = try XCTUnwrap(store.authorities.fetchAuthority(researchResultID: resultID))
        // The user verifies it in the Authorities tab (a legal transition).
        try store.authorities.updateUseStatus(authorityID: authority.id, useStatus: .userMarkedVerified)

        // Re-reviewing as Needs Later Review would set unverified — an illegal
        // §11.4 transition that must NOT silently downgrade the verified status.
        controller.reviewResult(resultID, as: .needsLaterReview)
        let after = try XCTUnwrap(store.authorities.fetchAuthority(researchResultID: resultID))
        XCTAssertEqual(after.useStatus, AuthorityUseStatus.userMarkedVerified.rawValue)
        XCTAssertEqual(after.reviewState, ResearchResultReviewState.needsLaterReview.rawValue, "review classification still updates")
    }

    // MARK: - Structured outputs (WO 28)

    func testCreateOutputCompleteWhenAllSectionsPresent() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // draftingSkeleton is structurally validated but does not assert legal
        // authority, so a section-complete, citation-free output reaches `.complete`.
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let markdown = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        let ok = await controller.createOutput(type: .draftingSkeleton, context: "issue + authorities", modelID: ModelID())
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.outputs.count, 1)
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(controller.outputs[0].missingCount, 0)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "structured_output_created" })
    }

    func testCreateOutputWithUngroundedCitationIsForcedToNeedsReviewWithBanner() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)!
        // All required sections present (would otherwise be `.complete`), but the
        // body contains a legal citation this path never retrieved or verified.
        let markdown = contract.requiredHeadings.joined(separator: "\n\nThe rule derives from Brown v. Board, 347 U.S. 483.\n\n")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        let ok = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: ModelID())
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.needsReview.rawValue, "an ungrounded legal citation must force review, never complete")
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).first)
        XCTAssertTrue(version.contentMarkdown.contains("UNVERIFIED CITATIONS"), "must carry the unverified-citations banner")
    }

    func testAuthorityAssertingOutputAlwaysFlaggedEvenWithNoRecognizedCitation() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // ruleSynthesis asserts authority. All sections present, but the body uses
        // prose authority references with NO recognized citation format — it must
        // still be flagged so an unrecognized/fabricated authority can't read as
        // a finished, verified output.
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)!
        let markdown = contract.requiredHeadings.joined(separator: "\n\nThe controlling authority establishes the rule.\n\n")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)
        let ok = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: ModelID())
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.needsReview.rawValue)
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).first)
        XCTAssertTrue(version.contentMarkdown.contains("UNVERIFIED CITATIONS"))
    }

    func testNonAuthorityScaffoldWithoutCitationStaysComplete() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // draftingSkeleton does not assert authority; with all sections and no
        // citation it should remain complete (no spurious banner).
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let markdown = contract.requiredHeadings.joined(separator: "\n\nplaceholder body text\n\n")
        let stub = StubRuntimeClient { request in
            .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)
        _ = await controller.createOutput(type: .draftingSkeleton, context: "x", modelID: ModelID())
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue)
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

    func testCreateOutputAutoRepairsMissingSections() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // draftingSkeleton asserts no authority, so status is driven purely by sections.
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let complete = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let incomplete = "\(contract.requiredHeadings.first!)\n\nonly the first section"
        final class CallBox: @unchecked Sendable { var n = 0 }
        let box = CallBox()
        let stub = StubRuntimeClient { request in
            box.n += 1
            let markdown = box.n == 1 ? incomplete : complete   // first generation incomplete; repair completes it
            return .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        let ok = await controller.createOutput(type: .draftingSkeleton, context: "x", modelID: ModelID())
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue, "auto-repair should fill in the missing sections")
        XCTAssertEqual(controller.outputs[0].missingCount, 0)
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).count, 2, "initial + one repair version")
    }

    func testRepairKeepsCitationBannerEvenWhenRepairEvadesRegex() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)! // non-authority
        // v1: missing the last heading, plus a detected reporter citation → flagged.
        let partial = contract.requiredHeadings.dropLast().joined(separator: "\n\nThe rule is from Brown v. Board, 347 U.S. 483.\n\n")
        // repair: all headings, but the citation is restated WITHOUT a reporter format.
        let full = contract.requiredHeadings.joined(separator: "\n\nThe rule follows the Brown decision.\n\n")
        let stub = StubRuntimeClient { request in
            let token = request.prompt.contains("repairing the structure") ? full : partial
            return .events([.event(request, 1, .token, token: token), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        _ = await controller.createOutput(type: .draftingSkeleton, context: "x", modelID: ModelID())
        // Auto-repair fills the heading, but the once-raised citation banner must persist.
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.needsReview.rawValue)
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        let active = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).max(by: { $0.versionIndex < $1.versionIndex })
        )
        XCTAssertTrue(active.contentMarkdown.contains("UNVERIFIED CITATIONS"), "the citation banner must not be silently cleared by a repair pass")
    }

    func testManualRepairDiscardsWorseResultAndKeepsPriorVersion() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let full = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let worse = contract.requiredHeadings.dropLast(2).joined(separator: "\n\nbody\n\n")
        final class CallBox: @unchecked Sendable { var n = 0 }
        let box = CallBox()
        let stub = StubRuntimeClient { request in
            box.n += 1
            let token = box.n == 1 ? full : worse // initial complete; manual repair regresses
            return .events([.event(request, 1, .token, token: token), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        _ = await controller.createOutput(type: .draftingSkeleton, context: "x", modelID: ModelID())
        let outputID = controller.outputs[0].id
        let beforeCount = try store.structuredOutputs.fetchVersions(structuredOutputID: outputID).count

        let ran = await controller.repairOutput(outputID, modelID: ModelID())
        XCTAssertTrue(ran, "the repair ran")
        XCTAssertEqual(
            try store.structuredOutputs.fetchVersions(structuredOutputID: outputID).count, beforeCount,
            "a worse repair must not replace the active version"
        )
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue, "the prior complete version/status is preserved")
    }

    func testStructuredOutputUsesTaskRouteOptionsAndSystemPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let markdown = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let stub = StubRuntimeClient { request in
            XCTAssertEqual(request.options.preset, .drafting)
            XCTAssertTrue(request.systemPrompt?.contains("legal drafting assistant") ?? false)
            return .events([.event(request, 1, .token, token: markdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        let ok = await controller.createOutput(type: .draftingSkeleton, context: "draft facts", modelID: ModelID())

        XCTAssertTrue(ok)
    }

    func testCreateOutputWithoutModelDoesNothing() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let stub = StubRuntimeClient { _ in .events([]) }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)
        let ok = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(controller.outputs.isEmpty)
        XCTAssertEqual(controller.message, "Assign a High-quality legal reasoning model in the Models tab to generate Rule Synthesis.")
    }

    // MARK: - Structure repair (WO 29)

    func testRepairCreatesNewVersionPreservingOriginalAndCompletes() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // draftingSkeleton (non-authority-asserting) so a section-complete repair
        // can reach `.complete`, isolating this test to the repair/version flow.
        let contract = StructuredOutputContracts.contract(for: .draftingSkeleton)!
        let fullMarkdown = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let partialMarkdown = "\(contract.requiredHeadings[0])\n\(contract.requiredHeadings[1])\npartial"
        // Create returns an incomplete doc; repair (detected by prompt text) returns the full one.
        let stub = StubRuntimeClient { request in
            let token = request.prompt.contains("repairing the structure") ? fullMarkdown : partialMarkdown
            return .events([.event(request, 1, .token, token: token), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)

        // createOutput now auto-repairs in-line: the partial generation becomes
        // version 1, and the repair pass completes it as version 2.
        _ = await controller.createOutput(type: .draftingSkeleton, context: "x", modelID: ModelID())
        let outputID = controller.outputs[0].id
        XCTAssertEqual(controller.outputs[0].status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(controller.outputs[0].missingCount, 0)

        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: outputID)
            .sorted { $0.versionIndex < $1.versionIndex }
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].contentMarkdown, partialMarkdown, "original version preserved")
        XCTAssertEqual(versions[1].versionIndex, 2)
        XCTAssertEqual(versions[1].parentVersionID, versions[0].id)
        XCTAssertEqual(versions[1].repairReason, "missing_required_sections")
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "structured_output_repaired" })
    }

    func testStructureRepairUsesCritiqueRouteOptionsAndSystemPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)!
        let fullMarkdown = contract.requiredHeadings.joined(separator: "\n\nbody\n\n")
        let partialMarkdown = "# Rule Synthesis\n## Rule Statement\npartial"
        let stub = StubRuntimeClient { request in
            if request.prompt.contains("repairing the structure") {
                XCTAssertEqual(request.options.preset, .legalCritique)
                XCTAssertTrue(request.systemPrompt?.contains("reviewing legal work product") ?? false)
                return .events([.event(request, 1, .token, token: fullMarkdown), .event(request, 2, .generationCompleted)])
            }
            return .events([.event(request, 1, .token, token: partialMarkdown), .event(request, 2, .generationCompleted)])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: stub, matterID: matter.id)
        _ = await controller.createOutput(type: .ruleSynthesis, context: "x", modelID: ModelID())
        let outputID = controller.outputs[0].id

        let repaired = await controller.repairOutput(outputID, modelID: ModelID())

        XCTAssertTrue(repaired)
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

    func testDeleteModelUnregistersClearsRoleAssignmentAndUnloads() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient(
            loadResult: LoadModelResponse(status: .loaded, modelID: ModelID())
        ))
        let model = try library.addModel(displayName: "Local 32B", path: "/tmp/delete-model", bookmarkData: nil)
        library.assignModel(model.id, to: .legalReasoning)
        await library.activateAndLoad(modelID: model.id)
        XCTAssertNotNil(library.loadedModelID)

        let result = await library.deleteModel(modelID: model.id)

        XCTAssertEqual(result, .deleted)
        XCTAssertTrue(library.models.isEmpty)
        XCTAssertNil(try store.models.fetchModel(id: model.id))
        XCTAssertNil(library.roleAssignments.modelID(for: .legalReasoning))
        XCTAssertEqual(library.loadState, .idle, "deleting the loaded model unloads it")
    }

    func testIsManagedDownloadDistinguishesManagedFromUserFolder() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let managedPath = ManagedModelStorage.modelsDirectory().appendingPathComponent("org__model").path
        let managed = try library.addModel(displayName: "Downloaded", path: managedPath, bookmarkData: nil)
        let userFolder = try library.addModel(displayName: "User", path: "/Users/x/Models/m", bookmarkData: Data([1]))
        XCTAssertTrue(library.isManagedDownload(managed))
        XCTAssertFalse(library.isManagedDownload(userFolder))
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

    func testRouteAssignmentLoadsAssignedModelInsteadOfActiveFallback() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let startup = try library.addModel(displayName: "Generic Startup", path: "/tmp/startup", bookmarkData: nil)
        let drafter = try library.addModel(displayName: "Drafting Route", path: "/tmp/drafter", bookmarkData: nil)
        try store.models.setActiveModel(id: startup.id)
        library.refresh()
        library.assignModel(drafter.id, to: .drafting)

        let result = await library.ensureLoadedRoutedModelID(for: .drafting)

        guard case let .success(modelID) = result else {
            return XCTFail("Expected the assigned drafting model to load.")
        }
        XCTAssertEqual(modelID.rawValue.uuidString, drafter.id)
        XCTAssertEqual(stub.loadRequests.map { $0.modelID.rawValue.uuidString }, [drafter.id])
        XCTAssertEqual(library.activeModel?.id, drafter.id)
    }

    func testRoutedLoadFailsWhenRoleIsUnassignedInsteadOfUsingActiveModel() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let startup = try library.addModel(displayName: "Generic Startup", path: "/tmp/startup", bookmarkData: nil)
        try store.models.setActiveModel(id: startup.id)
        // A second registered model so the single-model convenience fallback does not
        // apply: with >1 model an unassigned role must fail rather than silently pick
        // the active/startup model.
        _ = try library.addModel(displayName: "Other", path: "/tmp/other", bookmarkData: nil)
        library.refresh()

        let result = await library.ensureLoadedRoutedModelID(
            for: .legalReasoning,
            configuration: LegalModelConfiguration(legalReasoningModel: "MissingPreferred")
        )

        XCTAssertEqual(
            result,
            .failure(.roleUnassigned(role: .legalReasoning, configuredIdentifier: "MissingPreferred"))
        )
        XCTAssertTrue(stub.loadRequests.isEmpty)
        XCTAssertNil(library.loadedModelID)
    }

    func testRoleAssignmentsPersistByModelID() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let critic = try library.addModel(displayName: "Critic", path: "/tmp/critic", bookmarkData: nil)

        library.assignModel(critic.id, to: .critique)

        let reopened = ModelLibrary(store: store, runtimeClient: stub)
        XCTAssertEqual(reopened.roleAssignments.modelID(for: .critique), critic.id)
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
    private var _loadRequests: [LoadModelRequest] = []

    var cancelledGenerationIDs: [GenerationID] {
        lock.withLock { _cancelledGenerationIDs }
    }

    var loadRequests: [LoadModelRequest] {
        lock.withLock { _loadRequests }
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
        lock.withLock { _loadRequests.append(request) }
        return loadResult
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
