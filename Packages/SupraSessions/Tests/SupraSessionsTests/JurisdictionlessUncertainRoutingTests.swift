import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// The controller-level backstop for the fail-closed router in a chat with no
/// jurisdiction context (user report: global chat "always errors"). A prompt the
/// classifier could only mark `.uncertain` routes to legalQA fail-closed — but in
/// a jurisdictionless global chat that route can produce NOTHING except the
/// "I need the jurisdiction" block, so ordinary conversation dead-ends. The
/// controller therefore answers an INFERRED-UNCERTAIN legal route on the general
/// route when (and only when) no jurisdiction is available:
///
/// - confident classifications (`.legal`) and deterministic markers KEEP their
///   gates — recall protection is untouched;
/// - explicit slash commands are never overridden;
/// - with a jurisdiction available (matter scope, the chat's jurisdiction
///   picker, or one stated in the prompt), `.uncertain` stays on the gated
///   route exactly as before — matter chat is unchanged.
///
/// Expected RED for this file: `effectiveRoutedPrompt` does not exist on
/// `GlobalChatController`, so the file does not compile.
final class JurisdictionlessUncertainRoutingTests: XCTestCase {

    private struct FixedClassifier: PromptIntentClassifying {
        let result: PromptIntentClassification
        func classify(_ prompt: String) -> PromptIntentClassification { result }
    }

    private func makeStore() throws -> SupraStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jurisdictionless-\(UUID().uuidString).sqlite")
        return try SupraStore(url: url)
    }

    @MainActor
    private func makeController(store: SupraStore) -> GlobalChatController {
        makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { request in
                .events([
                    .event(request, 1, .token, token: "General answer."),
                    .event(request, 2, .generationCompleted),
                ])
            }
        )
    }

    private func routed(
        _ prompt: String,
        classifier: PromptIntentClassification
    ) -> RoutedPrompt {
        ModelRouter(
            configuration: LegalModelConfiguration(requireCitations: true, jurisdictionRequired: true),
            intentClassifier: FixedClassifier(result: classifier)
        ).routePrompt(prompt)
    }

    /// T-JLU-01. Inferred-uncertain + no jurisdiction anywhere → the general route,
    /// and a full send produces a model answer instead of the jurisdiction block.
    @MainActor
    func testUncertainWithoutJurisdictionAnswersOnTheGeneralRoute() async throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let uncertain = routed("Can you rewrite this paragraph to sound friendlier?", classifier: .uncertain)
        XCTAssertEqual(uncertain.route.mode, .legalQA, "precondition: the router failed closed")

        let effective = controller.effectiveRoutedPrompt(uncertain)
        XCTAssertEqual(effective.route.mode, .generalQA)
        XCTAssertFalse(effective.route.requiresJurisdiction)

        await controller.performSend(
            prompt: effective.prompt,
            modelID: nil,
            systemPrompt: effective.route.systemPrompt,
            options: effective.route.options,
            route: effective.route,
            modelResolver: { @MainActor in .model(ModelID()) }
        )
        XCTAssertEqual(controller.messages.last?.content, "General answer.")
    }

    /// T-JLU-02. A jurisdiction stated in the prompt satisfies the gate, so the
    /// uncertain prompt STAYS gated — the downgrade only applies where the gated
    /// route could produce nothing.
    @MainActor
    func testUncertainWithPromptJurisdictionStaysGated() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let uncertain = routed(
            "Does that rule change anything under Florida law for my situation?",
            classifier: .uncertain
        )
        XCTAssertEqual(uncertain.route.mode, .legalQA)
        XCTAssertEqual(controller.effectiveRoutedPrompt(uncertain).route.mode, .legalQA)
    }

    /// T-JLU-03. A confident legal classification keeps its gate even with no
    /// jurisdiction: the jurisdiction ask is the CORRECT outcome for a genuine
    /// legal question that needs one.
    @MainActor
    func testConfidentLegalWithoutJurisdictionStaysGated() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let legal = routed("What is the deadline to file an answer?", classifier: .legal)
        XCTAssertEqual(legal.route.mode, .legalQA)
        XCTAssertEqual(controller.effectiveRoutedPrompt(legal).route.mode, .legalQA)
    }

    /// T-JLU-04. Explicit slash commands are the user's own routing decision and
    /// are never overridden.
    @MainActor
    func testSlashCommandIsNeverDowngraded() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let explicit = routed("/legal is this clause enforceable", classifier: .general)
        XCTAssertEqual(explicit.route.mode, .legalQA)
        XCTAssertNil(explicit.inferredIntent)
        XCTAssertEqual(controller.effectiveRoutedPrompt(explicit).route.mode, .legalQA)
    }

    /// T-JLU-05. The chat's jurisdiction picker supplies context: with an override
    /// selected, the uncertain prompt stays gated (mirrors matter scope, where the
    /// matter's courts do the same).
    @MainActor
    func testUncertainWithChatJurisdictionOverrideStaysGated() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()
        let florida = try XCTUnwrap(
            controller.stateJurisdictions.first { $0.displayName.localizedCaseInsensitiveContains("Florida") }
        )
        controller.jurisdictionOverrideID = florida.id

        let uncertain = routed("Can you rewrite this paragraph to sound friendlier?", classifier: .uncertain)
        XCTAssertEqual(controller.effectiveRoutedPrompt(uncertain).route.mode, .legalQA)
    }
}
