import Combine
import Foundation
import SupraCore
import SupraDocuments
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
    /// Generation options for the SELECTED chat. Seeded from the app-wide default
    /// (Settings → Generation Defaults) and overridable per chat via the status-bar
    /// popover; a customized chat keeps its value (persisted) until changed again or
    /// deleted, independent of later changes to the global default.
    @Published public private(set) var activeChatOptions = GenerationOptions()
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isGenerating = false
    @Published public private(set) var errorMessage: String?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    private let scope: ChatScope
    /// Grounds matter chats in the matter's own documents (folder inventories +
    /// retrieval). nil for global chats, which have no document collection.
    private let documentGrounding: MatterChatDocumentGrounding?
    private let router: ModelRouter
    private let legalConfiguration: LegalModelConfiguration
    private let courtListenerClient: any CourtListenerClientProtocol
    /// Pluggable statutory-source orchestration (Open Legal Codes today; govinfo / Openlaws /
    /// MCP-backed sources later). Best-effort and lowest-weight — it supplements case law for
    /// statutory questions and never blocks the answer if a source is unavailable.
    private let statutoryOrchestrator: StatutorySourceOrchestrator
    /// Provisions to request from the statutory tier per query.
    private static let maxStatutoryProvisions = 4
    /// Pluggable legal-developments tracking (Federal Register today; OpenStates / LegiScan /
    /// Regulations.gov next). NON-citable — surfaced as a separate "Developments" section.
    private let developmentsOrchestrator: LegalDevelopmentOrchestrator
    private static let maxDevelopments = 5
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
        embedder: (any TextEmbedder)? = nil,
        legalConfiguration: LegalModelConfiguration = .fromEnvironment(),
        tokenStore: (any APIKeyStoreProtocol)? = nil,
        courtListenerClient: (any CourtListenerClientProtocol)? = nil,
        statutoryOrchestrator: StatutorySourceOrchestrator? = nil,
        developmentsOrchestrator: LegalDevelopmentOrchestrator? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
        self.scope = scope
        if case let .matter(id) = scope {
            self.documentGrounding = MatterChatDocumentGrounding(
                store: store, embedder: embedder, matterID: id, defaultSystemPrompt: defaultSystemPrompt
            )
        } else {
            self.documentGrounding = nil
        }
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
        // Default statutory tier: eCFR (official federal regs, currency-verifiable) + Open Legal
        // Codes (free state/USC convenience). Both are key-less and token-free; their shared
        // AuthorizedHTTPClient keeps the statutory rate budget separate from CourtListener's.
        let statutoryHTTPClient = AuthorizedHTTPClient(
            keyStore: resolvedTokenStore,
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests),
            redactsQueryValues: !legalConfiguration.logPrivilegedQueryTerms
        )
        self.statutoryOrchestrator = statutoryOrchestrator ?? StatutorySourceOrchestrator(sources: [
            GovInfoStatutorySource(httpClient: statutoryHTTPClient, tokenStore: resolvedTokenStore),
            ECFRStatutorySource(client: ECFRClient(httpClient: statutoryHTTPClient)),
            OpenLegalCodesStatutorySource(client: OpenLegalCodesClient(httpClient: statutoryHTTPClient))
        ])
        // Legal-developments tracking. Federal Register is key-less; the others read their API key
        // from the token store and contribute nothing (a note) until the key is set in Settings.
        self.developmentsOrchestrator = developmentsOrchestrator ?? LegalDevelopmentOrchestrator(sources: [
            FederalRegisterSource(client: FederalRegisterClient(httpClient: statutoryHTTPClient)),
            OpenStatesSource(httpClient: statutoryHTTPClient, tokenStore: resolvedTokenStore),
            LegiScanSource(httpClient: statutoryHTTPClient, tokenStore: resolvedTokenStore),
            RegulationsGovSource(httpClient: statutoryHTTPClient, tokenStore: resolvedTokenStore)
        ])
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
            activeChatOptions = loadChatOptions(for: selectedChatID) ?? storedDefaultOptions()
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
        activeChatOptions = chatID.flatMap(loadChatOptions(for:)) ?? storedDefaultOptions()
        reloadMessages()
    }

    private func reloadMessages() {
        guard let selectedChatID else {
            messages = []
            return
        }
        let records = (try? store.chats.fetchMessages(chatID: selectedChatID)) ?? []
        messages = records.map { record in
            var message = ChatMessage(record: record)
            // Inline citations only exist for finalized assistant messages.
            if message.role == .assistant, !message.isStreaming {
                let citations = (try? store.chats.fetchCitations(messageID: message.id)) ?? []
                message.citations = citations.map(MessageCitation.init)
            }
            return message
        }
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
            clearChatOptions(for: chatID)
            chats = fetchScopedChats()
            if selectedChatID == chatID {
                select(chatID: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders an entire chat conversation as a Markdown transcript: the chat title
    /// as an H1, then each turn labelled "You" / "Assistant". Assistant turns use the
    /// answer with chain-of-thought stripped (matching what's shown on screen), and
    /// system turns are dropped. Emoji stripping is applied by the caller (the view's
    /// `EmojiStripper`). Pure and order-preserving so it can be unit-tested directly.
    /// Surfaces a user-facing error from a view-driven action (e.g. a failed file
    /// export) through the same banner the controller uses internally.
    public func reportError(_ message: String) {
        errorMessage = message
    }

    /// Resolves a tapped `[S#]` matter-document citation into a renderable preview
    /// (navigated to its page, with a best-effort highlight). Keeps the view free of
    /// the store, mirroring `MatterDocumentsController.preview(documentID:)`.
    public func citationPreview(
        documentID: String,
        locator: DocumentSourceLocator,
        matchText: String?
    ) -> DocumentPreviewModel {
        DocumentPreviewLoader(store: store).load(
            documentID: documentID, locator: locator, matchText: matchText
        )
    }

    public func exportTranscriptMarkdown(chatID: String, title: String) -> String {
        let messages = (try? store.chats.fetchMessages(chatID: chatID))?.map(ChatMessage.init) ?? []
        var lines: [String] = ["# \(title)", ""]
        for message in messages where message.role != .system {
            let label = message.role == .user ? "**You:**" : "**Assistant:**"
            let body = message.role == .assistant
                ? ReasoningContent.answer(from: message.content)
                : message.content
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(label)
            lines.append("")
            lines.append(trimmed)
            lines.append("")
            // The answer body now carries bare `[S#]`/`[A#]` markers (the resolving
            // excerpt trailer was dropped from generation), so resolve them from the
            // persisted citations table here — otherwise the export would leave the
            // markers dangling.
            let citations = (try? store.chats.fetchCitations(messageID: message.id))?
                .map(MessageCitation.init(record:)) ?? []
            if message.role == .assistant, !citations.isEmpty {
                lines.append("**Sources:**")
                lines.append("")
                for citation in citations { lines.append(Self.exportSourceLine(citation)) }
                lines.append("")
            }
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Renders one persisted citation as a Markdown bullet for the exported
    /// transcript, e.g. `- [S1] agreement.pdf — p. 3` or `- [A1] Doe v. Smith — <url>`.
    private static func exportSourceLine(_ citation: MessageCitation) -> String {
        let name = citation.displayName ?? (citation.kind == .authority ? "Authority" : "Document")
        var line = "- [\(citation.label)] \(name)"
        if citation.kind == .source, let display = citation.locator?.displayString, !display.isEmpty {
            line += " — \(display)"
        } else if citation.kind == .authority, let url = citation.url, !url.isEmpty {
            line += " — \(url)"
        }
        return line
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

    // MARK: - Tag / content search

    /// Searches chats (by title + message content) and ScratchPad notes for `term`,
    /// returning hits grouped by matter. A leading `#` is treated as an exact tag
    /// match for notes. In a matter scope the search is bounded to that matter; in the
    /// global scope it spans every matter (cross-matter discovery). Chat hits in the
    /// current scope are openable; others are discovery-only. Runs synchronous LIKE
    /// queries — fine at current scale (no FTS index yet).
    public func tagSearch(term: String) -> [TagSearchHit] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return [] }
        let exactTag = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : nil

        let matters = (try? store.matters.fetchMatters()) ?? []
        let nameByID = Dictionary(matters.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var hits: [TagSearchHit] = []

        for hit in (try? store.chats.searchChats(term: trimmed, matterID: scopedMatterID)) ?? [] {
            let group = hit.matterID.flatMap { nameByID[$0] } ?? "Global chats"
            hits.append(TagSearchHit(
                id: "chat-\(hit.chatID)", kind: .chat,
                openableChatID: isOpenable(hit) ? hit.chatID : nil,
                group: group, title: hit.title,
                snippet: Self.searchSnippet(hit.snippet, around: trimmed), date: hit.updatedAt
            ))
        }

        for entry in (try? store.scratchPad.searchEntries(term: trimmed)) ?? [] {
            // For a #tag query, require the exact tag (so #urgent ≠ #urgentish).
            if let exactTag, !entry.tags.contains(where: { $0.caseInsensitiveCompare(exactTag) == .orderedSame }) { continue }
            // In a matter scope, only notes that @mention this matter.
            if let scoped = scopedMatterID, !entry.mentions.contains(scoped) { continue }
            let group = entry.mentions.first.flatMap { nameByID[$0] } ?? "Unassigned notes"
            hits.append(TagSearchHit(
                id: "note-\(entry.entryID)", kind: .note, openableChatID: nil,
                group: group, title: "ScratchPad · \(entry.day)",
                snippet: Self.searchSnippet(entry.text, around: trimmed), date: nil
            ))
        }
        return hits
    }

    /// Whether a chat hit belongs to this controller's scope (so it can be opened in
    /// place rather than only surfaced for discovery).
    private func isOpenable(_ hit: ChatRepository.ChatSearchHit) -> Bool {
        switch scope {
        case .global: return hit.scope == "global"
        case let .matter(id): return hit.matterID == id
        }
    }

    /// A short snippet of `content` centered on the first match of `term`.
    private static func searchSnippet(_ content: String?, around term: String, window: Int = 100) -> String {
        guard let content, !content.isEmpty else { return "" }
        guard let match = content.range(of: term, options: .caseInsensitive) else {
            return String(content.prefix(window + 40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = content.index(match.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(match.upperBound, offsetBy: window, limitedBy: content.endIndex) ?? content.endIndex
        var snippet = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start != content.startIndex { snippet = "…" + snippet }
        if end != content.endIndex { snippet += "…" }
        return snippet
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

        // Layer the user's soul document OVER the route's task prompt (not instead of
        // it): the route prompt stays the lead instruction and the profile (citation
        // style, jurisdiction, voice) applies on top — so even an authoritative legal
        // route is personalized. Falls back to the route/default prompt when no
        // profile is configured.
        // Writing-style excerpts are for emulating voice when drafting; in QA/research
        // routes they'd be mined as facts, so include them only for the drafting route.
        let effectiveSystemPrompt = systemPrompt ?? store.composedAssistantPrompt(
            base: route?.systemPrompt ?? defaultSystemPrompt,
            includeWritingSamples: route?.mode == .drafting
        )
        let effectiveOptions = Self.effectiveOptions(userOptions: options, route: route, fallback: storedDefaultOptions())
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
            // History is part of that inference — a follow-up ("the exact language
            // of the statute") inherits the federal jurisdiction an earlier turn
            // established — so replay the same prior turns the send path captures.
            let history = selectedChatID.map {
                Self.conversationHistory(
                    from: (try? store.chats.fetchMessages(chatID: $0))?.map(ChatMessage.init) ?? [],
                    budget: Self.historyCharBudget
                )
            } ?? []
            let classification = classificationApplyingChatJurisdiction(
                classificationApplyingMatterScope(LegalQueryClassifier.classify(routed.prompt)),
                prompt: routed.prompt,
                history: history
            )
            return !(routed.route.requiresJurisdiction && classification.needsJurisdictionForAuthority)
        case .legalCritique, .drafting, .generalQA:
            return true
        }
    }

    private func storedDefaultOptions() -> GenerationOptions {
        (try? store.appSettings.getSetting(SettingsController.generationDefaultsKey, as: GenerationOptions.self)) ?? GenerationOptions()
    }

    // MARK: - Per-chat generation options

    private static func chatOptionsKey(_ chatID: String) -> String { "generation.chat.\(chatID)" }

    private func loadChatOptions(for chatID: String) -> GenerationOptions? {
        try? store.appSettings.getSetting(Self.chatOptionsKey(chatID), as: GenerationOptions.self)
    }

    private func persistChatOptions(_ options: GenerationOptions, for chatID: String) {
        try? store.appSettings.setSetting(Self.chatOptionsKey(chatID), value: options)
    }

    private func clearChatOptions(for chatID: String) {
        try? store.appSettings.removeSetting(Self.chatOptionsKey(chatID))
    }

    /// Persists the current chat's override (when one is selected). A not-yet-created
    /// chat keeps the change in memory; `ensureSelectedChat` writes it on the first send.
    private func persistActiveChatOverride() {
        if let selectedChatID { persistChatOptions(activeChatOptions, for: selectedChatID) }
    }

    /// Switches the selected chat's preset (snapping sampling/length to its character),
    /// scoped to this chat only — the app-wide default is unchanged.
    public func setActiveChatPreset(_ preset: GenerationPreset) {
        guard preset != activeChatOptions.preset else { return }
        activeChatOptions.selectPreset(preset)
        persistActiveChatOverride()
    }

    /// Sets the selected chat's temperature (scoped to this chat).
    public func setActiveChatTemperature(_ temperature: Double) {
        activeChatOptions.temperature = min(1, max(0, temperature))
        persistActiveChatOverride()
    }

    /// Sets the selected chat's max output tokens (scoped to this chat).
    public func setActiveChatMaxOutputTokens(_ tokens: Int) {
        activeChatOptions.maxOutputTokens = tokens
        persistActiveChatOverride()
    }

    /// Resolves the options for a send, honoring the user's visible generation
    /// controls on routed sends instead of silently ignoring them. The route's
    /// specialized tuning is the base; the user's temperature applies on top — except
    /// the route is never *loosened* if it is intentionally greedy (temperature 0,
    /// e.g. verification). `maxOutputTokens` is extend-only (the larger of the two) so
    /// the user can lengthen an answer but never truncate a route's tuned budget
    /// (e.g. a research memo's). Routes keep their topK / thinking / context / penalty.
    nonisolated static func effectiveOptions(
        userOptions: GenerationOptions?,
        route: ModelRoute?,
        fallback: GenerationOptions
    ) -> GenerationOptions {
        guard let route else { return userOptions ?? fallback }
        var merged = route.options
        if let userOptions {
            // Legal authority routes keep their tuned conservative temperature — the
            // user's global default (e.g. Balanced 0.5) must not silently loosen a
            // citation-bound /legal or /research answer toward fabrication. Non-legal
            // routes (drafting, general chat) honor the user's temperature.
            if !route.usesOneShotLegalWorkflow {
                merged.temperature = userOptions.temperature
            }
            merged.maxOutputTokens = max(route.options.maxOutputTokens, userOptions.maxOutputTokens)
        }
        return merged
    }

    /// Greedy decoding for document-grounded answers: faithful, reproducible
    /// extraction from the supplied sources rather than creative sampling. Mirrors the
    /// Documents-tab Q&A route; keeps the caller's context/output budget.
    nonisolated static func groundedOptions(_ base: GenerationOptions) -> GenerationOptions {
        var options = base
        options.temperature = 0
        options.topP = 1
        options.topK = nil
        options.repetitionPenalty = nil
        // Literal extraction, not reasoning: a chain-of-thought scratchpad is what lets
        // a model "derive" a full name from an email prefix. Disable thinking so the
        // grounded turn copies facts from the sources instead of inferring them.
        options.thinkingBudget = .off
        return options
    }

    /// A warning footer for a grounded answer listing identities (names/emails/phones)
    /// that don't appear in the cited sources, or nil when everything is grounded. The
    /// answer is always shown; this only marks what could not be verified in the record.
    nonisolated static func entityGroundingBanner(_ issues: [LegalVerificationIssue]) -> String? {
        let excerpts = issues.compactMap { issue -> String? in
            guard let excerpt = issue.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty else { return nil }
            return excerpt
        }
        guard !excerpts.isEmpty else { return nil }
        var lines = [
            "",
            "---",
            "",
            "⚠️ **Grounding check — not found in the cited documents.** The following were stated in the answer above but do not appear verbatim in the sources, and may be inferred (for example, a name reconstructed from an email prefix). Verify each against the record before relying on it:"
        ]
        for excerpt in excerpts {
            lines.append("- \(excerpt)")
        }
        return "\n" + lines.joined(separator: "\n")
    }

    /// A warning footer for a grounded answer whose citations don't clear the coverage
    /// bar — no inline `[S#]`, a label that doesn't resolve, or a still-indexing scope —
    /// or nil when coverage is clean. Like the entity banner, the answer is always shown;
    /// this only marks what the reader must verify.
    nonisolated static func citationCoverageBanner(_ check: CitationCheckResult) -> String? {
        guard check.requiresReview else { return nil }
        let warnings = check.warnings
        guard !warnings.isEmpty else { return nil }
        var lines = [
            "",
            "---",
            "",
            "⚠️ **Citation check — verify before relying on this answer.**"
        ]
        for warning in warnings {
            lines.append("- \(warning)")
        }
        return "\n" + lines.joined(separator: "\n")
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
            // In a matter chat, a question about the matter's OWN documents ("list the
            // cases in the Research folder", "what do my documents say about X") is
            // answered from real data — a deterministic inventory or retrieved passages
            // — instead of the model's memory, which otherwise fabricates. This takes
            // precedence over the CourtListener legal routes: "in my documents" must
            // never become an external case-law search. Skipped when the user attached
            // files inline (those are the grounding) or for non-document questions.
            // Gated on a loaded model so a no-model send doesn't pay for retrieval it
            // will discard at the guard below.
            let grounded: GroundedChatContext? = (attachments.isEmpty && modelID != nil)
                ? await documentGrounding?.groundedContext(forQuestion: prompt)
                : nil

            if grounded == nil, let route, route.usesOneShotLegalWorkflow {
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

            // Grounded answers must stay faithful to the supplied sources, so decode
            // greedily (mirroring the Documents-tab Q&A route) rather than with the
            // chat's creative sampling.
            let effectiveModelPrompt = grounded?.modelPrompt ?? modelPrompt
            let effectiveSystemPrompt = grounded.map { $0.systemPrompt } ?? systemPrompt
            let effectiveOptions = grounded == nil ? options : Self.groundedOptions(options)
            let groundingTrailer = grounded?.trailer
            let groundingSourceTexts = grounded?.sourceTexts ?? []
            let groundingSources = grounded?.sources ?? []
            let groundingScopeFullyIndexed = grounded?.scopeFullyIndexed ?? true

            guard let modelID else {
                errorMessage = "Load or register a local MLX model in the Models tab."
                return
            }

            // Title from the routed prompt (slash command already stripped), so a
            // "/draft …" chat is titled by its content — matching the legal path.
            let chatID = try ensureSelectedChat(titleHint: prompt).id

            // Replay prior turns so the model can answer follow-ups in context.
            // Captured before appending the new user message. A grounded turn is
            // self-contained (its prompt carries the authoritative inventory/sources
            // and the "use ONLY these" contract), so it skips history — prior, possibly
            // ungrounded turns must not dilute the grounding, matching the Q&A path.
            let history = grounded == nil
                ? Self.conversationHistory(
                    from: (try? store.chats.fetchMessages(chatID: chatID))?.map(ChatMessage.init) ?? [],
                    budget: Self.historyCharBudget
                )
                : []

            _ = try store.chats.appendUserMessage(chatID: chatID, content: displayContent)
            let assistant = try store.chats.createAssistantMessageShell(chatID: chatID)
            let generationID = GenerationID()
            let session = try store.generation.createGenerationSession(
                chatID: chatID,
                messageID: assistant.id,
                modelID: modelID.rawValue.uuidString,
                prompt: effectiveModelPrompt,
                systemPrompt: effectiveSystemPrompt,
                options: effectiveOptions
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
                prompt: effectiveModelPrompt,
                systemPrompt: effectiveSystemPrompt,
                history: history,
                options: effectiveOptions
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
                    // The runtime dropped oldest turns to fit the window — tell the
                    // user (persist it too) rather than silently losing context.
                    if finalMetrics?.contextTrimmed == true {
                        try? store.chats.appendToken(to: variant.id, token: Self.contextTrimmedNotice)
                        streamedContent += Self.contextTrimmedNotice
                    }
                    // The model's answer, before the source trailer — what the
                    // entity-grounding check inspects.
                    let answerText = streamedContent
                    // Append the grounded answer's source key so inline [S#] citations
                    // resolve to document names for the reader. Only on success.
                    if let groundingTrailer, !groundingTrailer.isEmpty {
                        try? store.chats.appendToken(to: variant.id, token: groundingTrailer)
                        streamedContent += groundingTrailer
                    }
                    // Post-generation grounding check: flag any name / email / phone the
                    // answer asserts that is absent from the cited sources (e.g. a full
                    // name reconstructed from an email prefix). Surfaced as a warning,
                    // never suppressed — the reader sees both the answer and the caveat.
                    if !groundingSourceTexts.isEmpty {
                        let entityIssues = LegalCitationVerifier.verifyGroundedEntities(
                            answer: answerText,
                            sourceText: groundingSourceTexts.joined(separator: "\n\n")
                        )
                        if let banner = Self.entityGroundingBanner(entityIssues) {
                            try? store.chats.appendToken(to: variant.id, token: banner)
                            streamedContent += banner
                        }
                    }
                    // Citation-coverage check — the same bar the Documents-tab Q&A
                    // enforces: a grounded answer with no inline [S#] citation, an
                    // unresolved label, or one produced from a still-indexing scope is
                    // flagged for review out-of-band, so the warning can't be dropped by
                    // the model the way a soft in-prompt note can.
                    if !groundingSources.isEmpty {
                        let coverage = CitationCoverage.check(
                            answer: answerText,
                            availableLabels: groundingSources.map(\.label),
                            scopeFullyIndexed: groundingScopeFullyIndexed
                        )
                        if let banner = Self.citationCoverageBanner(coverage) {
                            try? store.chats.appendToken(to: variant.id, token: banner)
                            streamedContent += banner
                        }
                    }
                    try store.chats.completeVariant(variant.id)
                    try store.generation.completeGeneration(
                        generationID: session.id,
                        metrics: storedMetrics(from: finalMetrics)
                    )
                    let citations = persistSourceCitations(
                        messageID: assistant.id,
                        answer: answerText,
                        sources: groundingSources
                    )
                    updateMessage(id: assistant.id, content: streamedContent, status: .completed)
                    attachCitations(citations, toMessage: assistant.id)

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
        // Replay prior turns so legal follow-ups ("now narrow that to the 9th Cir.",
        // "apply that rule to my facts") resolve in context. Captured before the new
        // user message is appended; the runtime's budget guard trims it if the packet
        // + question leave no room.
        let history = Self.conversationHistory(
            from: (try? store.chats.fetchMessages(chatID: chatID))?.map(ChatMessage.init) ?? [],
            budget: Self.historyCharBudget
        )

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
                history: history,
                priorAssistantDraft: priorAssistantDraft
            )
            try store.chats.appendToken(to: variant.id, token: result.output)
            try store.chats.completeVariant(variant.id)
            try store.generation.completeGeneration(generationID: session.id)
            let citations = persistAuthorityCitations(
                messageID: assistant.id,
                answer: result.output,
                authorities: result.authorities
            )
            updateMessage(id: assistant.id, content: result.output, status: .completed)
            attachCitations(citations, toMessage: assistant.id)
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
        history: [GenerateRequest.Turn],
        priorAssistantDraft: String?
    ) async throws -> LegalWorkflowResult {
        switch route.mode {
        case .legalVerify:
            // What to verify: pasted, citation-bearing text is checked as-is (the
            // "/verify <text with cites>" use case). A bare command or a short comment
            // ("/verify these names look wrong") instead verifies the PRIOR ASSISTANT
            // ANSWER — the user's intent, and the fix for /verify previously inspecting
            // its own command string and falsely "passing".
            let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let priorDraft = (priorAssistantDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let typedIsContent = !typed.isEmpty
                && (typed.range(of: #"\[[AS]\d+\]"#, options: .regularExpression) != nil
                    || !LegalCitationVerifier.extractCitationLikeStrings(from: typed).isEmpty)
            let answerToVerify = typedIsContent ? typed : (priorDraft.isEmpty ? typed : priorDraft)

            // A document-grounded answer cites [S#] document sources, not the [A#]
            // legal-authority packet; checking it against a (possibly stale) CourtListener
            // packet would be a meaningless, falsely-reassuring "pass". Those answers are
            // already checked for un-sourced names/identities inline when generated.
            if answerToVerify.range(of: #"\[S\d+\]"#, options: .regularExpression) != nil,
               answerToVerify.range(of: #"\[A\d+\]"#, options: .regularExpression) == nil {
                let note = "This answer is grounded in this matter's documents ([S#]), not in a legal-authority packet, so `/verify` (which checks case-law citations) does not apply here. Document-grounded answers are checked automatically when generated — look for a “⚠️ Grounding check” note beneath the answer flagging any name or identifier not found in the cited documents. Use `/verify` after a `/research` or `/legal` answer to check its [A#] citations."
                return LegalWorkflowResult(
                    output: note, queryTerms: [], authorities: [], verification: nil, researchSessionID: nil
                )
            }

            let packet = latestLegalSourcePacket(chatID: chatID)
            let report = LegalCitationVerifier.verify(answer: answerToVerify, authorities: packet.authorities)
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
                options: options,
                history: history
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
                history: history,
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
        options: GenerationOptions,
        history: [GenerateRequest.Turn]
    ) async throws -> LegalWorkflowResult {
        let scopedClassification = classificationApplyingChatJurisdiction(
            classificationApplyingMatterScope(LegalQueryClassifier.classify(prompt)),
            prompt: prompt,
            history: history
        )
        let sourcePlan = LegalResearchSourcePlanner.plan(
            classification: scopedClassification,
            target: legalSourceTarget(for: scopedClassification)
        )
        let classification = sourcePlan.effectiveClassification
        if route.requiresJurisdiction, !sourcePlan.satisfiesJurisdictionRequirement {
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

        let statutoryLookup: (provisions: [StatutoryProvision], notes: [String]) = sourcePlan.shouldRetrievePrimaryLaw
            ? await statutoryProvisions(for: sourcePlan)
            : ([], [])
        let citableStatutoryProvisions = statutoryLookup.provisions.filter(\.isCitableAuthority)
        if sourcePlan.requiresPrimaryLaw, citableStatutoryProvisions.isEmpty {
            let terms = [sourcePlan.primaryLawQueryTerms].filter { !$0.isEmpty }
            let output = Self.missingPrimaryLawMessage(plan: sourcePlan, notes: statutoryLookup.notes)
            return LegalWorkflowResult(output: output, queryTerms: terms, authorities: [], verification: nil, researchSessionID: nil)
        }

        let retrieval: (queryTerms: [String], authorities: [LegalAuthority], researchSessionID: String?)
        do {
            retrieval = try await retrieveAuthorities(for: classification, route: route, modelID: modelID, matterID: scopedMatterID)
        } catch {
            guard !statutoryLookup.provisions.isEmpty else { throw error }
            retrieval = ([], [], nil)
        }
        let rankedAll = await hydrateTopAuthorities(LegalAuthorityRanker.rank(retrieval.authorities, for: classification))
        // Cap to exactly the packet the model is shown. buildAnswerPrompt caps the
        // SOURCE PACKET at maxPacketAuthorities, so the model only ever sees
        // [A1]…[A maxPacketAuthorities]. The verifier and the stored packet (used by
        // /verify) must use the SAME capped set — otherwise a fabricated [A13+] label
        // pointing at an authority that was never in the prompt would pass as grounded.
        // Packet construction is source-plan driven: primary law leads when present,
        // and statutory/legal-rule questions are blocked before this point if primary
        // law was required but unavailable.
        let ranked = StatutoryPacketMerge.merge(
            statutoryProvisions: citableStatutoryProvisions,
            rankedCases: rankedAll,
            jurisdictionLabel: classification.jurisdiction,
            cap: LegalResearchPromptBuilder.maxPacketAuthorities
        )
        let authorities = ranked.map(\.authority)
        let queryTerms = Self.uniqued(
            ([sourcePlan.primaryLawQueryTerms].filter { sourcePlan.shouldRetrievePrimaryLaw && !$0.isEmpty })
            + retrieval.queryTerms
        )
        let packet = LegalSourcePacket(
            queryTerms: queryTerms,
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
                queryTerms: queryTerms,
                authorities: [],
                verification: nil,
                researchSessionID: retrieval.researchSessionID
            )
        }

        let answerPrompt = LegalResearchPromptBuilder.buildAnswerPrompt(
            question: prompt,
            classification: classification,
            rankedAuthorities: ranked,
            authorityPriority: sourcePlan.authorityPriority
        )
        let request = GenerateRequest(
            generationID: generationID,
            modelID: modelID,
            prompt: answerPrompt,
            systemPrompt: systemPrompt,
            history: history,
            options: options
        )
        var output = ReasoningContent.answer(from: try await runtimeClient.collectGeneratedText(request))
        var verification = legalConfiguration.verifyCitations
            ? LegalCitationVerifier.verify(
                answer: output,
                authorities: authorities,
                expectedJurisdiction: classification.jurisdiction
            )
            : nil

        // Auto-repair on a hard verification failure: re-prompt the same model once
        // with the specific issues and a packet-only-citation rule, then re-verify.
        // Runs only on a hard failure, so a clean answer keeps its single round-trip;
        // the revision is kept only if it is at least as clean as the original.
        if let failed = verification, !failed.passed,
           Self.hasHardVerificationFailure(failed, route: route)
            || (route.requiresCitations && !Self.hasSupportedCitation(failed)) {
            let revisionPrompt = LegalResearchPromptBuilder.buildRevisionPrompt(
                question: prompt, classification: classification, rankedAuthorities: ranked,
                authorityPriority: sourcePlan.authorityPriority,
                priorAnswer: output, issues: failed.issues
            )
            let revisionRequest = GenerateRequest(
                generationID: generationID, modelID: modelID, prompt: revisionPrompt,
                systemPrompt: systemPrompt, history: history, options: options
            )
            if let revisedRaw = try? await runtimeClient.collectGeneratedText(revisionRequest) {
                let revised = ReasoningContent.answer(from: revisedRaw)
                let revisedVerification = LegalCitationVerifier.verify(
                    answer: revised, authorities: authorities, expectedJurisdiction: classification.jurisdiction
                )
                // Keep the revision only if it is genuinely cleaner: never accept MORE
                // hard failures (a soft-for-hard trade is a regression), and use the
                // total issue count only as a tiebreak at equal hard severity.
                let priorHard = Self.hardVerificationFailureCount(failed, route: route)
                let revisedHard = Self.hardVerificationFailureCount(revisedVerification, route: route)
                if revisedHard < priorHard
                    || (revisedHard == priorHard && revisedVerification.issues.count < failed.issues.count) {
                    output = revised
                    verification = revisedVerification
                }
            }
        }

        if let verification, !verification.passed {
            // Gate on severity: a fabricated/unsupported citation or quote (and a
            // jurisdiction mismatch when this route requires jurisdiction) is a hard
            // failure — quarantine the answer behind a banner so it can never read as
            // verified law. requireCitations additionally demands at least one cite
            // actually supported by the retrieved packet. Soft issues (e.g. an
            // uncited proposition) only append the advisory report.
            if Self.hasHardVerificationFailure(verification, route: route)
                || (route.requiresCitations && !Self.hasSupportedCitation(verification)) {
                output = Self.blockedLegalResearchMessage(report: verification)
            } else {
                output += "\n\n---\n\n" + LegalCitationVerifier.markdownReport(verification)
            }
        }

        // Firewall: guarantee a currency caveat reaches the reader whenever the answer cites an
        // UNVERIFIED statutory provision (a `.statute` authority with no confirmed effective date,
        // e.g. Open Legal Codes), regardless of whether the model hedged. Dated sources (eCFR) are exempt.
        output = Self.statutoryCurrencyCaveatApplied(to: output, authorities: authorities)

        // Append a NON-citable "Legal developments" section (pending bills / rulemaking) when there
        // is relevant tracking context. Never enters the citable packet — best-effort, never blocks.
        if sourcePlan.shouldRetrieveDevelopments, let developments = await legalDevelopmentsSection(for: classification) {
            output += "\n\n---\n\n" + developments
        }

        return LegalWorkflowResult(
            output: output,
            queryTerms: queryTerms,
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

    static func blockedLegalResearchMessage(report: LegalVerificationReport) -> String {
        """
        I cannot provide a source-grounded legal answer from the retrieved packet because automated verification still found unsupported or mismatched authority after repair.

        \(LegalCitationVerifier.markdownReport(report))
        """
    }

    static func missingPrimaryLawMessage(plan: LegalResearchSourcePlan, notes: [String]) -> String {
        var lines = [
            "I could not retrieve the governing primary law required for this question, so I cannot answer it from case law or model memory alone.",
            "",
            "Primary-law search target:",
            "- Jurisdiction: \(plan.effectiveClassification.jurisdiction ?? "Unspecified")",
            "- Issue: \(plan.primaryLawQueryTerms)"
        ]
        if let citation = plan.primaryLawCitationQuery, !citation.isEmpty {
            lines.append("- Citation target: \(citation)")
        }
        let allNotes = plan.notes + notes
        if !allNotes.isEmpty {
            lines.append("")
            lines.append("Retrieval notes:")
            lines += allNotes.map { "- \($0)" }
        }
        lines.append("")
        lines.append("Provide the governing statute/regulation text or narrow the citation, then rerun the research.")
        return lines.joined(separator: "\n")
    }

    /// Appended when the runtime had to drop the oldest turns to fit the context
    /// window, so the user knows earlier messages were not in view for this reply
    /// rather than silently losing that context.
    static let contextTrimmedNotice = "\n\n---\n_Note: this conversation exceeded the model's context window, so the earliest messages were dropped from view for this reply. Start a new chat to reset the context._"

    /// A hard verification failure: a fabricated/unsupported citation or quotation,
    /// or — when the route requires jurisdiction — a jurisdiction mismatch.
    static func hasHardVerificationFailure(_ report: LegalVerificationReport, route: ModelRoute) -> Bool {
        hardVerificationFailureCount(report, route: route) > 0
    }

    /// Number of hard-failure issues (fabricated/unsupported citation or quote; a
    /// jurisdiction mismatch when the route requires jurisdiction). Used to ensure a
    /// self-repair never trades a soft issue for a new hard one.
    static func hardVerificationFailureCount(_ report: LegalVerificationReport, route: ModelRoute) -> Int {
        report.issues.filter { issue in
            switch issue.kind {
            case .unsupportedCitation, .unsupportedQuote:
                return true
            case .jurisdictionMismatch:
                return route.requiresJurisdiction
            case .missingCitation, .noRetrievedAuthorities, .ungroundedEntity:
                // .ungroundedEntity is a soft "shown but unverified" warning, never a
                // hard failure that would trigger self-repair.
                return false
            }
        }.count
    }

    /// True when at least one detected citation is actually supported by the
    /// retrieved authority packet (i.e. not flagged as unsupported).
    static func hasSupportedCitation(_ report: LegalVerificationReport) -> Bool {
        guard !report.citedStrings.isEmpty else { return false }
        let unsupported = Set(report.issues.filter { $0.kind == .unsupportedCitation }.compactMap { $0.excerpt })
        return report.citedStrings.contains { !unsupported.contains($0) }
    }

    /// Most authorities to enrich with full opinion text. CourtListener search returns
    /// only a short snippet/syllabus, so for the top-ranked authorities we fetch the
    /// full opinion body. This gives the model real opinion prose to reason over and
    /// quote, and lets the citation verifier check quotes against the full text rather
    /// than false-flagging a genuine quote that was merely absent from the snippet.
    static let maxHydratedAuthorities = 4

    /// Best-effort: replaces the top-N ranked authorities' text with the full opinion
    /// body fetched from CourtListener. Any fetch failure (network, rate limit, no
    /// opinion id, empty body) leaves that authority's existing snippet untouched, so
    /// hydration never blocks or fails the research answer.
    private func hydrateTopAuthorities(_ ranked: [RankedLegalAuthority]) async -> [RankedLegalAuthority] {
        var result = ranked
        for index in result.indices.prefix(Self.maxHydratedAuthorities) {
            guard let opinionID = result[index].authority.opinionId.flatMap(Int.init) else { continue }
            guard
                let detail = try? await courtListenerClient.fetchOpinion(id: opinionID),
                let body = detail.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !body.isEmpty
            else { continue }
            result[index].authority.text = body
        }
        return result
    }

    private func statutoryProvisions(
        for sourcePlan: LegalResearchSourcePlan
    ) async -> (provisions: [StatutoryProvision], notes: [String]) {
        guard statutoryOrchestrator.hasSources else {
            return ([], ["No statutory or regulatory source is configured."])
        }
        let query = LegalResearchSourcePlanner.statutoryQuery(
            for: sourcePlan,
            limit: Self.maxStatutoryProvisions
        )
        return await statutoryOrchestrator.lookup(query)
    }

    /// Firewall: appends a currency caveat when the answer cites an unverified statutory provision
    /// (a `.statute` authority with no confirmed effective date). Dated sources (eCFR) are exempt;
    /// if the model already hedged, the caveat is not duplicated.
    private static func statutoryCurrencyCaveatApplied(to output: String, authorities: [LegalAuthority]) -> String {
        let cited = citedPacketIndices(in: output)
        let unverifiedCited = cited.contains { index in
            guard index >= 1, index <= authorities.count else { return false }
            let authority = authorities[index - 1]
            return authority.authorityType == .statute && (authority.dateFiled?.isEmpty ?? true)
        }
        guard unverifiedCited else { return output }
        let lowered = output.lowercased()
        if lowered.contains("unverified") || lowered.contains("confirm against") { return output }
        return output + "\n\n⚠️ A cited statutory provision comes from an unverified source (no confirmed effective date). Confirm its current text against the official code before relying on it."
    }

    private static func citedPacketIndices(in text: String) -> Set<Int> {
        guard let regex = try? NSRegularExpression(pattern: #"\[A(\d+)\]"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var indices = Set<Int>()
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let captured = Range(match.range(at: 1), in: text), let value = Int(text[captured]) else { return }
            indices.insert(value)
        }
        return indices
    }

    /// Best-effort, non-citable legal-developments section (pending bills / rulemaking). Runs on
    /// statutory/regulatory questions; a lookup failure simply yields no section.
    private func legalDevelopmentsSection(for classification: LegalQueryClassification) async -> String? {
        guard developmentsOrchestrator.hasSources else { return nil }
        let query = LegalDevelopmentQuery(
            terms: classification.legalIssue,
            jurisdiction: classification.jurisdiction,
            limit: Self.maxDevelopments
        )
        let (developments, _) = await developmentsOrchestrator.lookup(query)
        return LegalDevelopmentFormatter.section(developments: developments)
    }

    private func retrieveAuthorities(
        for classification: LegalQueryClassification,
        route: ModelRoute,
        modelID: ModelID,
        matterID: String?
    ) async throws -> (queryTerms: [String], authorities: [LegalAuthority], researchSessionID: String?) {
        // Prefer planner-generated queries (same planner the Research tab uses); fall back
        // to the single deterministic query when the model is unavailable or returns none.
        let plannedQueries = await planCourtListenerQueries(for: classification, route: route, modelID: modelID)
        let primaryRequests: [CourtListenerSearchRequest] = plannedQueries.isEmpty
            ? [courtListenerRequest(for: classification, adverse: false)]
            : plannedQueries.prefix(Self.maxChatPlannerQueries).map { plannerRequest(query: $0, classification: classification) }
        var requests = primaryRequests.map { (request: $0, adverse: false) }
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

    /// The number of planner-generated CourtListener queries the chat one-shot runs,
    /// bounded to keep latency and rate-limit pressure reasonable.
    private static let maxChatPlannerQueries = 3

    /// Uses the local model's query planner — the same one the Research tab uses — to
    /// turn the classified issue into good CourtListener search queries instead of the
    /// raw issue string. Returns [] on any failure so the caller falls back to the
    /// deterministic query.
    private func planCourtListenerQueries(
        for classification: LegalQueryClassification,
        route: ModelRoute,
        modelID: ModelID
    ) async -> [String] {
        let planner = ResearchQueryPlanner()
        guard let prompt = try? planner.buildPrompt(
            issueText: classification.legalIssue,
            jurisdiction: classification.jurisdiction ?? "Unspecified",
            jurisdictionContext: classification.jurisdictionContext ?? "",
            partyPerspective: "neutral",
            preferredCourts: classification.courtIDs,
            excludedCourts: [],
            dateRange: Self.plannerDateRange(after: classification.dateFiledAfter, before: classification.dateFiledBefore)
        ) else { return [] }

        var options = route.options
        options.thinkingBudget = .off
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt,
            systemPrompt: defaultSystemPrompt,
            options: options
        )
        guard let raw = try? await runtimeClient.collectGeneratedText(request),
              case let .answer(answer) = ReasoningContent.resolve(rawOutput: raw, thinkingEnabled: false) else {
            return []
        }
        return planner.parseQueries(from: answer)
    }

    private static func plannerDateRange(after: String?, before: String?) -> String {
        let a = after?.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = before?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (a?.isEmpty == false ? a : nil, b?.isEmpty == false ? b : nil) {
        case let (start?, end?): return "\(start) to \(end)"
        case let (start?, nil): return "on or after \(start)"
        case let (nil, end?): return "on or before \(end)"
        default: return "Any"
        }
    }

    /// A CourtListener request for a planner-generated query, carrying the
    /// classification's court/date/citation filters.
    private func plannerRequest(query: String, classification: LegalQueryClassification) -> CourtListenerSearchRequest {
        CourtListenerSearchRequest(
            query: query,
            orderBy: "score desc",
            courtIDs: classification.courtIDs,
            dateFiledAfter: classification.dateFiledAfter,
            dateFiledBefore: classification.dateFiledBefore,
            citation: Self.courtListenerCitationParameter(classification.citationLookup)
        )
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

    private func legalSourceTarget(for classification: LegalQueryClassification) -> LegalSourceTarget {
        switch scope {
        case .global:
            return LegalSourceTarget(
                kind: .global,
                jurisdiction: classification.jurisdiction,
                courtIDs: classification.courtIDs
            )
        case let .matter(id):
            let matterScope = matterJurisdictionScope()
            let matterDocuments = (try? store.documentLibrary.fetchDocuments(matterID: id)) ?? []
            let savedAuthorities = ((try? store.authorities.fetchAuthorities(matterID: id)) ?? [])
                .filter { record in
                    record.useStatus != AuthorityUseStatus.doNotUse.rawValue
                        && record.reviewState != ResearchResultReviewState.skipped.rawValue
                }
            return LegalSourceTarget(
                kind: .matter,
                matterID: id,
                jurisdiction: classification.jurisdiction ?? matterScope?.jurisdictionName,
                courtIDs: classification.courtIDs.isEmpty ? (matterScope?.courtListenerIDs ?? []) : classification.courtIDs,
                hasMatterDocuments: !matterDocuments.isEmpty,
                hasSavedMatterAuthorities: !savedAuthorities.isEmpty
            )
        }
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
        prompt: String,
        history: [GenerateRequest.Turn] = []
    ) -> LegalQueryClassification {
        guard scopedMatterID == nil else { return classification }

        let isExplicit = !jurisdictionOverrideID.isEmpty
        let option: JurisdictionOption?
        if isExplicit {
            option = JurisdictionCatalog.shared.option(id: jurisdictionOverrideID)
        } else if classification.jurisdiction == nil {
            option = inferredJurisdictionOption(from: prompt, history: history)
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
    /// built-in shortlist, used only as the auto-detect fallback. When the current
    /// prompt names no jurisdiction, the most recent user turns are scanned too, so
    /// a follow-up like "what is the exact language of the statute?" inherits the
    /// federal (or state) jurisdiction established earlier in the conversation.
    private func inferredJurisdictionOption(
        from prompt: String,
        history: [GenerateRequest.Turn] = []
    ) -> JurisdictionOption? {
        if let option = inferredJurisdictionOption(fromText: prompt) {
            return option
        }
        // Fall back to recent user turns (most recent first), stopping at the first
        // match. Restricted to user turns so the assistant's own boilerplate (e.g.
        // the "I need the jurisdiction" prompt) can't re-trigger detection.
        for turn in history.reversed() where turn.role == .user {
            if let option = inferredJurisdictionOption(fromText: turn.content) {
                return option
            }
        }
        return nil
    }

    /// Single-string jurisdiction detection: explicit state/circuit names, the
    /// "federal court(s)" phrase, or a federal citation shape (U.S.C., C.F.R.,
    /// federal reporters, the U.S. reporter) — all of which imply federal courts.
    private func inferredJurisdictionOption(fromText text: String) -> JurisdictionOption? {
        let lower = text.lowercased()
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
        ) != nil || mentions("federal court") || mentions("federal courts")
            || Self.mentionsFederalCitation(lower) {
            return topLevelJurisdictions.first { $0.id == "federal-courts" }
        }
        return nil
    }

    /// Conservative, digit-anchored detection of a federal statute, regulation, or
    /// reporter citation (e.g. "18 U.S.C. § 1001", "32 C.F.R. § 1100", "123 F.3d
    /// 456", "410 U.S. 113"). All imply federal jurisdiction. Each pattern requires
    /// a leading volume/section number so prose mentions of "U.S." don't trigger it.
    static func mentionsFederalCitation(_ lowercasedText: String) -> Bool {
        let patterns = [
            #"\b\d+\s+u\.?\s?s\.?\s?c\.?(\s?a\.?)?\b"#,                              // U.S.C. / U.S.C.A.
            #"\b\d+\s+c\.?\s?f\.?\s?r\.?\b"#,                                        // C.F.R.
            #"\b\d+\s+f\.(\s?(2d|3d|4th|app'?x|supp\.?(\s?(2d|3d))?))?\s+\d+"#,      // F., F.2d, F.3d, F. Supp. 2d
            #"\b\d+\s+u\.?\s?s\.?\s+\d+"#                                            // U.S. reporter, e.g. 410 U.S. 113
        ]
        return patterns.contains {
            lowercasedText.range(of: $0, options: .regularExpression) != nil
        }
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
        // Sanitize highlight markup / HTML entities before persisting.
        let cleanCitations = CourtListenerText.cleanList(dto.citation)
        let citationJSON = (try? JSONEncoder().encode(cleanCitations))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ResearchResultRecord(
            researchQueryID: queryID,
            clusterID: dto.clusterID.map(String.init),
            opinionID: dto.opinions.first?.id.map(String.init),
            caseName: CourtListenerText.clean(dto.caseName) ?? CourtListenerText.clean(dto.caseNameFull) ?? "Untitled case",
            caseNameFull: CourtListenerText.clean(dto.caseNameFull),
            citationJSON: citationJSON,
            preferredCitation: CourtListenerMapper.preferredCitation(for: dto),
            court: CourtListenerText.clean(dto.court),
            courtID: dto.courtID,
            dateFiled: Self.parseCourtListenerDate(dto.dateFiled),
            docketNumber: CourtListenerText.clean(dto.docketNumber),
            snippet: CourtListenerText.clean(dto.opinions.first?.snippet),
            absoluteURL: dto.absoluteURL,
            reviewState: reviewState.rawValue,
            rawResultJSON: dto.rawResultJSON
        )
    }

    private static func legalAuthority(from result: ResearchResultRecord) -> LegalAuthority {
        let citations = (try? JSONDecoder().decode([String].self, from: Data(result.citationJSON.utf8))) ?? []
        let dateFiled = result.dateFiled.map(Self.courtListenerDateFormatter.string(from:))
        // Defensive: rows persisted before sanitization can still carry `<mark>`.
        var authority = LegalAuthority(
            id: result.opinionID.map { "courtlistener:opinion:\($0)" }
                ?? result.clusterID.map { "courtlistener:cluster:\($0)" }
                ?? "research_result:\(result.id)",
            authorityType: .case,
            caseName: CourtListenerText.clean(result.caseName),
            citation: CourtListenerText.clean(result.preferredCitation),
            citations: CourtListenerText.cleanList(citations),
            court: CourtListenerText.clean(result.court),
            courtID: result.courtID,
            jurisdiction: result.courtID ?? CourtListenerText.clean(result.court),
            dateFiled: dateFiled,
            url: CourtListenerMapper.displayURL(for: CourtListenerSearchResultDTO(absoluteURL: result.absoluteURL))?.absoluteString ?? result.absoluteURL,
            snippet: CourtListenerText.clean(result.snippet),
            text: CourtListenerText.clean(result.snippet),
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

    /// Formats attachments as a labeled grounding block prepended to the model
    /// prompt. Each file gets an `[S#]` label and the model is asked to cite claims
    /// that rely on a file to its label, extending the cite-your-source discipline to
    /// the drag-a-file-into-chat workflow.
    nonisolated static func attachmentsBlock(_ attachments: [ChatAttachmentContext]) -> String {
        var lines = ["The user attached the following file(s) as sources. Use their contents as context, and when a statement relies on an attachment, cite it inline with its label, e.g. [S1]."]
        for (index, attachment) in attachments.enumerated() {
            lines.append("")
            lines.append("[S\(index + 1)] \(attachment.name)")
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
        // A brand-new chat inherits the options the user set on the still-chat-less
        // composer. createChat() calls select(), which resets activeChatOptions to the
        // global default, so capture the pending customization first and re-apply +
        // persist it for the freshly created chat.
        let pending = activeChatOptions
        let title = titleHint.map(Self.derivedTitle(from:)) ?? "New Chat"
        let created = try createChat(title: title)
        if pending != storedDefaultOptions() {
            activeChatOptions = pending
            persistChatOptions(pending, for: created.id)
        }
        return created
    }

    private func updateMessage(id: String, content: String, status: MessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            reloadMessages()
            return
        }
        messages[index].content = content
        messages[index].status = status
    }

    /// Attaches resolved citations to the in-memory message so the chat UI can wire
    /// taps without waiting for a full reload (and tolerates a since-deselected chat).
    private func attachCitations(_ citations: [MessageCitation], toMessage id: String) {
        guard !citations.isEmpty,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].citations = citations
    }

    /// Persists `[A#]` legal-research authorities for a finalized message. The ranked
    /// `authorities` are the same capped, ordered packet the model saw, so `[A1]` =
    /// `authorities[0]`. Only labels that actually appear in the answer are stored, so
    /// unused packet entries don't become orphan rows. Returns the domain citations.
    @discardableResult
    private func persistAuthorityCitations(
        messageID: String,
        answer: String,
        authorities: [LegalAuthority]
    ) -> [MessageCitation] {
        guard !authorities.isEmpty else { return [] }
        let present = Self.citationLabels(in: answer)
        var records: [MessageCitationRecord] = []
        for (index, authority) in authorities.enumerated() {
            let label = "A\(index + 1)"
            guard present.contains(label), let url = authority.url, !url.isEmpty else { continue }
            records.append(
                MessageCitationRecord(
                    messageID: messageID,
                    label: label,
                    kind: MessageCitation.Kind.authority.rawValue,
                    url: url,
                    displayName: authority.caseName ?? authority.citation,
                    rank: index
                )
            )
        }
        guard !records.isEmpty else { return [] }
        try? store.chats.replaceCitations(messageID: messageID, records)
        return records.map(MessageCitation.init)
    }

    /// Persists `[S#]` matter-document sources for a finalized message, so a tapped
    /// marker opens the in-app preview at the cited page. Only labels present in the
    /// answer are stored. Returns the domain citations. Chat-attachment `[S#]` (which
    /// carry no document reference) pass an empty `sources` and so persist nothing.
    @discardableResult
    private func persistSourceCitations(
        messageID: String,
        answer: String,
        sources: [GroundedSourceRef]
    ) -> [MessageCitation] {
        guard !sources.isEmpty else { return [] }
        let present = Self.citationLabels(in: answer)
        var records: [MessageCitationRecord] = []
        for (index, source) in sources.enumerated() {
            guard present.contains(source.label) else { continue }
            records.append(
                MessageCitationRecord(
                    messageID: messageID,
                    label: source.label,
                    kind: MessageCitation.Kind.source.rawValue,
                    documentID: source.documentID,
                    locatorJSON: source.locator.encodedJSON(),
                    displayName: source.documentName,
                    matchText: source.excerpt,
                    rank: index
                )
            )
        }
        guard !records.isEmpty else { return [] }
        try? store.chats.replaceCitations(messageID: messageID, records)
        return records.map(MessageCitation.init)
    }

    /// The distinct `[A#]`/`[S#]` citation labels (no brackets) present in an answer.
    static func citationLabels(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\[([AS]\d{1,3})\]"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var labels: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) {
                labels.insert(String(text[r]))
            }
        }
        return labels
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
