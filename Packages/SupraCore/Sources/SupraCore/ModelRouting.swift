import Foundation

public enum ModelBackend: String, Codable, Hashable, Sendable {
    case mlx
}

public enum ModelRole: String, Codable, Hashable, Sendable, CaseIterable {
    case legalReasoning = "legal_reasoning"
    case legalReasoningHighQuality = "legal_reasoning_high_quality"
    case drafting
    case critique

    public var displayName: String {
        switch self {
        case .legalReasoning:
            "Legal reasoning"
        case .legalReasoningHighQuality:
            "High-quality legal reasoning"
        case .drafting:
            "Drafting"
        case .critique:
            "Critique"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .legalReasoning:
            "Legal"
        case .legalReasoningHighQuality:
            "Legal HQ"
        case .drafting:
            "Draft"
        case .critique:
            "Critique"
        }
    }
}

public enum ModelRouteMode: String, Codable, Hashable, Sendable, CaseIterable {
    case drafting
    case generalQA = "general_qa"
    case legalQA = "legal_qa"
    case legalResearch = "legal_research"
    case legalCritique = "legal_critique"
    case legalVerify = "legal_verify"

    public var slashCommand: String {
        switch self {
        case .drafting: "/draft"
        case .generalQA: "/ask"
        case .legalQA: "/legal"
        case .legalResearch: "/research"
        case .legalCritique: "/critique"
        case .legalVerify: "/verify"
        }
    }
}

public struct LegalModelConfiguration: Codable, Hashable, Sendable {
    public var backend: ModelBackend
    public var legalReasoningModel: String
    public var legalReasoningHighQualityModel: String
    public var draftingModel: String
    public var critiqueModel: String
    public var defaultContextTokens: Int
    public var maxContextTokens: Int
    public var enableCourtListener: Bool
    public var courtListenerBaseURL: String
    public var requireCitations: Bool
    public var allowUngroundedLaw: Bool
    public var verifyCitations: Bool
    public var jurisdictionRequired: Bool
    public var logPrivilegedQueryTerms: Bool

    public init(
        backend: ModelBackend = .mlx,
        legalReasoningModel: String = "Qwen3-30B-A3B-Thinking-2507-MLX-4bit",
        legalReasoningHighQualityModel: String = "DeepSeek-R1-Distill-Qwen-32B-MLX-4bit",
        draftingModel: String = "Qwen3-30B-A3B-Instruct-2507-MLX-4bit",
        critiqueModel: String = "DeepSeek-R1-Distill-Qwen-32B-MLX-4bit",
        defaultContextTokens: Int = 32_768,
        maxContextTokens: Int = 65_536,
        enableCourtListener: Bool = true,
        courtListenerBaseURL: String = "https://www.courtlistener.com/api/rest/v4",
        requireCitations: Bool = true,
        allowUngroundedLaw: Bool = false,
        verifyCitations: Bool = true,
        jurisdictionRequired: Bool = true,
        logPrivilegedQueryTerms: Bool = false
    ) {
        self.backend = backend
        self.legalReasoningModel = legalReasoningModel
        self.legalReasoningHighQualityModel = legalReasoningHighQualityModel
        self.draftingModel = draftingModel
        self.critiqueModel = critiqueModel
        self.defaultContextTokens = defaultContextTokens
        self.maxContextTokens = maxContextTokens
        self.enableCourtListener = enableCourtListener
        self.courtListenerBaseURL = courtListenerBaseURL
        self.requireCitations = requireCitations
        self.allowUngroundedLaw = allowUngroundedLaw
        self.verifyCitations = verifyCitations
        self.jurisdictionRequired = jurisdictionRequired
        self.logPrivilegedQueryTerms = logPrivilegedQueryTerms
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LegalModelConfiguration {
        LegalModelConfiguration(
            backend: ModelBackend(rawValue: environment["SUPRA_MODEL_BACKEND"]?.lowercased() ?? "") ?? .mlx,
            legalReasoningModel: environment.nonEmpty("SUPRA_MODEL_LEGAL_REASONING") ?? "Qwen3-30B-A3B-Thinking-2507-MLX-4bit",
            legalReasoningHighQualityModel: environment.nonEmpty("SUPRA_MODEL_LEGAL_REASONING_HIGH_QUALITY") ?? "DeepSeek-R1-Distill-Qwen-32B-MLX-4bit",
            draftingModel: environment.nonEmpty("SUPRA_MODEL_DRAFTING") ?? "Qwen3-30B-A3B-Instruct-2507-MLX-4bit",
            critiqueModel: environment.nonEmpty("SUPRA_MODEL_CRITIQUE") ?? "DeepSeek-R1-Distill-Qwen-32B-MLX-4bit",
            defaultContextTokens: environment.positiveInt("SUPRA_DEFAULT_CONTEXT_TOKENS") ?? 32_768,
            maxContextTokens: environment.positiveInt("SUPRA_MAX_CONTEXT_TOKENS") ?? 65_536,
            enableCourtListener: environment.bool("SUPRA_ENABLE_COURTLISTENER") ?? true,
            courtListenerBaseURL: environment.nonEmpty("SUPRA_COURTLISTENER_BASE_URL") ?? "https://www.courtlistener.com/api/rest/v4",
            requireCitations: environment.bool("SUPRA_LEGAL_REQUIRE_CITATIONS") ?? true,
            allowUngroundedLaw: environment.bool("SUPRA_LEGAL_ALLOW_UNGROUNDED_LAW") ?? false,
            verifyCitations: environment.bool("SUPRA_LEGAL_VERIFY_CITATIONS") ?? true,
            jurisdictionRequired: environment.bool("SUPRA_LEGAL_JURISDICTION_REQUIRED") ?? true,
            logPrivilegedQueryTerms: environment.bool("SUPRA_LEGAL_LOG_QUERY_TERMS") ?? false
        )
    }

    public func modelIdentifier(for role: ModelRole) -> String {
        switch role {
        case .legalReasoning:
            legalReasoningModel
        case .legalReasoningHighQuality:
            legalReasoningHighQualityModel
        case .drafting:
            draftingModel
        case .critique:
            critiqueModel
        }
    }
}

public struct ModelRoute: Codable, Hashable, Sendable {
    public var mode: ModelRouteMode
    public var role: ModelRole
    public var modelIdentifier: String
    public var options: GenerationOptions
    public var requiresCourtListener: Bool
    public var requiresCitations: Bool
    public var requiresJurisdiction: Bool
    public var allowUngroundedLaw: Bool
    public var systemPrompt: String

