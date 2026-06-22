import SupraCore
import XCTest

final class ModelRoutingTests: XCTestCase {
    func testConfigurationLoadsEnvironmentOverrides() {
        let config = LegalModelConfiguration.fromEnvironment([
            "SUPRA_MODEL_BACKEND": "mlx",
            "SUPRA_MODEL_LEGAL_REASONING": "Reasoning-4bit",
            "SUPRA_MODEL_DRAFTING": "Draft-4bit",
            "SUPRA_MODEL_CRITIQUE": "Critique-4bit",
            "SUPRA_DEFAULT_CONTEXT_TOKENS": "16384",
            "SUPRA_MAX_CONTEXT_TOKENS": "65536",
            "SUPRA_ENABLE_COURTLISTENER": "false",
            "SUPRA_LEGAL_ALLOW_UNGROUNDED_LAW": "true",
            "SUPRA_LEGAL_LOG_QUERY_TERMS": "true"
        ])

        XCTAssertEqual(config.legalReasoningModel, "Reasoning-4bit")
        XCTAssertEqual(config.draftingModel, "Draft-4bit")
        XCTAssertEqual(config.critiqueModel, "Critique-4bit")
        XCTAssertEqual(config.defaultContextTokens, 16_384)
        XCTAssertFalse(config.enableCourtListener)
        XCTAssertTrue(config.allowUngroundedLaw)
        XCTAssertTrue(config.logPrivilegedQueryTerms)
    }

    func testSlashCommandsRouteToExpectedRolesAndPresets() {
        let config = LegalModelConfiguration(
            legalReasoningModel: "Reasoner",
            draftingModel: "Drafter",
            critiqueModel: "Critic"
        )
        let router = ModelRouter(configuration: config)

        let draft = router.routePrompt("/draft Write a letter")
        XCTAssertEqual(draft.route.mode, .drafting)
        XCTAssertEqual(draft.route.role, .drafting)
        XCTAssertEqual(draft.route.modelIdentifier, "Drafter")
        XCTAssertEqual(draft.route.options.preset, .drafting)
        XCTAssertEqual(draft.prompt, "Write a letter")

        let research = router.routePrompt("/research California non-compete cases")
        XCTAssertEqual(research.route.mode, .legalResearch)
        XCTAssertEqual(research.route.role, .legalReasoning)
        XCTAssertEqual(research.route.modelIdentifier, "Reasoner")
        XCTAssertTrue(research.route.requiresCourtListener)
        XCTAssertEqual(research.route.options.thinkingBudget, .high)

        let critique = router.routePrompt("/critique This memo overstates the rule")
        XCTAssertEqual(critique.route.mode, .legalCritique)
        XCTAssertEqual(critique.route.role, .critique)
        XCTAssertEqual(critique.route.modelIdentifier, "Critic")
    }

    func testHighQualityResearchCommandUsesSixBitRole() {
        let config = LegalModelConfiguration(
            legalReasoningModel: "Reasoner-4bit",
            legalReasoningHighQualityModel: "Reasoner-6bit"
        )
        let routed = ModelRouter(configuration: config).routePrompt("/research-hq California contract issue")

        XCTAssertEqual(routed.route.mode, .legalResearch)
        XCTAssertEqual(routed.route.role, .legalReasoningHighQuality)
        XCTAssertEqual(routed.route.modelIdentifier, "Reasoner-6bit")
    }

    func testStructuredOutputRoutesUseTaskSpecificRoles() throws {
        let config = LegalModelConfiguration(
            legalReasoningModel: "Reasoner",
            legalReasoningHighQualityModel: "Reasoner-HQ",
            draftingModel: "Drafter",
            critiqueModel: "Critic"
        )
        let router = ModelRouter(configuration: config)

        XCTAssertEqual(router.route(forStructuredOutput: .legalIssueSpotting)?.role, .legalReasoning)
        XCTAssertEqual(router.route(forStructuredOutput: .researchPlan)?.role, .legalReasoning)
        XCTAssertEqual(router.route(forStructuredOutput: .caseResultSummary)?.role, .legalReasoning)

        let synthesis = router.route(forStructuredOutput: .ruleSynthesis)
        XCTAssertEqual(synthesis?.role, .legalReasoningHighQuality)
        XCTAssertEqual(synthesis?.modelIdentifier, "Reasoner-HQ")

        let outline = router.route(forStructuredOutput: .argumentOutline)
        XCTAssertEqual(outline?.role, .legalReasoningHighQuality)
        XCTAssertEqual(outline?.modelIdentifier, "Reasoner-HQ")

        let skeleton = router.route(forStructuredOutput: .draftingSkeleton)
        XCTAssertEqual(skeleton?.role, .drafting)
        XCTAssertEqual(skeleton?.modelIdentifier, "Drafter")

        for type in [StructuredOutputType.documentQA, .documentQAMemo, .factChronologyTable, .factChronologyNarrative] {
            let route = router.route(forStructuredOutput: type)
            XCTAssertEqual(route?.role, .legalReasoning)
            XCTAssertEqual(route?.modelIdentifier, "Reasoner")
            XCTAssertFalse(route?.requiresCourtListener ?? true)
            XCTAssertTrue(route?.systemPrompt.contains("legal document analysis assistant") ?? false)
            // Grounded document routes decode greedily for faithful, reproducible
            // extraction (the creative legalResearch sampling is case-law-only).
            let options = try XCTUnwrap(route?.options)
            XCTAssertEqual(options.temperature, 0.0, accuracy: 0.0001)
            XCTAssertEqual(options.topP, 1.0, accuracy: 0.0001)
            XCTAssertNil(options.topK)
            XCTAssertNil(options.repetitionPenalty, "greedy extraction must not carry a repetition penalty")
        }

        let repair = router.repairRoute(forStructuredOutput: .ruleSynthesis)
        XCTAssertEqual(repair?.role, .critique)
        XCTAssertEqual(repair?.modelIdentifier, "Critic")
    }

    func testLegalQAAndResearchUseDistinctSpecializedPrompts() {
        let router = ModelRouter()
        let qa = router.route(for: .legalQA).systemPrompt
        let research = router.route(for: .legalResearch).systemPrompt
        XCTAssertNotEqual(qa, research, "direct-answer and research-memo modes should not share one prompt")
        // Both carry the jurisdiction-binding directive and the packet-label contract.
        for prompt in [qa, research] {
            XCTAssertTrue(prompt.contains("controlling"), "missing jurisdiction-binding directive")
            XCTAssertTrue(prompt.contains("[A1]"), "missing [A#] citation contract")
        }
        // The research-memo prompt carries citator discipline; the direct answer leads with the bottom line.
        XCTAssertTrue(research.contains("VERIFY CITATOR TREATMENT"))
        XCTAssertTrue(qa.lowercased().contains("bottom line"))
    }

    func testLegalRouteRequiresJurisdictionWhenConfigured() {
        let router = ModelRouter(configuration: LegalModelConfiguration(jurisdictionRequired: true))
        let legal = router.route(for: .legalQA)
        XCTAssertTrue(legal.requiresJurisdiction)
        XCTAssertTrue(legal.requiresCitations)
        XCTAssertFalse(legal.allowUngroundedLaw)
    }

    func testLegalInferenceAvoidsGenericContractLanguage() {
        let router = ModelRouter()

        XCTAssertEqual(router.routePrompt("Draft a friendly contract renewal email").route.mode, .generalQA)
        XCTAssertEqual(router.routePrompt("What is the rule under California contract law?").route.mode, .legalQA)
    }
}
