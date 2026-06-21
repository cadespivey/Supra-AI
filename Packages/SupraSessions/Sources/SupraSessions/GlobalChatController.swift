import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Drives the first persisted global chat flow: it owns the list of global
/// chats, the messages of the selected chat, and the send/stream/cancel
/// lifecycle on top of the MLX-backed runtime service.
///
/// Every step is persisted through `SupraStore` so a chat survives relaunch and
/// a partially streamed answer is preserved if generation is cancelled or fails.
@MainActor
public final class GlobalChatController: ObservableObject {
    @Published public private(set) var chats: [ChatSummary] = []
    @Published public private(set) var selectedChatID: String?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isGenerating = false
    @Published public private(set) var errorMessage: String?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    private let scope: ChatScope
    private let router: ModelRouter
    private let legalConfiguration: LegalModelConfiguration
    private let courtListenerClient: any CourtListenerClientProtocol
    private var lastLegalPacketsByChatID: [String: LegalSourcePacket] = [:]
    private var activeGenerationID: GenerationID?

    /// Top-level jurisdiction options (Federal courts plus each state's aggregate
    /// court group), Federal first. Internal — the UI uses `federalCircuits` and
    /// `stateJurisdictions` instead.
    private let topLevelJurisdictions: [JurisdictionOption]

    /// The federal circuit courts, for the picker's Federal section.
    public let federalCircuits: [JurisdictionOption]

    /// The state/territory aggregates (top-level options minus the federal one).
    public var stateJurisdictions: [JurisdictionOption] {
        topLevelJurisdictions.filter { $0.id != "federal-courts" }
    }

    /// The user's jurisdiction choice for global-chat legal research. Empty means
    /// "auto-detect" — infer one from the prompt; otherwise a `JurisdictionOption`
    /// id that hard-bounds CourtListener to that jurisdiction's courts. Persisted
    /// app-wide, but only for the global scope (matter chats are bound by their
    /// matter's jurisdiction instead).
    @Published public var jurisdictionOverrideID: String = "" {
        didSet {
            guard oldValue != jurisdictionOverrideID, case .global = scope else { return }
            try? store.appSettings.setSetting(Self.jurisdictionOverrideKey, value: jurisdictionOverrideID)
        }
    }

    /// When a state is selected, also search the federal courts that apply its law
    /// (its circuit + district courts). Persisted app-wide for the global scope.
    @Published public var includeRelatedFederal: Bool = false {
        didSet {
            guard oldValue != includeRelatedFederal, case .global = scope else { return }
            try? store.appSettings.setSetting(Self.includeRelatedFederalKey, value: includeRelatedFederal)
        }
    }

