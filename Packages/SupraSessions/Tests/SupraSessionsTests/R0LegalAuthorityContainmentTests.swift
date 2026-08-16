import Foundation
import SupraCore
import SupraResearch
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

private final class R0CourtListenerRecorder: CourtListenerClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let response: CourtListenerSearchResponse
    private var recordedRequests: [CourtListenerSearchRequest] = []

    var requests: [CourtListenerSearchRequest] {
        lock.withLock { recordedRequests }
    }

    init(response: CourtListenerSearchResponse = .init(count: 0, results: [])) {
        self.response = response
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        lock.withLock { recordedRequests.append(request) }
        return response
    }

    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        CourtListenerOpinionDetailDTO(
            id: id,
            plainText: "Peacock v. Thomas limits ancillary jurisdiction over a new party."
        )
    }
}

private final class R0PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompts: [String] = []

    var prompts: [String] {
        lock.withLock { recordedPrompts }
    }

    func record(_ prompt: String) {
        lock.withLock { recordedPrompts.append(prompt) }
    }
}

@MainActor
final class R0LegalAuthorityContainmentTests: XCTestCase {
    /// T-EGRESS-R0-01 expected RED: matter chat currently plans and transmits this
    /// topical query automatically, creating an automatic research session.
    func testMatterDerivedQuickResearchStopsBeforeProviderAndDirectsToReviewedResearch() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Synthetic Meridian",
            jurisdiction: "Florida",
            clientNames: "MERIDIAN-CLIENT-771"
        )
        let court = R0CourtListenerRecorder()
        let prompts = R0PromptRecorder()
        let runtime = StubRuntimeClient { request in
            prompts.record(request.prompt)
            return .events([
                .event(request, 1, .token, token: "This should not be generated."),
                .event(request, 2, .generationCompleted),
            ])
        }
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "Research Florida successor liability for the Meridian client.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertTrue(court.requests.isEmpty, "blocked matter-derived research must make zero provider calls")
        XCTAssertTrue(prompts.prompts.isEmpty, "containment must run before query planning or answer generation")
        XCTAssertTrue(try store.research.fetchSessions(matterID: matter.id).isEmpty)
        let answer = try XCTUnwrap(controller.messages.last)
        XCTAssertEqual(answer.status, .completed)
        XCTAssertTrue(answer.content.contains("No legal-data query was sent"))
        XCTAssertTrue(answer.content.contains("Research"))
    }

    /// T-EGRESS-R0-02 expected RED: the current citation-first path still invokes
    /// the model query planner before sending the deterministic public lookup.
    func testPublicCaseCitationUsesOneDeterministicRequestWithoutPlannerOrMatterCanary() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Synthetic Meridian",
            jurisdiction: "Florida",
            clientNames: "MERIDIAN-CLIENT-771"
        )
        let response = CourtListenerSearchResponse(
            count: 1,
            results: [
                CourtListenerSearchResultDTO(
                    absoluteURL: "/opinion/1/peacock-v-thomas/",
                    caseName: "Peacock v. Thomas",
                    citation: ["516 U.S. 349"],
                    clusterID: 1,
                    court: "Supreme Court of the United States",
                    courtID: "scotus",
                    dateFiled: "1996-02-21",
                    opinions: [CourtListenerOpinionDTO(id: 11, snippet: "Ancillary jurisdiction is limited.")],
                    status: "Published"
                )
            ]
        )
        let court = R0CourtListenerRecorder(response: response)
        let prompts = R0PromptRecorder()
        let runtime = StubRuntimeClient { request in
            prompts.record(request.prompt)
            let answer = request.prompt.contains("SOURCE PACKET")
                ? "Peacock limits ancillary jurisdiction over a new party [A1]."
                : "planner output that must never be requested"
            return .events([
                .event(request, 1, .token, token: answer),
                .event(request, 2, .generationCompleted),
            ])
        }
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id),
            courtListenerClient: court
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What did Peacock v. Thomas, 516 U.S. 349 hold?",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        XCTAssertEqual(court.requests.count, 1)
        let request = try XCTUnwrap(court.requests.first)
        XCTAssertEqual(request.query, "516 U.S. 349")
        XCTAssertEqual(request.citation, "516 U.S. 349")
        XCTAssertTrue(request.courtIDs.isEmpty)
        XCTAssertFalse(request.query.contains("MERIDIAN-CLIENT-771"))
        XCTAssertFalse(
            prompts.prompts.contains {
                $0.contains("expert legal researcher generating CourtListener case-law search queries")
            },
            "a deterministic public citation lookup must not invoke the model query planner"
        )
        XCTAssertTrue(try XCTUnwrap(prompts.prompts.first).contains("SOURCE PACKET"))
    }

    /// T-AUTH-R0-01 expected RED: all four authority-asserting templates currently
    /// call the runtime and persist an output, then downgrade it to needs-review.
    func testAuthorityAssertingOutputsWithoutReviewedPacketMakeZeroRuntimeAndStoreCalls() async throws {
        let authorityTypes: [StructuredOutputType] = [
            .researchPlan,
            .caseResultSummary,
            .ruleSynthesis,
            .argumentOutline,
        ]

        for type in authorityTypes {
            let store = try SupraStore.inMemory()
            let matter = try store.matters.createMatter(name: "Synthetic \(type.rawValue)")
            let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: type))
            let markdown = contract.requiredHeadings.map { "\($0)\n\nSynthetic content" }.joined(separator: "\n\n")
            let prompts = R0PromptRecorder()
            let runtime = StubRuntimeClient { request in
                prompts.record(request.prompt)
                return .events([
                    .event(request, 1, .token, token: markdown),
                    .event(request, 2, .generationCompleted),
                ])
            }
            let controller = StructuredOutputController(
                store: store,
                runtimeClient: runtime,
                matterID: matter.id
            )

            let created = await controller.createOutput(
                type: type,
                context: "MERIDIAN-AUTHORITY-CONTEXT-442",
                modelID: ModelID()
            )

            XCTAssertFalse(created, "\(type.rawValue) must fail closed without a reviewed authority packet")
            XCTAssertTrue(prompts.prompts.isEmpty, "\(type.rawValue) must be blocked before model work")
            XCTAssertTrue(try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty)
            XCTAssertTrue(
                try store.auditEvents.fetchEvents(matterID: matter.id)
                    .filter { $0.eventType == "structured_output_created" }
                    .isEmpty
            )
            XCTAssertTrue(controller.message?.contains("reviewed authorities") == true)
        }
    }

    /// T-AUTH-R0-02 is a standing parity guard: a non-authority scaffold must
    /// remain available while authority-asserting work is contained.
    func testNonAuthorityScaffoldStillGeneratesAndPersists() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic Scaffold")
        let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: .draftingSkeleton))
        let markdown = contract.requiredHeadings.map { "\($0)\n\nSynthetic content" }.joined(separator: "\n\n")
        let prompts = R0PromptRecorder()
        let runtime = StubRuntimeClient { request in
            prompts.record(request.prompt)
            return .events([
                .event(request, 1, .token, token: markdown),
                .event(request, 2, .generationCompleted),
            ])
        }
        let controller = StructuredOutputController(store: store, runtimeClient: runtime, matterID: matter.id)

        let created = await controller.createOutput(
            type: .draftingSkeleton,
            context: "MERIDIAN-SCAFFOLD-CONTEXT-119",
            modelID: ModelID()
        )

        XCTAssertTrue(created)
        XCTAssertEqual(prompts.prompts.count, 1)
        XCTAssertEqual(try store.structuredOutputs.fetchOutputs(matterID: matter.id).count, 1)
    }
}
