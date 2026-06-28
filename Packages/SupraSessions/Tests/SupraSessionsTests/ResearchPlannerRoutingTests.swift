import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Regression tests for the research query-planner routing fix. The planner used to
/// inherit the `.legalResearch` route's `thinkingBudget: .high`, so a reasoning model
/// spent its whole output budget on a `<think>` trace and produced no `## Query N`
/// blocks — surfacing as "no recommended queries" on even a trivial question. The fix
/// forces thinking off (and caps output) for planning, and resolves reasoning before
/// parsing so a closed `<think>…</think>` answer still yields queries.
@MainActor
final class ResearchPlannerRoutingTests: XCTestCase {

    private let fiveQueryMarkdown = """
    # Research Queries

    ## Query 1
    "Uniform Commercial Code" "sale of goods"

    ## Query 2
    "UCC Article 2" scope goods transaction

    ## Query 3
    "statute of frauds" goods price threshold

    ## Query 4
    "contract for sale" goods applicability

    ## Query 5
    "transaction in goods" merchant
    """

    /// The core fix: the request that reaches the runtime must have thinking OFF and a
    /// capped output budget, even though the supplied route is `.legalResearch` (which
    /// carries `thinkingBudget: .high` and `maxOutputTokens: 6000`).
    func testPlannerForcesThinkingOffAndCapsOutputBudget() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let markdown = fiveQueryMarkdown
        let runtime = StubRuntimeClient(outcome: { request in
            // The legalResearch preset's heavy thinking budget must not reach the runtime.
            XCTAssertEqual(request.options.thinkingBudget, .off)
            XCTAssertFalse(request.options.thinkingBudget.enablesModelThinking)
            XCTAssertLessThanOrEqual(request.options.maxOutputTokens, 1024)
            return .events([
                .event(request, 0, .token, token: markdown),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = ResearchSessionController(store: store, runtimeClient: runtime, matterID: matter.id)

        // The route the planner view supplies — full .legalResearch options (thinking .high).
        let route = ModelRouter().route(for: .legalResearch)
        XCTAssertEqual(route.options.thinkingBudget, .high)

        let draft = ResearchPlanDraft(
            title: "UCC scope",
            issueText: "Does the Uniform Commercial Code apply to sales of goods less than $500?",
            jurisdiction: "Florida"
        )
        await controller.generatePlan(draft: draft, modelID: ModelID(), route: route)

        XCTAssertEqual(controller.plannedQueries.count, 5)
        XCTAssertEqual(controller.planState, .ready)
    }

    /// A reasoning model that closes its `<think>` block and then writes the template
    /// must still parse to five queries (the resolve → parse path).
    func testReasoningModelClosedThinkingStillParsesQueries() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let reasoningOutput = """
        <think>
        The user asks whether the UCC governs sales of goods under $500. Article 2 applies to
        transactions in goods regardless of price; the $500 figure is the statute-of-frauds
        writing threshold, not a scope limit. Let me draft search queries that capture both.
        </think>

        \(fiveQueryMarkdown)
        """
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: reasoningOutput),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = ResearchSessionController(store: store, runtimeClient: runtime, matterID: matter.id)

        let draft = ResearchPlanDraft(title: "UCC scope", issueText: "UCC sale of goods under $500", jurisdiction: "Florida")
        await controller.generatePlan(draft: draft, modelID: ModelID(), route: ModelRouter().route(for: .legalResearch))

        XCTAssertEqual(controller.plannedQueries.count, 5)
        XCTAssertEqual(controller.planState, .ready)
    }

    /// Prose with no `## Query` headings degrades to a manual-entry message, not a crash.
    func testProseWithoutHeadingsReportsIncomplete() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "The UCC applies to transactions in goods regardless of price."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = ResearchSessionController(store: store, runtimeClient: runtime, matterID: matter.id)

        let draft = ResearchPlanDraft(title: "UCC scope", issueText: "UCC sale of goods", jurisdiction: "Florida")
        await controller.generatePlan(draft: draft, modelID: ModelID(), route: ModelRouter().route(for: .legalResearch))

        XCTAssertTrue(controller.plannedQueries.isEmpty)
        guard case .incomplete = controller.planState else {
            return XCTFail("Expected .incomplete, got \(controller.planState)")
        }
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchPlannerStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