    public init(
        mode: ModelRouteMode,
        role: ModelRole,
        modelIdentifier: String,
        options: GenerationOptions,
        requiresCourtListener: Bool,
        requiresCitations: Bool,
        requiresJurisdiction: Bool,
        allowUngroundedLaw: Bool,
        systemPrompt: String
    ) {
        self.mode = mode
        self.role = role
        self.modelIdentifier = modelIdentifier
        self.options = options
        self.requiresCourtListener = requiresCourtListener
        self.requiresCitations = requiresCitations
        self.requiresJurisdiction = requiresJurisdiction
        self.allowUngroundedLaw = allowUngroundedLaw
        self.systemPrompt = systemPrompt
    }
}

public struct RoutedPrompt: Codable, Hashable, Sendable {
    public var route: ModelRoute
    public var prompt: String
    public var command: String?
}

public struct ModelRouter: Sendable {
    public var configuration: LegalModelConfiguration

    public init(configuration: LegalModelConfiguration = .fromEnvironment()) {
        self.configuration = configuration
    }

    public func route(for mode: ModelRouteMode) -> ModelRoute {
        let role: ModelRole
        let preset: GenerationPreset
        let requiresCourtListener: Bool
        let requiresCitations: Bool
        let requiresJurisdiction: Bool
        let systemPrompt: String

        switch mode {
        case .drafting:
            role = .drafting
            preset = .drafting
            requiresCourtListener = false
            requiresCitations = false
            requiresJurisdiction = false
            systemPrompt = LegalPromptTemplates.draftingSystemPrompt
        case .generalQA:
            role = .drafting
            preset = .balanced
            requiresCourtListener = false
            requiresCitations = false
            requiresJurisdiction = false
            systemPrompt = LegalPromptTemplates.generalSystemPrompt
        case .legalQA:
            role = .legalReasoning
            preset = .legalReasoning
            requiresCourtListener = configuration.enableCourtListener && !configuration.allowUngroundedLaw
            requiresCitations = configuration.requireCitations
            requiresJurisdiction = configuration.jurisdictionRequired
            systemPrompt = LegalPromptTemplates.legalAnswerSystemPrompt
        case .legalResearch:
            role = .legalReasoning
            preset = .legalResearch
            requiresCourtListener = configuration.enableCourtListener
            requiresCitations = configuration.requireCitations
            requiresJurisdiction = configuration.jurisdictionRequired
            systemPrompt = LegalPromptTemplates.legalResearchSystemPrompt
        case .legalCritique:
            role = .critique
            preset = .legalCritique
            requiresCourtListener = false
            requiresCitations = false
            requiresJurisdiction = false
            systemPrompt = LegalPromptTemplates.critiqueSystemPrompt
        case .legalVerify:
            role = .legalReasoning
            preset = .legalVerify
            requiresCourtListener = false
            requiresCitations = configuration.requireCitations
            requiresJurisdiction = false
            systemPrompt = LegalPromptTemplates.verificationSystemPrompt
        }

        var options = preset.defaultOptions
        options.maxContextTokens = min(options.maxContextTokens, configuration.maxContextTokens)
        if mode != .legalResearch {
            options.maxContextTokens = min(options.maxContextTokens, configuration.defaultContextTokens)
        }

        return ModelRoute(
            mode: mode,
            role: role,
            modelIdentifier: configuration.modelIdentifier(for: role),
            options: options,
            requiresCourtListener: requiresCourtListener,
            requiresCitations: requiresCitations,
            requiresJurisdiction: requiresJurisdiction,
            allowUngroundedLaw: configuration.allowUngroundedLaw,
            systemPrompt: systemPrompt
        )
    }

