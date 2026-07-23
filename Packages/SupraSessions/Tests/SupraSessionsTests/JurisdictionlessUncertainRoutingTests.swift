import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// The controller-level backstop for the fail-closed router on conversational
/// prompts (user report: global chat "always errors"; the same class produced
/// junk CourtListener searches in matter chats). A prompt the classifier could
/// only mark `.uncertain` routes to legalQA fail-closed — but when the prompt
/// itself carries NO legal evidence, that route can only dead-end: the
/// jurisdiction block in a jurisdictionless chat, or an authority search over
/// non-legal text in a matter chat. The controller therefore answers an
/// INFERRED-UNCERTAIN legal route on the general route unless the PROMPT ITSELF
/// shows legal intent (REVISED in RED, matter-parity direction from the user;
/// measured: all 15 committed legal-recall corpus entries classify confidently
/// `.legal`, so no committed recall rides on the uncertain band):
///
/// - prompt-INTRINSIC legal evidence keeps the gate: a stated jurisdiction
///   ("under Florida law"), a named citation ("Smith v. Jones"), or a docket ask
///   ("who sued X") — context-supplied jurisdiction (matter scope, the chat
///   picker, history) never converts conversation into a research run;
/// - confident classifications (`.legal`) and deterministic markers KEEP their
///   gates — recall protection is untouched;
/// - explicit slash commands are never overridden.
///
/// Expected RED for this file: `effectiveRoutedPrompt` does not exist on
/// `GlobalChatController`, so the file does not compile. (Second RED, matter
/// parity: T-JLU-05 revised and T-JLU-06 added fail against the
/// jurisdiction-availability rule, which kept context-gated conversation on the
/// legal route.)
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

    /// T-JLU-05 (REVISED in RED — matter parity, user direction). The chat's
    /// jurisdiction picker bounds legal research; it must not convert
    /// conversation into a research run. An uncertain prompt with no intrinsic
    /// legal evidence downgrades even with an override selected.
    @MainActor
    func testUncertainConversationDowngradesDespiteChatJurisdictionOverride() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()
        let florida = try XCTUnwrap(
            controller.stateJurisdictions.first { $0.displayName.localizedCaseInsensitiveContains("Florida") }
        )
        controller.jurisdictionOverrideID = florida.id

        let uncertain = routed("Can you rewrite this paragraph to sound friendlier?", classifier: .uncertain)
        XCTAssertEqual(controller.effectiveRoutedPrompt(uncertain).route.mode, .generalQA)
    }

    /// T-JLU-06 (matter parity). A matter's courts satisfy the jurisdiction gate,
    /// so before this rule an uncertain conversational prompt ran a junk
    /// CourtListener search and answered "didn't find authority matching this
    /// query" (observed). It now answers on the general route, exactly like
    /// global chat.
    @MainActor
    func testUncertainConversationInAMatterAnswersOnTheGeneralRoute() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme v. Beta", jurisdiction: "California")
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient { request in
                .events([
                    .event(request, 1, .token, token: "General answer."),
                    .event(request, 2, .generationCompleted),
                ])
            },
            scope: .matter(id: matter.id)
        )
        controller.loadChats()

        let uncertain = routed("Can you rewrite this paragraph to sound friendlier?", classifier: .uncertain)
        let effective = controller.effectiveRoutedPrompt(uncertain)
        XCTAssertEqual(effective.route.mode, .generalQA)

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

    /// T-JLU-07. A named citation is the prompt showing legal intent: the gate
    /// stays even when the classifier is uncertain and no jurisdiction exists.
    @MainActor
    func testUncertainNamedCitationStaysGated() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let uncertain = routed("What happened in Smith v. Jones?", classifier: .uncertain)
        XCTAssertEqual(uncertain.route.mode, .legalQA)
        XCTAssertEqual(controller.effectiveRoutedPrompt(uncertain).route.mode, .legalQA)
    }

    /// T-JLU-08. A docket ask ("who sued X") is a factual litigation lookup the
    /// legal route answers from RECAP — it must stay gated, uncertain or not.
    @MainActor
    func testUncertainDocketAskStaysGated() throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        controller.loadChats()

        let uncertain = routed("Who sued Acme Corporation?", classifier: .uncertain)
        XCTAssertEqual(uncertain.route.mode, .legalQA)
        XCTAssertEqual(controller.effectiveRoutedPrompt(uncertain).route.mode, .legalQA)
    }
}