    static let jurisdictionOverrideKey = "globalChat.jurisdictionOverride"
    static let includeRelatedFederalKey = "globalChat.includeRelatedFederal"

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil,
        scope: ChatScope = .global,
        legalConfiguration: LegalModelConfiguration = .fromEnvironment(),
        tokenStore: (any APIKeyStoreProtocol)? = nil,
        courtListenerClient: (any CourtListenerClientProtocol)? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
        self.scope = scope
        self.legalConfiguration = legalConfiguration
        self.router = ModelRouter(configuration: legalConfiguration)
        let resolvedTokenStore = tokenStore ?? EnvironmentBackedTokenStore(primary: KeychainTokenStore())
        self.courtListenerClient = courtListenerClient ?? CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: resolvedTokenStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests),
                redactsQueryValues: !legalConfiguration.logPrivilegedQueryTerms
            ),
            baseURLOverride: legalConfiguration.courtListenerBaseURL
        )
        self.topLevelJurisdictions = Self.makeTopLevelJurisdictions()
        self.federalCircuits = Self.makeFederalCircuits()
        if case .global = scope {
            self.jurisdictionOverrideID = (try? store.appSettings.getSetting(Self.jurisdictionOverrideKey, as: String.self)) ?? ""
            self.includeRelatedFederal = (try? store.appSettings.getSetting(Self.includeRelatedFederalKey, as: Bool.self)) ?? false
        }
    }

    // MARK: - Chat list

    /// Reloads the scope's chats and, if nothing is selected yet, selects the most recent one.
    public func loadChats() {
        chats = fetchScopedChats()
        if let selectedChatID, chats.contains(where: { $0.id == selectedChatID }) {
            reloadMessages()
        } else {
            select(chatID: chats.first?.id)
        }
    }

    @discardableResult
    public func createChat(title: String = "New Chat") throws -> ChatSummary {
        let record: ChatRecord
        switch scope {
        case .global:
            record = try store.chats.createGlobalChat(title: title)
        case let .matter(id):
            record = try store.chats.createMatterChat(matterID: id, title: title)
        }
        let summary = ChatSummary(record: record)
        chats = fetchScopedChats()
        // Keep selection consistent even if the refetch failed to include the new row.
        if !chats.contains(where: { $0.id == summary.id }) {
            chats.insert(summary, at: 0)
        }
        select(chatID: record.id)
        return summary
    }

    private func fetchScopedChats() -> [ChatSummary] {
        let records: [ChatRecord]?
        switch scope {
        case .global:
            records = try? store.chats.fetchGlobalChats()
        case let .matter(id):
            records = try? store.chats.fetchMatterChats(matterID: id)
        }
        return records?.map(ChatSummary.init) ?? []
    }

    public func select(chatID: String?) {
        selectedChatID = chatID
        reloadMessages()
    }

    private func reloadMessages() {
        guard let selectedChatID else {
            messages = []
            return
        }
        messages = (try? store.chats.fetchMessages(chatID: selectedChatID))?.map(ChatMessage.init) ?? []
    }

    /// Opens a fresh, blank chat: deselects the current chat (clearing the message
    /// list) without yet persisting a row. The actual chat is created lazily on the
    /// first send, titled from that first message — so the history doesn't fill up
    /// with empty "New Chat" placeholders. Drives the example-prompt empty state.
    /// No-op while a response is still streaming.
    public func startNewChat() {
        guard !isGenerating else { return }
        errorMessage = nil
        select(chatID: nil)
    }

    /// Renames a chat from the history sidebar. No-op on an empty title; surfaces a
    /// store failure rather than swallowing it.
    public func renameChat(chatID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.chats.renameChat(id: chatID, title: trimmed)
            chats = fetchScopedChats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Soft-deletes a chat. Blocked while that chat is still generating (so a live
    /// stream can't write into a deleted chat). If the deleted chat was selected,
    /// the view falls back to the blank new-chat state (example prompts).
    public func deleteChat(chatID: String) {
        guard !(isGenerating && selectedChatID == chatID) else {
            errorMessage = "Stop the current generation before deleting this chat."
            return
        }
        do {
            try store.chats.softDeleteChat(id: chatID)
            chats = fetchScopedChats()
            if selectedChatID == chatID {
                select(chatID: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-homes a global chat into a matter (e.g. a chat that turned out to belong
    /// to a matter). Only valid from the global scope, and blocked while that chat
    /// is still generating. The audit event is recorded only after the move is
    /// confirmed by the store, so a failed move never logs a phantom "moved" event.
    public func moveChat(chatID: String, toMatter matterID: String) {
        guard case .global = scope else { return }
        guard !(isGenerating && selectedChatID == chatID) else {
            errorMessage = "Stop the current generation before moving this chat."
            return
        }
        let title = chats.first(where: { $0.id == chatID })?.title ?? "chat"
        do {
            guard try store.chats.moveChatToMatter(id: chatID, matterID: matterID) != nil else {
                errorMessage = "That chat or matter is no longer available."
                return
            }
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID,
                eventType: "chat_moved_to_matter",
                actor: "user",
                summary: "Moved chat “\(title)” into this matter",
                relatedTable: "chats",
                relatedID: chatID
            )
            chats = fetchScopedChats()
            if selectedChatID == chatID {
                select(chatID: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A concise chat title derived from the first user message (first words, up to
    /// ~48 chars on a word boundary). Falls back to "New Chat" for empty input.
    static func derivedTitle(from prompt: String) -> String {
        let collapsed = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "New Chat" }
        let maxLength = 48
        guard collapsed.count > maxLength else { return collapsed }
        let prefix = collapsed.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " ") {
            let trimmed = prefix[..<lastSpace].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed + "…" }
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Sending

    /// Sends a prompt in the selected chat against the given (already loaded) model.
    ///
    /// If no chat is selected, one is created automatically.
    public func send(
        prompt: String,
        modelID: ModelID?,
        attachments: [ChatAttachmentContext] = [],
        systemPrompt: String? = nil,
        options: GenerationOptions? = nil,
        route: ModelRoute? = nil,
        displayPrompt: String? = nil
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsEmptyPrompt = route?.mode == .legalCritique && latestAssistantDraft() != nil
        guard (!trimmed.isEmpty || allowsEmptyPrompt), !isGenerating else { return }
        // Claim the generating flag synchronously on the main actor. The actual
        // work runs in a Task (a later hop), so without claiming it now a second
        // synchronous send() could pass the guard before performSend sets it,
        // launching two concurrent generations on the same chat.
        isGenerating = true

        let effectiveSystemPrompt = systemPrompt ?? route?.systemPrompt ?? storedSystemPrompt() ?? defaultSystemPrompt
        let effectiveOptions = options ?? route?.options ?? storedDefaultOptions()
        Task {
            await self.performSend(
                prompt: trimmed,
                attachments: attachments,
                modelID: modelID,
                systemPrompt: effectiveSystemPrompt,
                options: effectiveOptions,
                route: route,
                displayPrompt: displayPrompt
            )
        }
    }

    public func canSendRoutedPrompt(_ routed: RoutedPrompt) -> Bool {
        let trimmed = routed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch routed.route.mode {
        case .legalCritique:
            return !trimmed.isEmpty || latestAssistantDraft() != nil
        default:
            return !trimmed.isEmpty
        }
    }

    public func requiresRuntimeModel(for routed: RoutedPrompt) -> Bool {
        switch routed.route.mode {
        case .legalVerify:
            return false
        case .legalQA, .legalResearch:
            // Must mirror legalResearchOutput's classification (incl. the chat's
            // jurisdiction selection/inference); otherwise an auto-detected
            // jurisdiction would let research proceed without a model loaded.
            let classification = classificationApplyingChatJurisdiction(
                classificationApplyingMatterScope(LegalQueryClassifier.classify(routed.prompt)),
                prompt: routed.prompt
            )
            return !(routed.route.requiresJurisdiction && classification.needsJurisdictionForAuthority)
        case .legalCritique, .drafting, .generalQA:
            return true
        }
    }

    private func storedDefaultOptions() -> GenerationOptions {
        (try? store.appSettings.getSetting(SettingsController.generationDefaultsKey, as: GenerationOptions.self)) ?? GenerationOptions()
    }

    /// The user's composed "soul document" (system prompt), if set, so profile
    /// edits in Settings shape every chat without a relaunch.
    private func storedSystemPrompt() -> String? {
        store.composedAssistantPrompt()
    }

    /// Requests cancellation of the active generation. The runtime emits a
    /// `generationCancelled` event which the stream loop persists.
    public func cancel() {
        guard let activeGenerationID else { return }
        let runtimeClient = runtimeClient
        Task { _ = try? await runtimeClient.cancelGeneration(activeGenerationID) }
    }

    /// The full persist-and-stream flow. Internal so tests can await it directly.
    func performSend(
        prompt: String,
        attachments: [ChatAttachmentContext] = [],
        modelID: ModelID?,
        systemPrompt: String?,
        options: GenerationOptions,
        route: ModelRoute? = nil,
        displayPrompt: String? = nil
    ) async {
        isGenerating = true
        errorMessage = nil
        defer {
            isGenerating = false
            activeGenerationID = nil
        }

        var variantID: String?
        var sessionID: String?

        // Keep the chat bubble clean (the question + a list of attached files);
        // give the model the attachment contents as grounding.
        let modelPrompt = attachments.isEmpty ? prompt : Self.attachmentsBlock(attachments) + "\n\n" + prompt
        let displayBase = displayPrompt ?? prompt
        let displayContent = attachments.isEmpty
            ? displayBase
            : displayBase + "\n\nAttached: " + attachments.map(\.name).joined(separator: ", ")

        do {
            if let route, route.usesOneShotLegalWorkflow {
                try await performLegalOneShotSend(
                    prompt: prompt,
                    modelPrompt: modelPrompt,
                    displayContent: displayContent,
                    modelID: modelID,
                    route: route,
                    systemPrompt: systemPrompt,
                    options: options
                )
                return
            }

            guard let modelID else {
                errorMessage = "Load or register a local MLX model in the Models tab."
                return
            }

            let chatID = try ensureSelectedChat(titleHint: displayBase).id

            // Replay prior turns so the model can answer follow-ups in context.
            // Captured before appending the new user message.
            let history = Self.conversationHistory(
                from: (try? store.chats.fetchMessages(chatID: chatID))?.map(ChatMessage.init) ?? [],
                budget: Self.historyCharBudget
            )

            _ = try store.chats.appendUserMessage(chatID: chatID, content: displayContent)
            let assistant = try store.chats.createAssistantMessageShell(chatID: chatID)
            let generationID = GenerationID()
            let session = try store.generation.createGenerationSession(
                chatID: chatID,
                messageID: assistant.id,
                modelID: modelID.rawValue.uuidString,
                prompt: modelPrompt,
                systemPrompt: systemPrompt,
                options: options
            )
            let variant = try store.chats.createVariant(messageID: assistant.id, generationSessionID: session.id)
            try store.generation.linkVariant(generationID: session.id, variantID: variant.id)
            variantID = variant.id
            sessionID = session.id
            activeGenerationID = generationID

            reloadMessages()

            let request = GenerateRequest(
                generationID: generationID,
                modelID: modelID,
                prompt: modelPrompt,
                systemPrompt: systemPrompt,
                history: history,
                options: options
            )

            var streamedContent = ""
            var sawFirstToken = false
            var sawTerminal = false
            var finalMetrics: RuntimeMetrics?

            for try await event in try runtimeClient.generate(request) {
                switch event.type {
                case .token:
                    guard let token = event.tokenText else { break }
                    try store.chats.appendToken(to: variant.id, token: token)
                    if !sawFirstToken {
                        sawFirstToken = true
                        try? store.generation.markFirstToken(generationID: session.id)
                    }
                    streamedContent += token
                    updateMessage(id: assistant.id, content: streamedContent, status: .pending)

                case .metrics:
                    finalMetrics = event.metrics

                case .generationCompleted:
                    sawTerminal = true
                    finalMetrics = event.metrics ?? finalMetrics
                    try store.chats.completeVariant(variant.id)
                    try store.generation.completeGeneration(
                        generationID: session.id,
                        metrics: storedMetrics(from: finalMetrics)
                    )
                    updateMessage(id: assistant.id, content: streamedContent, status: .completed)

                case .generationCancelled:
                    sawTerminal = true
                    try store.chats.markVariantCancelled(variant.id)
                    try store.generation.cancelGeneration(
                        generationID: session.id,
                        metrics: storedMetrics(from: event.metrics)
                    )
                    updateMessage(id: assistant.id, content: streamedContent, status: .cancelled)

                case .generationFailed:
                    sawTerminal = true
                    let reason = event.error?.message ?? "Generation failed."
                    try store.chats.markVariantFailed(variant.id, reason: reason)
                    try store.generation.failGeneration(
                        generationID: session.id,
                        errorSummary: reason,
                        diagnosticEventID: nil
                    )
                    errorMessage = reason
                    updateMessage(id: assistant.id, content: streamedContent, status: .failed)

                case .queued, .modelLoading, .modelLoaded, .generationStarted:
                    break
                }
            }

            // The stream finished without a terminal event; never leave the
            // assistant message stuck rendering as "still generating".
            if !sawTerminal {
                let reason = "Generation ended unexpectedly."
                try store.chats.markVariantInterrupted(variant.id, reason: reason)
                try store.generation.interruptGeneration(
                    generationID: session.id,
                    reason: reason,
                    diagnosticEventID: nil
                )
                updateMessage(id: assistant.id, content: streamedContent, status: .interrupted)
            }
        } catch {
            errorMessage = error.localizedDescription
            if let variantID, let sessionID {
                let reason = error.localizedDescription
                try? store.chats.markVariantFailed(variantID, reason: reason)
                try? store.generation.failGeneration(
                    generationID: sessionID,
                    errorSummary: reason,
                    diagnosticEventID: nil
                )
            }
        }

        reloadMessages()
    }

    private func performLegalOneShotSend(
        prompt: String,
        modelPrompt: String,
        displayContent: String,
        modelID: ModelID?,
        route: ModelRoute,
        systemPrompt: String?,
        options: GenerationOptions
    ) async throws {
        let chatID = try ensureSelectedChat(titleHint: prompt).id
        let priorAssistantDraft = latestAssistantDraft()

        _ = try store.chats.appendUserMessage(chatID: chatID, content: displayContent)
        let assistant = try store.chats.createAssistantMessageShell(chatID: chatID)
        let generationID = GenerationID()
        activeGenerationID = generationID

        let session = try store.generation.createGenerationSession(
            chatID: chatID,
            messageID: assistant.id,
            modelID: modelID?.rawValue.uuidString,
            prompt: modelPrompt,
            systemPrompt: systemPrompt,
            options: options
        )
        let variant = try store.chats.createVariant(messageID: assistant.id, generationSessionID: session.id)
        try store.generation.linkVariant(generationID: session.id, variantID: variant.id)
        reloadMessages()

        do {
            let result = try await legalWorkflowOutput(
                prompt: modelPrompt,
                chatID: chatID,
                modelID: modelID,
                generationID: generationID,
                route: route,
                systemPrompt: systemPrompt,
                options: options,
                priorAssistantDraft: priorAssistantDraft
            )
            try store.chats.appendToken(to: variant.id, token: result.output)
            try store.chats.completeVariant(variant.id)
            try store.generation.completeGeneration(generationID: session.id)
            updateMessage(id: assistant.id, content: result.output, status: .completed)
            recordLegalResearchAudit(
                route: route,
                modelID: modelID,
                generationSessionID: session.id,
                queryTerms: result.queryTerms,
                authorities: result.authorities,
                verification: result.verification,
                relatedResearchSessionID: result.researchSessionID
            )
        } catch GenerationStreamError.cancelled {
            // A user cancellation is not a failure — record it as cancelled.
            try? store.chats.markVariantCancelled(variant.id)
            try? store.generation.cancelGeneration(generationID: session.id)
            updateMessage(id: assistant.id, content: "", status: .cancelled)
        } catch {
            let reason = error.localizedDescription
            try? store.chats.markVariantFailed(variant.id, reason: reason)
            try? store.generation.failGeneration(
                generationID: session.id,
                errorSummary: reason,
                diagnosticEventID: nil
            )
            updateMessage(id: assistant.id, content: "", status: .failed)
            throw error
        }
    }

    private struct LegalWorkflowResult {
        var output: String
        var queryTerms: [String]
        var authorities: [LegalAuthority]
        var verification: LegalVerificationReport?
        var researchSessionID: String?
    }

    private func legalWorkflowOutput(
        prompt: String,
        chatID: String,
        modelID: ModelID?,
        generationID: GenerationID,
        route: ModelRoute,
        systemPrompt: String?,
        options: GenerationOptions,
        priorAssistantDraft: String?
    ) async throws -> LegalWorkflowResult {
        switch route.mode {
        case .legalVerify:
            let packet = latestLegalSourcePacket(chatID: chatID)
            let report = LegalCitationVerifier.verify(answer: prompt, authorities: packet.authorities)
            let preface = packet.authorities.isEmpty
                ? "No source packet is available for this chat. Run `/research` in a matter chat first, or paste source-supported text with citations for a limited citation check.\n\n"
                : "Verified against the latest source packet\(packet.researchSessionID.map { " (research session \($0))" } ?? "").\n\n"
            return LegalWorkflowResult(
                output: preface + LegalCitationVerifier.markdownReport(report),
                queryTerms: packet.queryTerms,
                authorities: packet.authorities,
                verification: report,
                researchSessionID: packet.researchSessionID
            )

        case .legalResearch, .legalQA:
            return try await legalResearchOutput(
                prompt: prompt,
                chatID: chatID,
                modelID: modelID,
                generationID: generationID,
                route: route,
                systemPrompt: systemPrompt,
                options: options
            )

        case .legalCritique:
            let draft = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (priorAssistantDraft ?? "")
                : prompt
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return LegalWorkflowResult(
                    output: "Paste a draft to critique, or run `/critique` after an assistant draft.",
                    queryTerms: [],
                    authorities: [],
                    verification: nil,
                    researchSessionID: nil
                )
            }
            guard let modelID else {
                return LegalWorkflowResult(
                    output: "Load or register a local MLX model in the Models tab before running `/critique`.",
                    queryTerms: [],
                    authorities: [],
                    verification: nil,
                    researchSessionID: nil
                )
            }
            let packet = latestLegalSourcePacket(chatID: chatID)
            let critiquePrompt = LegalResearchPromptBuilder.buildCritiquePrompt(
                draft: draft,
                authorities: packet.authorities
            )
            let request = GenerateRequest(
                generationID: generationID,
                modelID: modelID,
                prompt: critiquePrompt,
                systemPrompt: systemPrompt,
                options: options
            )
            let output = ReasoningContent.answer(from: try await runtimeClient.collectGeneratedText(request))
            return LegalWorkflowResult(
                output: output,
                queryTerms: packet.queryTerms,
                authorities: packet.authorities,
                verification: nil,
                researchSessionID: packet.researchSessionID
            )

        case .drafting, .generalQA:
            guard let modelID else {
                return LegalWorkflowResult(
                    output: "Load or register a local MLX model in the Models tab.",
                    queryTerms: [],
                    authorities: [],
                    verification: nil,
                    researchSessionID: nil
                )
            }
            let request = GenerateRequest(
                generationID: generationID,
                modelID: modelID,
                prompt: prompt,
                systemPrompt: systemPrompt,
                options: options
            )
            let output = ReasoningContent.answer(from: try await runtimeClient.collectGeneratedText(request))
            return LegalWorkflowResult(output: output, queryTerms: [], authorities: [], verification: nil, researchSessionID: nil)
        }
    }

    private func legalResearchOutput(
        prompt: String,
        chatID: String,
        modelID: ModelID?,
        generationID: GenerationID,
        route: ModelRoute,
        systemPrompt: String?,
        options: GenerationOptions
    ) async throws -> LegalWorkflowResult {
        let classification = classificationApplyingChatJurisdiction(
            classificationApplyingMatterScope(LegalQueryClassifier.classify(prompt)),
            prompt: prompt
        )
        if route.requiresJurisdiction, classification.needsJurisdictionForAuthority {
            let message = """
            I need the jurisdiction before I can give source-grounded legal authority. Please specify the state, federal circuit, court, or other governing jurisdiction. If you only want a general non-authoritative overview, use `/draft` or ask for a general overview.
            """
            return LegalWorkflowResult(output: message, queryTerms: [], authorities: [], verification: nil, researchSessionID: nil)
        }

        guard route.requiresCourtListener else {
            let message = """
            This legal route is configured not to use CourtListener. Because ungrounded law is disabled, I cannot treat model memory as legal authority. Enable CourtListener or use `/draft` for attorney-editable drafting that flags the need for research.
            """
            return LegalWorkflowResult(output: message, queryTerms: [], authorities: [], verification: nil, researchSessionID: nil)
        }

        guard let modelID else {
            let message = "Load or register a local MLX model in the Models tab before running source-grounded legal research."
            return LegalWorkflowResult(output: message, queryTerms: [], authorities: [], verification: nil, researchSessionID: nil)
        }

        let retrieval = try await retrieveAuthorities(for: classification, matterID: scopedMatterID)
        let ranked = LegalAuthorityRanker.rank(retrieval.authorities, for: classification)
        let authorities = ranked.map(\.authority)
        let packet = LegalSourcePacket(
            queryTerms: retrieval.queryTerms,
            authorities: authorities,
            researchSessionID: retrieval.researchSessionID
        )
        lastLegalPacketsByChatID[chatID] = packet
        guard !authorities.isEmpty else {
            let message = """
            CourtListener did not return authorities for this query. I cannot provide a source-grounded legal answer from model memory alone.

            Search terms used:
            \(retrieval.queryTerms.map { "- \($0)" }.joined(separator: "\n"))
            """
            return LegalWorkflowResult(
                output: message,
                queryTerms: retrieval.queryTerms,
                authorities: [],
                verification: nil,
                researchSessionID: retrieval.researchSessionID
            )
        }

        let answerPrompt = LegalResearchPromptBuilder.buildAnswerPrompt(
            question: prompt,
            classification: classification,
            rankedAuthorities: ranked
        )
        let request = GenerateRequest(
            generationID: generationID,
            modelID: modelID,
            prompt: answerPrompt,
            systemPrompt: systemPrompt,
            options: options
        )
        var output = ReasoningContent.answer(from: try await runtimeClient.collectGeneratedText(request))
        let verification = legalConfiguration.verifyCitations
            ? LegalCitationVerifier.verify(
                answer: output,
                authorities: authorities,
                expectedJurisdiction: classification.jurisdiction
            )
            : nil

        if let verification, !verification.passed {
            // Gate on severity: a fabricated/unsupported citation or quote (and a
            // jurisdiction mismatch when this route requires jurisdiction) is a hard
            // failure — quarantine the answer behind a banner so it can never read as
            // verified law. requireCitations additionally demands at least one cite
            // actually supported by the retrieved packet. Soft issues (e.g. an
            // uncited proposition) only append the advisory report.
            if Self.hasHardVerificationFailure(verification, route: route)
                || (route.requiresCitations && !Self.hasSupportedCitation(verification)) {
                output = Self.unverifiedDraftBanner + output + "\n\n---\n\n" + LegalCitationVerifier.markdownReport(verification)
            } else {
                output += "\n\n---\n\n" + LegalCitationVerifier.markdownReport(verification)
            }
        }

        return LegalWorkflowResult(
            output: output,
            queryTerms: retrieval.queryTerms,
            authorities: authorities,
            verification: verification,
            researchSessionID: retrieval.researchSessionID
        )
    }

    /// Banner prepended to a legal answer whose citations failed verification, so
    /// the user cannot mistake it for verified good law.
    static let unverifiedDraftBanner = """
    > ⚠️ **UNVERIFIED DRAFT — DO NOT RELY.** Automated citation verification found unsupported or mismatched authority below. Independently verify every citation, quotation, and holding before use.

    """

    /// A hard verification failure: a fabricated/unsupported citation or quotation,
    /// or — when the route requires jurisdiction — a jurisdiction mismatch.
    static func hasHardVerificationFailure(_ report: LegalVerificationReport, route: ModelRoute) -> Bool {
        report.issues.contains { issue in
            switch issue.kind {
            case .unsupportedCitation, .unsupportedQuote:
                return true
            case .jurisdictionMismatch:
                return route.requiresJurisdiction
            case .missingCitation, .noRetrievedAuthorities:
                return false
            }
        }
    }

    /// True when at least one detected citation is actually supported by the
    /// retrieved authority packet (i.e. not flagged as unsupported).
    static func hasSupportedCitation(_ report: LegalVerificationReport) -> Bool {
        guard !report.citedStrings.isEmpty else { return false }
        let unsupported = Set(report.issues.filter { $0.kind == .unsupportedCitation }.compactMap { $0.excerpt })
        return report.citedStrings.contains { !unsupported.contains($0) }
    }

    private func retrieveAuthorities(
        for classification: LegalQueryClassification,
        matterID: String?
    ) async throws -> (queryTerms: [String], authorities: [LegalAuthority], researchSessionID: String?) {
        let primaryRequest = courtListenerRequest(for: classification, adverse: false)
        var requests = [(request: primaryRequest, adverse: false)]
        if classification.adverseAuthorityRequested {
            requests.append((courtListenerRequest(for: classification, adverse: true), true))
        }

        let researchSession = try matterID.map {
            try createAutomaticResearchSession(
                matterID: $0,
                classification: classification,
                queryCount: requests.count
            )
        }

        let queryTerms = requests.map(\.request.query)
        var authorities: [LegalAuthority] = []
        var anySuccess = false
        var lastError: Error?

        for (index, item) in requests.enumerated() {
            let queryRecord = try researchSession.map {
                try store.research.createQuery(
                    researchSessionID: $0.id,
                    queryText: item.request.query,
                    queryIndex: index,
                    courtFilter: item.request.courtIDs.joined(separator: ","),
                    dateFiledAfter: Self.parseCourtListenerDate(item.request.dateFiledAfter),
                    dateFiledBefore: Self.parseCourtListenerDate(item.request.dateFiledBefore),
                    status: .running
                )
            }

            do {
                let response = try await courtListenerClient.searchOpinions(
                    item.request,
                    relatedResearchSessionID: researchSession?.id
                )
                authorities += LegalAuthorityNormalizer.normalize(response)
                if let queryRecord {
                    for dto in response.results {
                        _ = try? store.research.insertResult(
                            makeResultRecord(
                                dto,
                                queryID: queryRecord.id,
                                reviewState: .unreviewed
                            )
                        )
                    }
                    try? store.research.updateQueryExecution(
                        queryID: queryRecord.id,
                        status: .completed,
                        resultCount: response.count,
                        nextURL: response.next,
                        executedAt: Date(),
                        requestMetadataJSON: requestMeta(item.request),
                        responseMetadataJSON: Self.responseMeta(response)
                    )
                }
                anySuccess = true
            } catch {
                lastError = error
                if let queryRecord {
                    try? store.research.updateQueryExecution(
                        queryID: queryRecord.id,
                        status: .failed,
                        executedAt: Date(),
                        requestMetadataJSON: requestMeta(item.request),
                        errorMessage: error.localizedDescription
                    )
                }
                if !item.adverse {
                    break
                }
            }
        }

        if let researchSession {
            let status: ResearchSessionStatus = anySuccess ? .resultsReady : .failed
            try? store.research.updateSessionStatus(
                sessionID: researchSession.id,
                status: status,
                completedAt: anySuccess ? nil : Date()
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: researchSession.matterID,
                eventType: anySuccess ? "courtlistener_search_completed" : "courtlistener_search_failed",
                actor: "network",
                summary: anySuccess ? "Automatic CourtListener source packet completed" : "Automatic CourtListener source packet failed",
                relatedTable: "research_sessions",
                relatedID: researchSession.id
            )
        }

        if !anySuccess, let lastError {
            throw lastError
        }

        var seen = Set<String>()
        let deduped = authorities.filter { authority in
            if seen.contains(authority.id) { return false }
            seen.insert(authority.id)
            return true
        }
        return (queryTerms, deduped, researchSession?.id)
    }

    private func courtListenerRequest(for classification: LegalQueryClassification, adverse: Bool) -> CourtListenerSearchRequest {
        CourtListenerSearchRequest(
            query: courtListenerQuery(for: classification, adverse: adverse),
            orderBy: "score desc",
            courtIDs: classification.courtIDs,
            dateFiledAfter: classification.dateFiledAfter,
            dateFiledBefore: classification.dateFiledBefore,
            citation: Self.courtListenerCitationParameter(classification.citationLookup)
        )
    }

    private static func courtListenerCitationParameter(_ citation: String?) -> String? {
        guard let citation else { return nil }
        let lower = citation.lowercased()
        if lower.contains("§") || lower.contains(" v. ") || lower.contains(" v ") {
            return nil
        }
        return citation
    }

    private func courtListenerQuery(for classification: LegalQueryClassification, adverse: Bool) -> String {
        var terms: [String] = []
        if let citation = classification.citationLookup {
            terms.append(citation)
        } else {
            terms.append(classification.legalIssue)
        }
        if let jurisdiction = classification.jurisdiction, classification.courtIDs.isEmpty {
            terms.append(jurisdiction)
        }
        if let posture = classification.proceduralPosture {
            terms.append(posture)
        }
        if classification.bindingAuthorityRequired {
            terms.append("binding controlling")
        }
        if adverse {
            terms.append("adverse limiting distinguished rejected")
        }
        return terms
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func createAutomaticResearchSession(
        matterID: String,
        classification: LegalQueryClassification,
        queryCount: Int
    ) throws -> ResearchSessionRecord {
        let title = "Chat research: \(classification.legalIssue.prefix(80))"
        let session = try store.research.createSession(
            matterID: matterID,
            title: String(title),
            issueText: classification.legalIssue,
            jurisdiction: classification.jurisdiction ?? "Unspecified",
            preferredCourts: classification.courtIDs,
            dateRangeStart: Self.parseCourtListenerDate(classification.dateFiledAfter),
            dateRangeEnd: Self.parseCourtListenerDate(classification.dateFiledBefore),
            status: .running
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: "courtlistener_search_started",
            actor: "runtime",
            summary: "Started automatic CourtListener source packet (\(queryCount) quer\(queryCount == 1 ? "y" : "ies"))",
            relatedTable: "research_sessions",
            relatedID: session.id
        )
        return session
    }

    private func latestLegalSourcePacket(chatID: String) -> LegalSourcePacket {
        if let packet = lastLegalPacketsByChatID[chatID] {
            return packet
        }
        return latestChatSourcePacket(chatID: chatID)
            ?? LegalSourcePacket(queryTerms: [], authorities: [], researchSessionID: nil)
    }

    private func latestChatSourcePacket(chatID: String) -> LegalSourcePacket? {
        let sessions = (try? store.generation.fetchGenerationSessions(chatID: chatID, limit: nil)) ?? []
        for session in sessions {
            let audits = (try? store.auditEvents.fetchEvents(
                relatedTable: "generation_sessions",
                relatedID: session.id,
                eventType: "legal_model_route"
            )) ?? []
            for audit in audits {
                guard let metadata = Self.legalResearchAuditMetadata(from: audit.metadataJSON) else { continue }
                if let researchSessionID = metadata.relatedResearchSessionID {
                    let packet = sourcePacket(
                        researchSessionID: researchSessionID,
                        fallbackQueryTerms: metadata.courtListenerQueryTerms
                    )
                    if !packet.authorities.isEmpty {
                        return packet
                    }
                    if metadata.blocksOlderSourcePacket {
                        return packet
                    }
                }
                if let authorities = metadata.sourcePacketAuthorities {
                    return LegalSourcePacket(
                        queryTerms: metadata.courtListenerQueryTerms,
                        authorities: authorities,
                        researchSessionID: metadata.relatedResearchSessionID
                    )
                }
                if metadata.blocksOlderSourcePacket {
                    return LegalSourcePacket(
                        queryTerms: metadata.courtListenerQueryTerms,
                        authorities: [],
                        researchSessionID: metadata.relatedResearchSessionID
                    )
                }
            }
        }
        return nil
    }

    private func sourcePacket(
        researchSessionID: String,
        fallbackQueryTerms: [String] = []
    ) -> LegalSourcePacket {
        let queries = (try? store.research.fetchQueries(sessionID: researchSessionID)) ?? []
        var authorities: [LegalAuthority] = []
        var queryTerms: [String] = []
        for query in queries.sorted(by: { $0.queryIndex < $1.queryIndex }) {
            queryTerms.append(query.queryText)
            let results = (try? store.research.fetchResults(queryID: query.id)) ?? []
            authorities += results.map(Self.legalAuthority(from:))
        }
        return LegalSourcePacket(
            queryTerms: queryTerms.isEmpty ? fallbackQueryTerms : queryTerms,
            authorities: authorities,
            researchSessionID: researchSessionID
        )
    }

    private var scopedMatterID: String? {
        if case let .matter(id) = scope {
            return id
        }
        return nil
    }

    private func classificationApplyingMatterScope(
        _ classification: LegalQueryClassification
    ) -> LegalQueryClassification {
        guard let matterScope = matterJurisdictionScope() else {
            return classification
        }
        var scoped = classification
        let canApplyMatterJurisdiction = scoped.jurisdiction == nil
            || Self.sameJurisdiction(scoped.jurisdiction, matterScope.jurisdictionName)

        if scoped.needsJurisdictionForAuthority {
            scoped.jurisdiction = matterScope.jurisdictionName
        }
        if canApplyMatterJurisdiction {
            scoped.jurisdictionContext = matterScope.modelContext
            if scoped.courtIDs.isEmpty {
                scoped.courtIDs = matterScope.courtListenerIDs
            }
        }
        return scoped
    }

    private func matterJurisdictionScope() -> JurisdictionAuthorityScope? {
        guard let matterID = scopedMatterID,
              let matter = try? store.matters.fetchMatter(id: matterID)
        else {
            return nil
        }
        return JurisdictionCatalog.shared.authorityScope(
            jurisdiction: matter.jurisdiction,
            court: matter.court
        )
    }

    /// Applies the global chat's jurisdiction selection — or, when set to
    /// auto-detect, a jurisdiction inferred from the prompt — so CourtListener
    /// research is actually bounded. No-op for matter chats, which are already
    /// bound by `classificationApplyingMatterScope`.
    private func classificationApplyingChatJurisdiction(
        _ classification: LegalQueryClassification,
        prompt: String
    ) -> LegalQueryClassification {
        guard scopedMatterID == nil else { return classification }

        let isExplicit = !jurisdictionOverrideID.isEmpty
        let option: JurisdictionOption?
        if isExplicit {
            option = JurisdictionCatalog.shared.option(id: jurisdictionOverrideID)
        } else if classification.jurisdiction == nil {
            option = inferredJurisdictionOption(from: prompt)
        } else {
            option = nil
        }
        guard let option else { return classification }

        let scope = JurisdictionCatalog.shared.authorityScope(for: option)
        var scoped = classification
        if isExplicit {
            // A deliberate selection hard-bounds research to that jurisdiction.
            scoped.jurisdiction = scope.jurisdictionName
            scoped.jurisdictionContext = scope.modelContext
            var ids = scope.courtListenerIDs
            // Optionally fold in the federal courts that apply this state's law.
            if includeRelatedFederal, option.system == .state, let state = option.state {
                ids += JurisdictionCatalog.shared.relatedFederalCourtIDs(forState: state)
            }
            scoped.courtIDs = Self.uniqued(ids)
        } else {
            // An inferred jurisdiction only fills gaps the classifier left, so an
            // explicit jurisdiction named in the prompt still wins.
            if scoped.needsJurisdictionForAuthority {
                scoped.jurisdiction = scope.jurisdictionName
            }
            scoped.jurisdictionContext = scope.modelContext
            if scoped.courtIDs.isEmpty {
                scoped.courtIDs = scope.courtListenerIDs
            }
        }
        return scoped
    }

    /// Best-effort detection of a jurisdiction named in the prompt across every
    /// state aggregate plus the federal courts — broader than the classifier's
    /// built-in shortlist, used only as the auto-detect fallback.
    private func inferredJurisdictionOption(from prompt: String) -> JurisdictionOption? {
        let lower = prompt.lowercased()
        func mentions(_ needle: String) -> Bool {
            guard !needle.isEmpty else { return false }
            let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: needle.lowercased()) + "([^a-z]|$)"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
        // Longest state name first so e.g. "West Virginia" isn't captured by the
        // "Virginia" aggregate (substring), or "North Dakota" by "Dakota".
        let stateOptions = topLevelJurisdictions
            .filter { $0.state != nil }
            .sorted { ($0.state?.count ?? 0) > ($1.state?.count ?? 0) }
        if let state = stateOptions.first(where: { mentions($0.state ?? "") }) {
            return state
        }
        if lower.range(
            of: #"(^|[^a-z])(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|federal|d\.?c\.?)\s+circuit"#,
            options: .regularExpression
        ) != nil || mentions("federal court") || mentions("federal courts") {
            return topLevelJurisdictions.first { $0.id == "federal-courts" }
        }
        return nil
    }

    private static func makeTopLevelJurisdictions() -> [JurisdictionOption] {
        JurisdictionCatalog.shared.options
            .filter { $0.level == .jurisdiction }
            .sorted { lhs, rhs in
                if (lhs.id == "federal-courts") != (rhs.id == "federal-courts") {
                    return lhs.id == "federal-courts"
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func makeFederalCircuits() -> [JurisdictionOption] {
        let order = ["ca1", "ca2", "ca3", "ca4", "ca5", "ca6", "ca7", "ca8", "ca9", "ca10", "ca11", "cadc", "cafc"]
        var seen = Set<String>()
        var circuits: [JurisdictionOption] = []
        for option in JurisdictionCatalog.shared.options where option.level == .federalAppellate {
            let key = option.courtListenerIDs.first ?? option.id
            guard seen.insert(key).inserted else { continue }
            circuits.append(option)
        }
        return circuits.sorted { lhs, rhs in
            let lhsRank = order.firstIndex(of: lhs.courtListenerIDs.first ?? "") ?? Int.max
            let rhsRank = order.firstIndex(of: rhs.courtListenerIDs.first ?? "") ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Maximum characters of prior conversation replayed as context, keeping the
    /// most recent turns within a budget so long chats don't overflow the window.
    static let historyCharBudget = 16_000

    /// Prior turns to replay (oldest→newest), selecting the most recent within the
    /// budget. Assistant chain-of-thought is stripped so only answers are fed back.
    static func conversationHistory(from messages: [ChatMessage], budget: Int) -> [GenerateRequest.Turn] {
        var turns: [GenerateRequest.Turn] = []
        var used = 0
        for message in messages.reversed() {
            let role: GenerateRequest.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: continue
            }
            let raw = message.role == .assistant
                ? ReasoningContent.answer(from: message.content)
                : message.content
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if !turns.isEmpty, used + content.count > budget { break }
            turns.append(GenerateRequest.Turn(role: role, content: content))
            used += content.count
        }
        return turns.reversed()
    }

    private static func sameJurisdiction(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return normalizedJurisdiction(lhs) == normalizedJurisdiction(rhs)
    }

    private static func normalizedJurisdiction(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func latestAssistantDraft() -> String? {
        messages.reversed().first {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.content
    }

    private func makeResultRecord(
        _ dto: CourtListenerSearchResultDTO,
        queryID: String,
        reviewState: ResearchResultReviewState = .unreviewed
    ) -> ResearchResultRecord {
        let citationJSON = (try? JSONEncoder().encode(dto.citation))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ResearchResultRecord(
            researchQueryID: queryID,
            clusterID: dto.clusterID.map(String.init),
            opinionID: dto.opinions.first?.id.map(String.init),
            caseName: dto.caseName ?? dto.caseNameFull ?? "Untitled case",
            caseNameFull: dto.caseNameFull,
            citationJSON: citationJSON,
            preferredCitation: CourtListenerMapper.preferredCitation(for: dto),
            court: dto.court,
            courtID: dto.courtID,
            dateFiled: Self.parseCourtListenerDate(dto.dateFiled),
            docketNumber: dto.docketNumber,
            snippet: dto.opinions.first?.snippet,
            absoluteURL: dto.absoluteURL,
            reviewState: reviewState.rawValue,
            rawResultJSON: dto.rawResultJSON
        )
    }

    private static func legalAuthority(from result: ResearchResultRecord) -> LegalAuthority {
        let citations = (try? JSONDecoder().decode([String].self, from: Data(result.citationJSON.utf8))) ?? []
        let dateFiled = result.dateFiled.map(Self.courtListenerDateFormatter.string(from:))
        var authority = LegalAuthority(
            id: result.opinionID.map { "courtlistener:opinion:\($0)" }
                ?? result.clusterID.map { "courtlistener:cluster:\($0)" }
                ?? "research_result:\(result.id)",
            authorityType: .case,
            caseName: result.caseName,
            citation: result.preferredCitation,
            citations: citations,
            court: result.court,
            courtID: result.courtID,
            jurisdiction: result.courtID ?? result.court,
            dateFiled: dateFiled,
            url: CourtListenerMapper.displayURL(for: CourtListenerSearchResultDTO(absoluteURL: result.absoluteURL))?.absoluteString ?? result.absoluteURL,
            snippet: result.snippet,
            text: result.snippet,
            clusterId: result.clusterID,
            opinionId: result.opinionID,
            docketNumber: result.docketNumber
        )
        if let rawAuthority = legalAuthorityFromRawResultJSON(result.rawResultJSON) {
            authority.citation = authority.citation ?? rawAuthority.citation
            authority.citations = Array(Set(authority.citations + rawAuthority.citations)).sorted()
            authority.court = authority.court ?? rawAuthority.court
            authority.courtID = authority.courtID ?? rawAuthority.courtID
            authority.jurisdiction = authority.jurisdiction ?? rawAuthority.jurisdiction
            authority.dateFiled = authority.dateFiled ?? rawAuthority.dateFiled
            authority.precedentialStatus = authority.precedentialStatus ?? rawAuthority.precedentialStatus
            authority.url = authority.url ?? rawAuthority.url
            authority.snippet = rawAuthority.snippet ?? authority.snippet
            authority.text = rawAuthority.text ?? authority.text
            authority.clusterId = authority.clusterId ?? rawAuthority.clusterId
            authority.opinionId = authority.opinionId ?? rawAuthority.opinionId
            authority.docketNumber = authority.docketNumber ?? rawAuthority.docketNumber
        }
        return authority
    }

    private static func legalAuthorityFromRawResultJSON(_ rawResultJSON: String) -> LegalAuthority? {
        let trimmed = rawResultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}",
              let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(CourtListenerSearchResultDTO.self, from: data)
        else {
            return nil
        }
        let hasUsableContent = dto.caseName != nil
            || dto.caseNameFull != nil
            || !dto.citation.isEmpty
            || !dto.opinions.isEmpty
            || dto.syllabus != nil
            || dto.proceduralHistory != nil
            || dto.posture != nil
        guard hasUsableContent else { return nil }
        return LegalAuthorityNormalizer.normalize(dto)
    }

    private static func parseCourtListenerDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return courtListenerDateFormatter.date(from: String(string.prefix(10)))
    }

    private static let courtListenerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func requestMeta(_ request: CourtListenerSearchRequest) -> String? {
        // Redact the privileged query term and citation to fingerprints unless
        // query-term logging is enabled, matching the network-log redaction.
        let logTerms = legalConfiguration.logPrivilegedQueryTerms
        var dict: [String: String] = [
            "q": logTerms ? request.query : "#\(Self.fingerprint(request.query))",
            "type": "o",
            "highlight": String(request.highlight)
        ]
        if !request.courtIDs.isEmpty {
            dict["court"] = request.courtIDs.joined(separator: ",")
        }
        if let after = request.dateFiledAfter {
            dict["filed_after"] = after
        }
        if let before = request.dateFiledBefore {
            dict["filed_before"] = before
        }
        if let citation = request.citation {
            dict["citation"] = logTerms ? citation : "#\(Self.fingerprint(citation))"
        }
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func responseMeta(_ response: CourtListenerSearchResponse) -> String? {
        let dict = ["count": String(response.count), "has_next": String(response.next != nil)]
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legalResearchAuditMetadata(from metadataJSON: String?) -> LegalResearchAuditMetadata? {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(LegalResearchAuditMetadata.self, from: data)
    }

    private func recordLegalResearchAudit(
        route: ModelRoute,
        modelID: ModelID?,
        generationSessionID: String,
        queryTerms: [String],
        authorities: [LegalAuthority],
        verification: LegalVerificationReport?,
        relatedResearchSessionID: String?
    ) {
        let metadata = LegalResearchAuditMetadata(
            route: route.mode.rawValue,
            selectedModelID: modelID?.rawValue.uuidString,
            configuredModelIdentifier: route.modelIdentifier,
            preset: route.options.preset.rawValue,
            courtListenerUsed: !queryTerms.isEmpty,
            courtListenerQueryTerms: legalConfiguration.logPrivilegedQueryTerms ? queryTerms : [],
            courtListenerQueryFingerprints: queryTerms.map(Self.fingerprint),
            retrievedAuthorityIDs: authorities.map(\.id),
            citationsIncluded: verification?.citedStrings ?? [],
            verificationPassed: verification?.passed,
            warnings: verification?.issues.map(\.message) ?? [],
            relatedResearchSessionID: relatedResearchSessionID,
            sourcePacketAuthorities: relatedResearchSessionID == nil ? Self.auditSafeSourcePacket(authorities) : nil
        )
        let metadataJSON = (try? JSONEncoder().encode(metadata)).flatMap { String(data: $0, encoding: .utf8) }
        _ = try? store.auditEvents.recordEvent(
            matterID: scopedMatterID,
            eventType: "legal_model_route",
            actor: "runtime",
            summary: "Routed \(route.mode.rawValue) to \(route.modelIdentifier)",
            relatedTable: "generation_sessions",
            relatedID: generationSessionID,
            metadataJSON: metadataJSON
        )
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func auditSafeSourcePacket(_ authorities: [LegalAuthority]) -> [LegalAuthority] {
        authorities.map { authority in
            var copy = authority
            copy.snippet = nil
            copy.text = nil
            return copy
        }
    }

    // MARK: - Helpers

    /// Formats attachments as a grounding block prepended to the model prompt.
    private static func attachmentsBlock(_ attachments: [ChatAttachmentContext]) -> String {
        var lines = ["The user attached the following file(s). Use their contents as context for the question."]
        for attachment in attachments {
            lines.append("")
            lines.append("===== \(attachment.name) =====")
            lines.append(attachment.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the selected chat, creating one lazily if none is selected. When a
    /// chat is created here, `titleHint` (the first user message) becomes its title
    /// so the history sidebar shows something meaningful instead of "New Chat".
    private func ensureSelectedChat(titleHint: String? = nil) throws -> ChatSummary {
        if let selectedChatID, let existing = chats.first(where: { $0.id == selectedChatID }) {
            return existing
        }
        let title = titleHint.map(Self.derivedTitle(from:)) ?? "New Chat"
        return try createChat(title: title)
    }

    private func updateMessage(id: String, content: String, status: MessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            reloadMessages()
            return
        }
        messages[index].content = content
        messages[index].status = status
    }

    private func storedMetrics(from metrics: RuntimeMetrics?) -> StoredRuntimeMetrics {
        guard let metrics else { return StoredRuntimeMetrics() }
        return StoredRuntimeMetrics(
            loadTimeMs: metrics.loadTimeMs,
            firstTokenLatencyMs: metrics.firstTokenLatencyMs,
            tokensPerSecond: metrics.tokensPerSecond,
            cancellationLatencyMs: metrics.cancellationLatencyMs,
            peakMemoryMb: metrics.peakMemoryMb,
            generatedTokenCount: metrics.generatedTokenCount
        )
    }
}

private struct LegalResearchAuditMetadata: Codable {
    let route: String
    let selectedModelID: String?
    let configuredModelIdentifier: String
    let preset: String
    let courtListenerUsed: Bool
    let courtListenerQueryTerms: [String]
    let courtListenerQueryFingerprints: [String]
    let retrievedAuthorityIDs: [String]
    let citationsIncluded: [String]
    let verificationPassed: Bool?
    let warnings: [String]
    let relatedResearchSessionID: String?
    let sourcePacketAuthorities: [LegalAuthority]?

    var blocksOlderSourcePacket: Bool {
        switch route {
        case ModelRouteMode.legalQA.rawValue,
             ModelRouteMode.legalResearch.rawValue,
             ModelRouteMode.legalVerify.rawValue:
            courtListenerUsed || relatedResearchSessionID != nil || sourcePacketAuthorities != nil
        default:
            false
        }
    }
}

private extension ModelRoute {
    var usesOneShotLegalWorkflow: Bool {
        switch mode {
        case .legalQA, .legalResearch, .legalVerify, .legalCritique:
            true
        case .drafting, .generalQA:
            false
        }
    }
}

private struct LegalSourcePacket {
    var queryTerms: [String]
    var authorities: [LegalAuthority]
    var researchSessionID: String?
}