    public func route(forStructuredOutput type: StructuredOutputType) -> ModelRoute? {
        switch type {
        case .legalIssueSpotting, .researchPlan, .caseResultSummary:
            return route(for: .legalResearch)
        case .ruleSynthesis, .argumentOutline:
            var route = route(for: .legalResearch)
            route.role = .legalReasoningHighQuality
            route.modelIdentifier = configuration.modelIdentifier(for: .legalReasoningHighQuality)
            return route
        case .draftingSkeleton:
            return route(for: .drafting)
        case .documentQA, .documentQAMemo, .factChronologyTable, .factChronologyNarrative:
            var route = route(for: .legalResearch)
            route.requiresCourtListener = false
            route.requiresJurisdiction = false
            route.systemPrompt = LegalPromptTemplates.documentGroundedSystemPrompt
            // Grounded extraction/Q&A over the user's own documents must be faithful
            // and reproducible, so decode greedily (mirroring the classifier) while
            // keeping legalResearch's large context + output budget. The creative
            // legalResearch sampling — including its repetition penalty — stays only
            // on the case-law research-memo path.
            route.options.temperature = 0.0
            route.options.topP = 1.0
            route.options.topK = nil
            route.options.repetitionPenalty = nil
            return route
        }
    }

    public func repairRoute(forStructuredOutput type: StructuredOutputType) -> ModelRoute? {
        switch type {
        case .legalIssueSpotting, .researchPlan, .caseResultSummary, .ruleSynthesis, .argumentOutline, .draftingSkeleton:
            return route(for: .legalCritique)
        case .documentQA, .documentQAMemo, .factChronologyTable, .factChronologyNarrative:
            return nil
        }
    }

    public func routePrompt(_ rawPrompt: String) -> RoutedPrompt {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseSlashCommand(trimmed) {
            return RoutedPrompt(
                route: route(for: parsed.mode),
                prompt: parsed.remainingPrompt,
                command: parsed.command
            )
        }

        let inferredMode: ModelRouteMode = Self.looksLegal(trimmed) ? .legalQA : .generalQA
        return RoutedPrompt(route: route(for: inferredMode), prompt: trimmed, command: nil)
    }

    private func parseSlashCommand(_ prompt: String) -> (mode: ModelRouteMode, command: String, remainingPrompt: String)? {
        guard prompt.hasPrefix("/") else { return nil }
        let parts = prompt.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard let first = parts.first else { return nil }
        let command = String(first).lowercased()
        let remaining = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch command {
        case "/draft":
            return (.drafting, command, remaining)
        case "/ask", "/general":
            return (.generalQA, command, remaining)
        case "/legal":
            return (.legalQA, command, remaining)
        case "/research":
            return (.legalResearch, command, remaining)
        case "/critique", "/redteam", "/red-team", "/secondpass", "/second-pass":
            return (.legalCritique, command, remaining)
        case "/verify":
            return (.legalVerify, command, remaining)
        default:
            return nil
        }
    }

    private static func looksLegal(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let strongMarkers = [
            "case law", "statute", "regulation", "precedent", "jurisdiction",
            "legal authority", "legal standard", "holding", "motion to dismiss",
            "summary judgment", "pleading", "bluebook", "citation", "docket",
            "plaintiff", "defendant", "appellant", "appellee", "injunction",
            "court of appeals", "district court", "supreme court"
        ]
        if strongMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let contextualMarkers = [
            "contract law", "under california law", "under new york law",
            "governing law", "elements of", "cause of action", "burden of proof",
            "standard of review", "recover damages", "damages under"
        ]
        return contextualMarkers.contains { lower.contains($0) }
    }
}

public enum LegalPromptTemplates {
    public static let generalSystemPrompt = """
    You are a helpful local assistant. If the user asks for law, cases, statutes, \
    procedural rules, jurisdiction-specific legal analysis, or current legal authority, \
    say that the legal research route should be used with CourtListener grounding.
    """

    /// Direct-answer mode (the `/legal` route): a focused IRAC answer to a specific
    /// question. Distinct from the research-memo prompt below.
    public static let legalAnswerSystemPrompt = """
    You are a legal research assistant answering a specific question in a source-grounded mode. Give a direct, well-organized answer that moves from issue to rule to application to conclusion; lead with the bottom line.

    Reason only over the authorities in the SOURCE PACKET; never cite, quote, or rely on any authority that is not in the packet. End every sentence that states a legal proposition with its packet label (e.g. [A1]). If the packet does not support a proposition, write [NEEDS AUTHORITY] and say what is missing rather than guessing.

    Treat only authorities that are controlling in the stated jurisdiction as binding, and label everything else persuasive; never describe an out-of-jurisdiction case as controlling. Distinguish a holding from dictum, give pinpoint support where the packet allows, and date-qualify authority. Do not assert that an authority is current good law without noting that citator treatment must be verified.

    Do not invent citations, quotations, holdings, procedural posture, dates, docket numbers, or subsequent history. State assumptions, factual gaps, and the limits of the retrieved authority.
    """

    /// Research-memo mode (the `/research` route): an exhaustive, structured survey.
    public static let legalResearchSystemPrompt = """
    You are a legal research assistant producing a thorough, well-structured research memo in a source-grounded mode. Survey the relevant authority, organize the analysis by issue, and address binding vs. persuasive authority, adverse authority, and any tensions or splits the packet reveals.

    Reason only over the authorities in the SOURCE PACKET; never cite, quote, or rely on any authority that is not in the packet. End every sentence that states a legal proposition with its packet label (e.g. [A1]). If the packet does not support a proposition, write [NEEDS AUTHORITY] and say what is missing rather than guessing.

    Treat only authorities that are controlling in the stated jurisdiction as binding, and label everything else persuasive; never describe an out-of-jurisdiction case as controlling. Distinguish holding from dictum, date-qualify authority, surface adverse authority, and flag where current good-law status needs citator verification ([VERIFY CITATOR TREATMENT]).

    Do not invent citations, quotations, holdings, procedural posture, dates, docket numbers, or subsequent history. State assumptions, unresolved factual gaps, jurisdictional gaps, and research limitations.
    """

    public static let documentGroundedSystemPrompt = """
    You are a legal document analysis assistant operating in a source-grounded mode. Use only the provided document sources. Cite source labels for every factual claim, do not invent facts, dates, quotations, or document contents, and say when the provided sources do not support an answer. Preserve the requested output structure.
    """

    public static let draftingSystemPrompt = """
    You are a legal drafting assistant. Produce clear, precise, attorney-editable work product. Do not represent any legal proposition as current law unless the user has supplied authority or the legal research pipeline has retrieved authority. When authority is missing, use cautious drafting language and flag the need for research.
    """

    public static let critiqueSystemPrompt = """
    You are reviewing legal work product for defects. Identify unsupported propositions, missing elements, adverse authority risk, jurisdictional problems, overbroad statements, factual assumptions, citation defects, and internal contradictions. Do not rewrite the full draft unless asked. Be specific and practical.
    """

    public static let verificationSystemPrompt = """
    You are verifying a legal analysis against a fixed source packet. Determine whether each legal proposition is supported by the cited source. Flag unsupported propositions, invented citations, citation/source mismatches, inaccurate quotations, jurisdictional mismatches, and conclusions that overread the authority. Return a structured verification report.
    """
}

private extension Dictionary where Key == String, Value == String {
    func nonEmpty(_ key: String) -> String? {
        guard let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func positiveInt(_ key: String) -> Int? {
        guard let value = nonEmpty(key), let intValue = Int(value), intValue > 0 else {
            return nil
        }
        return intValue
    }

    func bool(_ key: String) -> Bool? {
        guard let value = nonEmpty(key)?.lowercased() else { return nil }
        switch value {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }
}
