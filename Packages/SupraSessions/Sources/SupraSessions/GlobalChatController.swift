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

    /// After a fast-tier grounded answer, offers the deeper pass for the same
    /// question (spec §3.2/§5): the full document pass for doc-grounded answers, or
    /// the CourtListener network search after a local-first research answer.
    /// Transient: cleared on the next send or chat switch.
    public struct DeeperSearchOffer: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case documents, research }
        public let kind: Kind
        public let chatID: String
        public let question: String
    }
    @Published public private(set) var deeperSearchOffer: DeeperSearchOffer?
    private let router: ModelRouter
    private let legalConfiguration: LegalModelConfiguration
    private let courtListenerClient: any CourtListenerClientProtocol
    /// Pluggable statutory-source orchestration (Open Legal Codes today; govinfo / Openlaws /
    /// MCP-backed sources later). Best-effort and lowest-weight — it supplements case law for
    /// statutory questions and never blocks the answer if a source is unavailable.
    private let statutoryOrchestrator: StatutorySourceOrchestrator
    /// Provisions to request from the statutory tier per query.
    private static let maxStatutoryProvisions = 4
    /// Pluggable legal-developments tracking (Federal Register today; OpenStates /
    /// Regulations.gov next). NON-citable — surfaced as a separate "Developments" section.
    private let developmentsOrchestrator: LegalDevelopmentOrchestrator
    private static let maxDevelopments = 5
    private var lastLegalPacketsByChatID: [String: LegalSourcePacket] = [:]
    /// The case each chat is currently discussing (most recent case-shaped
    /// citation lookup) — lets follow-ups the anaphor list misses ("Did Peacock
    /// address laches?") still resolve to the case under discussion.
    private var activeNamedCaseByChatID: [String: String] = [:]
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
                store: store, embedder: embedder, matterID: id, defaultSystemPrompt: defaultSystemPrompt,
                runtimeClient: runtimeClient
            )
        } else {
            self.documentGrounding = nil
        }
        self.legalConfiguration = legalConfiguration
        self.router = ModelRouter(configuration: legalConfiguration)
        let resolvedTokenStore = tokenStore ?? APIKeyStoreComposition.live()
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
        // Codes (free state/USC convenience). Each legal-data provider gets its OWN
        // AuthorizedHTTPClient because the local rate budget is per-client: with one
        // shared client, govinfo's section-text fetches exhausted the shared 5/min
        // budget and starved eCFR/OLC on the next lookup. Budgets remain separate
        // from CourtListener's client as before.
        let makeLegalDataHTTPClient: () -> AuthorizedHTTPClient = {
            AuthorizedHTTPClient(
                keyStore: resolvedTokenStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests),
                redactsQueryValues: !legalConfiguration.logPrivilegedQueryTerms
            )
        }
        self.statutoryOrchestrator = statutoryOrchestrator ?? StatutorySourceOrchestrator(sources: [
            GovInfoStatutorySource(httpClient: makeLegalDataHTTPClient(), tokenStore: resolvedTokenStore),
            ECFRStatutorySource(client: ECFRClient(httpClient: makeLegalDataHTTPClient())),
            OpenLegalCodesStatutorySource(client: OpenLegalCodesClient(httpClient: makeLegalDataHTTPClient()))
        ])
        // Legal-developments tracking. Federal Register is key-less; the others read their API key
        // from the token store and contribute nothing (a note) until the key is set in Settings.
        self.developmentsOrchestrator = developmentsOrchestrator ?? LegalDevelopmentOrchestrator(sources: [
            FederalRegisterSource(client: FederalRegisterClient(httpClient: makeLegalDataHTTPClient())),
            OpenStatesSource(httpClient: makeLegalDataHTTPClient(), tokenStore: resolvedTokenStore),
            RegulationsGovSource(httpClient: makeLegalDataHTTPClient(), tokenStore: resolvedTokenStore)
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
        // The deeper-search offer belongs to the conversation it was made in.
        if deeperSearchOffer?.chatID != chatID { deeperSearchOffer = nil }
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
                message.assuranceState = groundedAssurance(messageID: message.id)
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
        displayPrompt: String? = nil,
        documentDepth: RetrievalDepth = .fast,
        researchDepth: RetrievalDepth = .fast
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
                displayPrompt: displayPrompt,
                documentDepth: documentDepth,
                researchDepth: researchDepth
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
            let history = selectedChatID.map { replayHistory(chatID: $0) } ?? []
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

    /// A persistent, out-of-band warning for document-grounded chat. Generation
    /// completion is only a transport state; this banner records whether each
    /// proposition actually cleared deterministic source verification.
    nonisolated static func documentSupportBanner(_ report: DocumentSupportReport) -> String? {
        guard report.requiresReview else { return nil }
        var lines = [
            "",
            "---",
            "",
            "⚠️ **Document support check — verify before relying on this answer.**",
        ]
        let warnings = report.warnings.isEmpty
            ? ["Proposition support could not be established from the cited document text."]
            : report.warnings
        for warning in warnings { lines.append("- \(warning)") }
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
        displayPrompt: String? = nil,
        documentDepth: RetrievalDepth = .fast,
        researchDepth: RetrievalDepth = .fast
    ) async {
        isGenerating = true
        errorMessage = nil
        deeperSearchOffer = nil
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
                ? await documentGrounding?.groundedContext(
                    forQuestion: prompt,
                    depth: documentDepth,
                    modelID: modelID,
                    options: options
                )
                : nil

            if grounded == nil, let route, route.usesOneShotLegalWorkflow {
                try await performLegalOneShotSend(
                    prompt: prompt,
                    modelPrompt: modelPrompt,
                    displayContent: displayContent,
                    modelID: modelID,
                    route: route,
                    systemPrompt: systemPrompt,
                    options: options,
                    researchDepth: researchDepth
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
            let history = grounded == nil ? replayHistory(chatID: chatID) : []

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

            if grounded?.packingReport?.canPack == false {
                try store.chats.appendToken(
                    to: variant.id,
                    token: Self.groundedContextOverflowRefusal
                )
                try store.chats.completeVariant(variant.id)
                try store.generation.completeGeneration(generationID: session.id)
                updateMessage(
                    id: assistant.id,
                    content: Self.groundedContextOverflowRefusal,
                    status: .completed
                )
                reloadMessages()
                return
            }

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
            var groundingVerification: DocumentSupportReport?

            generationEvents: for try await event in try runtimeClient.generate(request) {
                switch event.type {
                case .token:
                    guard let token = event.tokenText else { break }
                    // Grounded tokens stay transient until the terminal metrics
                    // prove the packet did not overflow. This lets the refusal
                    // replace discarded model output instead of following it.
                    if grounded == nil {
                        try store.chats.appendToken(to: variant.id, token: token)
                    }
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
                    if grounded != nil, finalMetrics?.contextOverflowed == true {
                        streamedContent = Self.groundedContextOverflowRefusal
                        try store.chats.appendToken(to: variant.id, token: streamedContent)
                        try store.chats.completeVariant(variant.id)
                        try store.generation.completeGeneration(
                            generationID: session.id,
                            metrics: storedMetrics(from: finalMetrics)
                        )
                        logGenerationTiming(finalMetrics, generationID: session.id)
                        updateMessage(id: assistant.id, content: streamedContent, status: .completed)
                        break generationEvents
                    }
                    if grounded != nil, !streamedContent.isEmpty {
                        try store.chats.appendToken(to: variant.id, token: streamedContent)
                    }
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
                    // Proposition support check — resolved labels are structural only.
                    // The warning is appended and persisted out-of-band so source text
                    // cannot instruct the model to suppress it.
                    if !groundingSources.isEmpty {
                        let report = try? DocumentSupportVerifier.verify(
                            answer: answerText,
                            sources: groundingSources.map { source in
                                DocumentSupportSource(
                                    sourceID: source.sourceID,
                                    label: source.label,
                                    locator: source.locator.encodedJSON(),
                                    text: source.supportText,
                                    lowConfidence: source.lowConfidence
                                )
                            },
                            scopeFullyIndexed: groundingScopeFullyIndexed
                        )
                        groundingVerification = report
                        let banner = report.flatMap(Self.documentSupportBanner) ?? """

                        ---

                        ⚠️ **Document support check — verify before relying on this answer.**
                        - Proposition verification could not be completed.
                        """
                        if report == nil || report?.requiresReview == true {
                            try? store.chats.appendToken(to: variant.id, token: banner)
                            streamedContent += banner
                        }
                    }
                    try store.chats.completeVariant(variant.id)
                    try store.generation.completeGeneration(
                        generationID: session.id,
                        metrics: storedMetrics(from: finalMetrics)
                    )
                    logGenerationTiming(finalMetrics, generationID: session.id)
                    if let grounded {
                        try persistGroundedDocumentPacket(
                            messageID: assistant.id,
                            question: prompt,
                            context: grounded,
                            verification: groundingVerification
                        )
                        updateMessageAssurance(
                            id: assistant.id,
                            state: Self.groundedAssurance(
                                depth: grounded.depth,
                                verificationStatus: groundingVerification?.verificationStatus
                            )
                        )
                    }
                    let citations = persistSourceCitations(
                        messageID: assistant.id,
                        answer: answerText,
                        sources: groundingSources
                    )
                    updateMessage(id: assistant.id, content: streamedContent, status: .completed)
                    attachCitations(citations, toMessage: assistant.id)
                    // A fast-tier grounded answer is preliminary: offer the deep pass
                    // for the same question (spec §3.2). Auto-escalated or deep passes
                    // carry .deep and offer nothing.
                    if grounded?.depth == .fast, !groundingSources.isEmpty {
                        deeperSearchOffer = DeeperSearchOffer(kind: .documents, chatID: chatID, question: prompt)
                    }

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
        options: GenerationOptions,
        researchDepth: RetrievalDepth = .fast
    ) async throws {
        let chatID = try ensureSelectedChat(titleHint: prompt).id
        let priorAssistantDraft = latestAssistantDraft()
        // Replay prior turns so legal follow-ups ("now narrow that to the 9th Cir.",
        // "apply that rule to my facts") resolve in context. Captured before the new
        // user message is appended; the runtime's budget guard trims it if the packet
        // + question leave no room.
        let history = replayHistory(chatID: chatID)

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
                classificationText: prompt,
                chatID: chatID,
                modelID: modelID,
                generationID: generationID,
                route: route,
                systemPrompt: systemPrompt,
                options: options,
                history: history,
                priorAssistantDraft: priorAssistantDraft,
                researchDepth: researchDepth
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
        classificationText: String? = nil,
        chatID: String,
        modelID: ModelID?,
        generationID: GenerationID,
        route: ModelRoute,
        systemPrompt: String?,
        options: GenerationOptions,
        history: [GenerateRequest.Turn],
        priorAssistantDraft: String?,
        researchDepth: RetrievalDepth = .fast
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
            // Strip app-appended furniture (the local-first "Preliminary" footer)
            // before verifying: its own wording reads as an uncited proposition
            // with a quoted button label, so /verify would flag the app, not the
            // answer.
            let answerToVerify = Self.strippingAssistantFurniture(
                typedIsContent ? typed : (priorDraft.isEmpty ? typed : priorDraft)
            )

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

            // Persisted packets are audit-safe (opinion text stripped), so after an
            // app restart the quote check would have nothing to search. Refill text
            // from the matter's saved authorities, then a capped network fetch —
            // spent on the authorities the answer actually cites first.
            let hydration = await rehydratedForVerification(
                latestLegalSourcePacket(chatID: chatID),
                answer: answerToVerify
            )
            let packet = hydration.packet
            let report = LegalCitationVerifier.verify(
                answer: answerToVerify,
                authorities: packet.authorities,
                requiresSupportedAuthority: route.requiresCitations,
                sourceFailuresByAuthorityID: hydration.failuresByAuthorityID
            )
            let preface = packet.authorities.isEmpty
                ? "No source packet is available for this chat. Run `/research` in a matter chat first, or paste source-supported text with citations for a limited citation check.\n\n"
                : "Verified against the latest source packet\(packet.researchSessionID.map { " (research session \($0))" } ?? "").\n\n"
            let resolution = await citationResolutionSection(for: answerToVerify)
            return LegalWorkflowResult(
                output: preface + LegalCitationVerifier.markdownReport(report) + resolution,
                queryTerms: packet.queryTerms,
                authorities: packet.authorities,
                verification: report,
                researchSessionID: packet.researchSessionID
            )

        case .legalResearch, .legalQA:
            return try await legalResearchOutput(
                prompt: prompt,
                classificationText: classificationText,
                chatID: chatID,
                modelID: modelID,
                generationID: generationID,
                route: route,
                systemPrompt: systemPrompt,
                options: options,
                history: history,
                researchDepth: researchDepth
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
        classificationText: String? = nil,
        chatID: String,
        modelID: ModelID?,
        generationID: GenerationID,
        route: ModelRoute,
        systemPrompt: String?,
        options: GenerationOptions,
        history: [GenerateRequest.Turn],
        researchDepth: RetrievalDepth = .fast
    ) async throws -> LegalWorkflowResult {
        // Classify from the USER'S QUESTION only. The model prompt may carry an
        // attachments block whose first citation, statute keywords, or sheer bulk
        // would otherwise hijack the citation lookup, authority type, and search
        // terms. The full prompt (with attachments) still drives generation.
        let questionForClassification = classificationText ?? prompt
        // An anaphoric follow-up ("what about the dissent?") is still about the
        // case named earlier — inherit that citation so retrieval targets the
        // case (instead of searching the follow-up's words) and the named-case
        // verification exemption survives the turn.
        var baseClassification = Self.classificationInheritingNamedCase(
            LegalQueryClassifier.classify(questionForClassification),
            prompt: questionForClassification,
            history: history,
            activeAuthority: activeNamedCaseByChatID[chatID]
        )
        // Second net for follow-ups the anaphor/surname signals miss ("why did
        // they rule that way?"): a thinking-off model pass rewrites the
        // follow-up as a self-contained question, which is then classified in
        // the ordinary way. Guarded against hallucinated authorities inside
        // `standaloneRewrittenQuestion`; on any doubt the raw prompt stands.
        if baseClassification.citationLookup == nil,
           let modelID,
           !history.isEmpty,
           Self.looksLikeWeakFollowUp(questionForClassification),
           let rewritten = await standaloneRewrittenQuestion(
               followUp: questionForClassification,
               history: history,
               route: route,
               modelID: modelID
           ) {
            baseClassification = Self.classificationInheritingNamedCase(
                LegalQueryClassifier.classify(rewritten),
                prompt: rewritten,
                history: history,
                activeAuthority: activeNamedCaseByChatID[chatID]
            )
        }
        // Remember the case this chat is now discussing for later follow-ups —
        // and CLEAR it when the discussion pivots to a statute or other
        // non-case citation, so a stale surname can't resurrect a dead topic.
        if let lookup = baseClassification.citationLookup {
            activeNamedCaseByChatID[chatID] = Self.isCaseShapedLookup(lookup) ? lookup : nil
        }
        let scopedClassification = classificationApplyingChatJurisdiction(
            classificationApplyingMatterScope(baseClassification),
            prompt: questionForClassification,
            history: history
        )
        // A "who sued X / litigation involving X" question is a factual docket lookup, not a
        // legal-authority question — answer it from RECAP dockets, with no jurisdiction gate
        // and no citation verifier (dockets are filings, not authority).
        if scopedClassification.desiredAuthorityType == .docket {
            return await caseFinderOutput(for: scopedClassification)
        }

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
        var primaryLawCaveat: String?
        if sourcePlan.requiresPrimaryLaw, citableStatutoryProvisions.isEmpty {
            // A question that PINPOINTS primary law ("what does 18 U.S.C. § 1001
            // require?", a named federal scheme) can only be answered by quoting
            // that law — answering around a missing provision would fabricate
            // statutory text, so it stays hard-blocked. A question that merely
            // SOUNDS statutory ("what's the deadline to respond?") continues on
            // retrieved case law, prominently caveated: a grounded case-law
            // answer beats a refusal, but it must never read as the statute.
            // The target must itself be STATUTORY-shaped: a case caption riding
            // in citationLookup ("the notice deadline in Mullane v. Central
            // Hanover") pinpoints a case, not a provision.
            let citationTarget = (sourcePlan.primaryLawCitationQuery ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pinpointsProvision = !citationTarget.isEmpty && Self.isStatutoryCitationTarget(citationTarget)
            // Limitations-class questions ("what's the deadline…") stay HARD:
            // a stale period quoted from old case law is the malpractice
            // scenario. Exception: a question ABOUT a named case's own
            // limitations discussion is a case question, answerable from the
            // opinion — soft-continue it under the caveat.
            let asksAboutNamedCase = classification.citationLookup.map(Self.isCaseShapedLookup) ?? false
            if pinpointsProvision || (sourcePlan.primaryLawHardBlock && !asksAboutNamedCase) {
                let terms = [sourcePlan.primaryLawQueryTerms].filter { !$0.isEmpty }
                let output = Self.missingPrimaryLawMessage(plan: sourcePlan, notes: statutoryLookup.notes)
                return LegalWorkflowResult(output: output, queryTerms: terms, authorities: [], verification: nil, researchSessionID: nil)
            }
            primaryLawCaveat = Self.primaryLawUnavailableCaveat(notes: sourcePlan.notes + statutoryLookup.notes)
        }

        // Local-first research (spec §4.1/§4.4, locked §8.5): with ≥1 saved authority,
        // answer preliminarily from the matter's own library before any network call —
        // preserving CourtListener quota and mirroring the document fast/deep shape.
        // The deep tier (researchDepth == .deep, the "Search CourtListener" offer)
        // skips this branch and searches the network.
        let retrieval: (queryTerms: [String], authorities: [LegalAuthority], researchSessionID: String?)
        var answeredFromSavedAuthorities = false
        if researchDepth == .fast, let local = localAuthorityRetrieval(for: classification) {
            retrieval = local
            answeredFromSavedAuthorities = true
        } else {
            do {
                retrieval = try await retrieveAuthorities(for: classification, route: route, modelID: modelID, matterID: scopedMatterID)
            } catch {
                // Network down or rate-limited: the matter's own library is still
                // a grounded source — better a local answer than a dead send,
                // even on the deep tier.
                if let local = localAuthorityRetrieval(for: classification) {
                    retrieval = local
                    answeredFromSavedAuthorities = true
                } else if !statutoryLookup.provisions.isEmpty {
                    retrieval = ([], [], nil)
                } else {
                    throw error
                }
            }
        }
        // Saved authorities already carry their persisted opinion text — hydrating
        // them again would defeat the local tier's no-network promise.
        let rankedBase = LegalAuthorityRanker.rank(retrieval.authorities, for: classification)
        let rankedAll = answeredFromSavedAuthorities
            ? rankedBase
            : await hydrateTopAuthorities(rankedBase, citationLookup: classification.citationLookup)
        // Cap to exactly the packet the model is shown. buildAnswerPrompt caps the
        // SOURCE PACKET at maxPacketAuthorities, so the model only ever sees
        // [A1]…[A maxPacketAuthorities]. The verifier and the stored packet (used by
        // /verify) must use the SAME capped set — otherwise a fabricated [A13+] label
        // pointing at an authority that was never in the prompt would pass as grounded.
        // Packet construction is source-plan driven: primary law leads when present,
        // and statutory/legal-rule questions are blocked before this point if primary
        // law was required but unavailable.
        var ranked = StatutoryPacketMerge.merge(
            statutoryProvisions: citableStatutoryProvisions,
            rankedCases: rankedAll,
            jurisdictionLabel: classification.jurisdiction,
            cap: LegalResearchPromptBuilder.maxPacketAuthorities,
            citation: sourcePlan.primaryLawCitationQuery ?? classification.citationLookup,
            queryTerms: sourcePlan.primaryLawQueryTerms
        )
        var authorities = ranked.map(\.authority)
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
            I searched CourtListener's published **opinions** (case law) and didn't find authority matching this query, so I can't give a source-grounded legal answer from model memory alone. This means no matching *opinion* was found — not that no law or litigation on the topic exists.

            Search terms used:
            \(retrieval.queryTerms.map { "- \($0)" }.joined(separator: "\n"))

            You can try: rephrasing or narrowing the issue; naming the jurisdiction or court; or — if you're looking for *filed cases* involving a person or company — asking "who has sued [name]" to search the dockets instead.
            """
            // The primary-law miss still matters even when case law came up
            // empty — without the caveat this read as a pure case-law miss.
            let output = (primaryLawCaveat.map { $0 + "\n\n" } ?? "") + message
            return LegalWorkflowResult(
                output: output,
                queryTerms: queryTerms,
                authorities: [],
                verification: nil,
                researchSessionID: retrieval.researchSessionID
            )
        }

        // On the caveated soft path, the model itself must not present periods
        // or requirements as current law — the instruction rides the question.
        let answerQuestion = primaryLawCaveat == nil
            ? prompt
            : prompt + "\n\n(Note: the governing statute/rule text could NOT be retrieved. Do not state any limitations period, deadline, or statutory requirement as current law — attribute every date- or period-bearing statement to its cited case and that case's year, and say plainly that the primary law was not retrieved.)"
        let answerPrompt = LegalResearchPromptBuilder.buildAnswerPrompt(
            question: answerQuestion,
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
        var verificationPacket = packet
        var hydration = await rehydratedForVerification(verificationPacket, answer: output)
        verificationPacket = hydration.packet
        authorities = verificationPacket.authorities
        for index in ranked.indices where index < authorities.count {
            ranked[index].authority = authorities[index]
        }
        lastLegalPacketsByChatID[chatID] = verificationPacket
        // A question that NAMES its authority ("What is the holding of X?") is about
        // that case wherever it sits — the matter's forum must not veto quoting it.
        let verificationJurisdiction = classification.citationLookup == nil ? classification.jurisdiction : nil
        var verification = legalConfiguration.verifyCitations
            ? LegalCitationVerifier.verify(
                answer: output,
                authorities: authorities,
                expectedJurisdiction: verificationJurisdiction,
                requiresSupportedAuthority: route.requiresCitations,
                sourceFailuresByAuthorityID: hydration.failuresByAuthorityID
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
                question: answerQuestion, classification: classification, rankedAuthorities: ranked,
                authorityPriority: sourcePlan.authorityPriority,
                priorAnswer: output, issues: failed.issues
            )
            let revisionRequest = GenerateRequest(
                generationID: generationID, modelID: modelID, prompt: revisionPrompt,
                systemPrompt: systemPrompt, history: history, options: options
            )
            if let revisedRaw = try? await runtimeClient.collectGeneratedText(revisionRequest) {
                let revised = ReasoningContent.answer(from: revisedRaw)
                hydration = await rehydratedForVerification(verificationPacket, answer: revised)
                verificationPacket = hydration.packet
                authorities = verificationPacket.authorities
                for index in ranked.indices where index < authorities.count {
                    ranked[index].authority = authorities[index]
                }
                lastLegalPacketsByChatID[chatID] = verificationPacket
                let revisedVerification = LegalCitationVerifier.verify(
                    answer: revised,
                    authorities: authorities,
                    expectedJurisdiction: verificationJurisdiction,
                    requiresSupportedAuthority: route.requiresCitations,
                    sourceFailuresByAuthorityID: hydration.failuresByAuthorityID
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

        // A local-first answer is preliminary (spec §5): label it honestly and offer
        // the network search — never silently pass saved-library coverage off as a
        // full CourtListener pass.
        if answeredFromSavedAuthorities {
            output += "\n\n_Preliminary — answered from this matter's saved authorities. Use “Search CourtListener” below for a wider search._"
            deeperSearchOffer = DeeperSearchOffer(kind: .research, chatID: chatID, question: prompt)
        }

        // The caveat leads the answer — the reader must see "no primary law was
        // retrieved" before any case-law discussion of a deadline or requirement.
        if let primaryLawCaveat {
            output = primaryLawCaveat + "\n\n" + output
        }

        return LegalWorkflowResult(
            output: output,
            queryTerms: queryTerms,
            authorities: authorities,
            verification: verification,
            researchSessionID: retrieval.researchSessionID
        )
    }

    /// Removes app-appended lines from a stored assistant answer before /verify
    /// re-checks it. The local-first "Preliminary" footer, the "⚠️" banners
    /// (primary-law caveat, unverified-draft), and their blockquote continuation
    /// lines are the APP talking, not the model citing law — left in, their
    /// quoted labels and uncited sentences false-flag every /verify.
    static func strippingAssistantFurniture(_ answer: String) -> String {
        answer
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("_Preliminary — answered from")
                    && !trimmed.hasPrefix("> ⚠️")
                    && !trimmed.hasPrefix("> Retrieval notes:")
                    && trimmed != ">"
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Banner prepended to a legal answer whose citations failed verification, so
    /// the user cannot mistake it for verified good law.
    static let unverifiedDraftBanner = """
    > ⚠️ **UNVERIFIED DRAFT — DO NOT RELY.** Automated citation verification found unsupported or mismatched authority below. Independently verify every citation, quotation, and holding before use.

    """

    static func blockedLegalResearchMessage(report: LegalVerificationReport) -> String {
        let issueSummary = report.issues.map { issue in
            "- \(issue.kind.rawValue): \(issue.message)"
        }.joined(separator: "\n")
        return """
        I cannot provide a source-grounded legal answer from the retrieved packet because automated verification still found unsupported or mismatched authority after repair.

        Verification warnings:
        \(issueSummary)
        """
    }

    /// Whether a primary-law citation target actually names STATUTORY law
    /// (U.S.C./C.F.R./§/a statutes-or-code reference) as opposed to a case
    /// caption or reporter cite that rode in through `citationLookup`.
    static func isStatutoryCitationTarget(_ target: String) -> Bool {
        let lower = target.lowercased()
        if lower.contains("§") || lower.contains("u.s.c") || lower.contains("c.f.r") { return true }
        if lower.range(of: #"(?i)\b\d{1,4}\s+(?:u\.?\s?s\.?\s?c\.?|c\.?\s?f\.?\s?r\.?)\b"#, options: .regularExpression) != nil { return true }
        return lower.range(of: #"(?i)\b(?:stat(?:s\.|utes|\.)|code)\b"#, options: .regularExpression) != nil
    }

    /// Leads a case-law-only answer to a question that SOUNDED statutory
    /// ("deadline", "notice requirement") when no citable primary law could be
    /// retrieved. The soft complement to `missingPrimaryLawMessage`, which stays
    /// a hard block for questions that pinpoint a specific provision.
    static func primaryLawUnavailableCaveat(notes: [String]) -> String {
        var caveat = "> ⚠️ **Primary law not retrieved.** This question likely turns on a statute, rule, or regulation, but no citable primary-law text could be retrieved, so the answer below is grounded in retrieved case law only. Verify the controlling statute or rule before relying on any deadline, limitations period, or filing requirement."
        let meaningful = notes.filter { !$0.isEmpty }
        if !meaningful.isEmpty {
            caveat += "\n>\n> Retrieval notes: " + meaningful.joined(separator: "; ")
        }
        return caveat
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

    static let groundedContextOverflowRefusal = "I can’t provide a source-grounded answer because the complete instruction and evidence packet does not fit this model’s context window. Use fewer sources or a model with a larger context window, then try again."

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
            case .unsupportedCitation, .unsupportedQuote,
                 .unverifiableProposition, .unverifiableQuote,
                 .missingCitation, .noRetrievedAuthorities:
                return true
            case .jurisdictionMismatch:
                return route.requiresJurisdiction
            case .ungroundedEntity:
                // Document-entity diagnostics are advisory and do not participate
                // in the legal proposition firewall.
                return false
            }
        }.count
    }

    /// True when at least one detected citation is actually supported by the
    /// retrieved authority packet (i.e. not flagged as unsupported).
    static func hasSupportedCitation(_ report: LegalVerificationReport) -> Bool {
        report.supportResults.contains { $0.status == .supported }
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
    private func hydrateTopAuthorities(
        _ ranked: [RankedLegalAuthority],
        citationLookup: String? = nil
    ) async -> [RankedLegalAuthority] {
        var result = ranked
        // The named case must carry full text wherever it ranked — a snippet-only
        // body cannot contain the holding the user asked about.
        var indices = Array(result.indices.prefix(Self.maxHydratedAuthorities))
        if let lookup = citationLookup?.trimmingCharacters(in: .whitespacesAndNewlines), !lookup.isEmpty,
           let namedIndex = result.indices.first(where: { LegalCitationMatch.authority(result[$0].authority, matchesLookup: lookup) }),
           !indices.contains(namedIndex) {
            indices.append(namedIndex)
        }
        for index in indices {
            guard let opinionID = result[index].authority.opinionId.flatMap(Int.init) else { continue }
            guard
                let detail = try? await courtListenerClient.fetchOpinion(id: opinionID),
                let body = detail.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !body.isEmpty
            else { continue }
            result[index].authority.text = body
            result[index].authority.textKind = .fullText
            // Already-fetched text is free to keep: persist it on a matching SAVED
            // authority (spec §4.3, §8.3 — saved only) so future local-first answers
            // and the offline reader don't re-fetch.
            persistHydratedTextIfSaved(opinionID: result[index].authority.opinionId, body: body)
        }
        return result
    }

    private func persistHydratedTextIfSaved(opinionID: String?, body: String) {
        guard let opinionID, let matterID = scopedMatterID else { return }
        guard let saved = (try? store.authorities.fetchAuthorities(matterID: matterID))?
            .first(where: { $0.opinionID == opinionID && $0.opinionText == nil }) else { return }
        try? store.authorities.updateOpinionText(authorityID: saved.id, text: body)
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
            limit: Self.maxDevelopments,
            dateAfter: classification.dateFiledAfter,
            dateBefore: classification.dateFiledBefore
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
        var primaryRequests: [CourtListenerSearchRequest] = []
        // Citation-first: when the prompt cites a specific authority, look it up directly
        // (via CourtListener's citation filter) so the cited case is retrieved even if the
        // planner's keyword queries wouldn't surface it.
        if let citation = classification.citationLookup?.trimmingCharacters(in: .whitespacesAndNewlines), !citation.isEmpty {
            primaryRequests.append(courtListenerRequest(for: classification, adverse: false))
        }
        if plannedQueries.isEmpty {
            if primaryRequests.isEmpty {
                primaryRequests.append(courtListenerRequest(for: classification, adverse: false))
            }
        } else {
            primaryRequests.append(contentsOf: plannedQueries.prefix(Self.maxChatPlannerQueries).map {
                plannerRequest(query: $0, classification: classification)
            })
        }
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
                // With citation-first + planner queries there are several non-adverse
                // requests; one transient failure (e.g. a 429 on the narrow citation
                // query) must not abort the broader queries behind it. Only give up
                // early when no request can possibly succeed.
                if case CourtListenerError.missingToken = error {
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

    /// Answers a party/litigation-lookup question ("who has sued X") from CourtListener's
    /// RECAP dockets — a factual case list, not legal authority, so it skips the source
    /// packet and the citation verifier entirely.
    private func caseFinderOutput(for classification: LegalQueryClassification) async -> LegalWorkflowResult {
        let party = classification.partyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasParty = (party?.isEmpty == false)
        let request = CourtListenerSearchRequest(
            query: hasParty ? party! : classification.legalIssue,
            searchType: .recap,
            orderBy: "dateFiled desc",
            courtIDs: classification.courtIDs,
            dateFiledAfter: classification.dateFiledAfter,
            dateFiledBefore: classification.dateFiledBefore,
            partyName: hasParty ? party : nil
        )
        let terms = [request.query]
        do {
            let response = try await courtListenerClient.searchDockets(request)
            let dockets = Array(response.results.prefix(Self.maxCaseFinderResults))
            let output = dockets.isEmpty
                ? Self.caseFinderEmptyMessage(party: hasParty ? party : nil)
                : Self.formatCaseList(dockets, party: hasParty ? party : nil, total: response.count)
            return LegalWorkflowResult(output: output, queryTerms: terms, authorities: [], verification: nil, researchSessionID: nil)
        } catch {
            return LegalWorkflowResult(output: Self.caseFinderErrorMessage(error), queryTerms: terms, authorities: [], verification: nil, researchSessionID: nil)
        }
    }

    private static let maxCaseFinderResults = 15

    /// ADDITIVE live-resolution check for `/verify`: extracts citation strings locally
    /// and asks CourtListener whether each resolves to a real, published opinion.
    /// PRIVACY: only the extracted cite strings leave the device — never the answer or
    /// prompt text. Failures degrade to a short unavailable note; the offline packet
    /// verifier above remains the gate.
    private func citationResolutionSection(for answer: String) async -> String {
        let citations = Array(Set(LegalCitationVerifier.extractCitationLikeStrings(from: answer))).sorted()
        guard !citations.isEmpty else { return "" }
        let capped = Array(citations.prefix(Self.maxCitationResolutionLookups))
        do {
            let results = try await courtListenerClient.resolveCitations(capped)
            guard !results.isEmpty else { return "" }
            var lines = [
                "",
                "---",
                "",
                "**Citation resolution (CourtListener).** Whether each cite resolves to a real, published opinion. A resolved cite is not necessarily good law; an unresolved one may be fabricated, mistyped, or outside CourtListener's corpus:"
            ]
            for result in results {
                let cite = result.citation.isEmpty ? "(unparsed citation)" : result.citation
                if result.resolved {
                    let cluster = result.clusters.first
                    let name = cluster?.caseName ?? "matching opinion"
                    if let path = cluster?.absoluteURL, let url = Self.courtListenerURL(path) {
                        lines.append("- ✅ \(cite) → [\(name)](\(url))")
                    } else {
                        lines.append("- ✅ \(cite) → \(name)")
                    }
                } else {
                    lines.append("- ⚠️ \(cite) — did not resolve to a published opinion")
                }
            }
            return "\n" + lines.joined(separator: "\n")
        } catch {
            return "\n\n_Live citation resolution unavailable (\(error.localizedDescription))._"
        }
    }

    private static let maxCitationResolutionLookups = 20

    private static func formatCaseList(_ dockets: [CourtListenerSearchResultDTO], party: String?, total: Int) -> String {
        let target = party.map { "“\($0)”" } ?? "your query"
        var lines = [
            "Found \(total) case\(total == 1 ? "" : "s") in CourtListener's RECAP/PACER **docket** records matching \(target). These are court **filings** — a factual record of who filed what, **not legal authority** (a filing is not precedent). Verify anything you rely on against the docket itself.",
            ""
        ]
        for docket in dockets {
            let name = docket.caseName ?? docket.caseNameFull ?? "Case"
            var parts = ["**\(name)**"]
            if let court = docket.court, !court.isEmpty { parts.append(court) }
            if let filed = docket.dateFiled, !filed.isEmpty { parts.append("filed \(filed)") }
            if let number = docket.docketNumber, !number.isEmpty { parts.append("No. \(number)") }
            var line = "- " + parts.joined(separator: " · ")
            if let url = docket.absoluteURL, let full = Self.courtListenerURL(url) {
                line += " — [view](\(full))"
            }
            lines.append(line)
        }
        if total > dockets.count {
            lines.append("")
            lines.append("Showing the \(dockets.count) most recent of \(total). This is a docket search, not a conflicts check or a complete litigation history.")
        }
        return lines.joined(separator: "\n")
    }

    private static func courtListenerURL(_ path: String) -> String? {
        if path.lowercased().hasPrefix("http") { return path }
        guard path.hasPrefix("/") else { return nil }
        return "https://www.courtlistener.com" + path
    }

    private static func caseFinderEmptyMessage(party: String?) -> String {
        let target = party.map { "“\($0)”" } ?? "that query"
        return "I searched CourtListener's RECAP/PACER **docket** records for \(target) and found no matching federal cases. That doesn't mean none exist — RECAP covers federal filings uploaded to CourtListener, not every court and not state courts, and the party may be recorded under a different name. Try the exact entity name, or search PACER / the relevant state docket directly."
    }

    private static func caseFinderErrorMessage(_ error: Error) -> String {
        "I couldn't reach CourtListener's docket search just now: \(error.localizedDescription). Check the CourtListener connection in Settings and try again."
    }

    /// Builds a research retrieval from the matter's SAVED authorities (spec §4.2):
    /// project each saved record to a `LegalAuthority` and rank with the same ranker
    /// as network results. Returns nil — falling through to CourtListener — when the
    /// chat has no matter, the library is empty, nothing ranked has persisted opinion
    /// text to ground from ("locals strong enough", §4.4), or the prompt cites a
    /// specific authority the library doesn't hold.
    private func localAuthorityRetrieval(
        for classification: LegalQueryClassification
    ) -> (queryTerms: [String], authorities: [LegalAuthority], researchSessionID: String?)? {
        guard let matterID = scopedMatterID,
              ((try? store.authorities.countAuthorities(matterID: matterID)) ?? 0) >= 1 else { return nil }
        let saved = (try? store.authorities.fetchAuthorities(matterID: matterID)) ?? []
        let locals = saved.map(Self.savedLegalAuthority)
        // A cited case the library doesn't hold must go to the network — a local
        // answer that misses the very authority the user named would be wrong.
        // Token-aware matching: the user types the SHORT caption ("Peacock v.
        // Thomas"); the saved record carries the full one.
        if let cite = classification.citationLookup?.trimmingCharacters(in: .whitespacesAndNewlines), !cite.isEmpty {
            let holders = locals.filter { LegalCitationMatch.authority($0, matchesLookup: cite) }
            guard !holders.isEmpty else { return nil }
            // Held, but with NO persisted opinion text: the grounded filter below
            // would silently drop the very case the user asked about and answer
            // from the rest of the library. Go to the network instead, which
            // retrieves the case, hydrates it, and persists the text back onto
            // the saved record for next time.
            guard holders.contains(where: { !($0.text ?? "").isEmpty }) else { return nil }
        }
        let ranked = LegalAuthorityRanker.rank(locals, for: classification)
        let grounded = ranked.filter { !($0.authority.text ?? "").isEmpty }
        guard !grounded.isEmpty else { return nil }
        return (
            queryTerms: [classification.legalIssue],
            authorities: grounded.map(\.authority),
            researchSessionID: nil
        )
    }

    /// A saved `AuthorityRecord` projected back to a `LegalAuthority` so local
    /// results flow through the same ranking/packet/verifier machinery as network
    /// results (spec §4.2).
    static func savedLegalAuthority(_ record: AuthorityRecord) -> LegalAuthority {
        let citations = (try? JSONDecoder().decode([String].self, from: Data(record.citationJSON.utf8))) ?? []
        return LegalAuthority(
            id: record.clusterID ?? record.id,
            source: .courtlistener,
            authorityType: .case,
            caseName: record.caseNameFull ?? record.caseName,
            citation: record.preferredCitation ?? citations.first,
            citations: citations,
            court: record.court,
            courtID: record.courtID,
            dateFiled: record.dateFiled.map { Self.isoDayFormatter.string(from: $0) },
            precedentialStatus: record.precedentialStatus,
            url: record.absoluteURL.flatMap(Self.courtListenerURL),
            snippet: record.opinionText.map { String($0.prefix(280)) },
            text: record.opinionText,
            textKind: record.opinionText == nil ? nil : .fullText,
            clusterId: record.clusterID,
            opinionId: record.opinionID,
            docketNumber: record.docketNumber
        )
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

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

    /// A CourtListener request for a planner-generated query, carrying the classification's
    /// court/date filters. No citation filter: planner queries find RELATED authority; the
    /// dedicated citation-first request (above) retrieves the specifically-cited case.
    private func plannerRequest(query: String, classification: LegalQueryClassification) -> CourtListenerSearchRequest {
        CourtListenerSearchRequest(
            query: query,
            orderBy: "score desc",
            courtIDs: classification.courtIDs,
            dateFiledAfter: classification.dateFiledAfter,
            dateFiledBefore: classification.dateFiledBefore
        )
    }

    private func courtListenerRequest(for classification: LegalQueryClassification, adverse: Bool) -> CourtListenerSearchRequest {
        // A request that NAMES a specific case must not be court- or date-bounded:
        // those filters bound TOPICAL searches, but the named case pins itself —
        // an out-of-forum cite (sister state, another circuit) would otherwise be
        // structurally unretrievable, and a "recent"-triggered date floor would
        // filter out the very (older) case being asked about. Case names go to
        // the case_name parameter; reporter cites to the citation filter.
        // Only a lookup that pins a specific CASE (a caption or reporter cite)
        // unbounds the request — a §-statute cite is a topic, not a case, and
        // keeps the forum-bounded search below.
        if !adverse,
           let lookup = classification.citationLookup?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lookup.isEmpty,
           LegalCitationMatch.isCaseNameLookup(lookup) || Self.courtListenerCitationParameter(lookup) != nil {
            let isName = LegalCitationMatch.isCaseNameLookup(lookup)
            // "Rush v. Savchuk, 444 U.S. 320" splits into name + reporter cite.
            let nameOnly = lookup.replacingOccurrences(
                of: #",\s*\d.*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let reporterTail = lookup.range(of: #"\d{1,4}\s+[A-Za-z. ]{1,30}\s+\d{1,5}\s*$"#, options: .regularExpression)
                .map { String(lookup[$0]) }
            return CourtListenerSearchRequest(
                query: courtListenerQuery(for: classification, adverse: false),
                orderBy: "score desc",
                citation: isName ? reporterTail : Self.courtListenerCitationParameter(lookup),
                caseName: isName ? nameOnly : nil
            )
        }
        return CourtListenerSearchRequest(
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

    private struct LegalVerificationHydration {
        var packet: LegalSourcePacket
        var failuresByAuthorityID: [String: LegalAuthorityTextFailure]
    }

    private struct LegalAuthorityHydrationAttempt: Sendable {
        var index: Int
        var body: String?
        var failure: LegalAuthorityTextFailure?
    }

    /// Refills every authority cited by this exact answer. Saved matter text is
    /// preferred; remaining CourtListener opinions are fetched in batches of four.
    /// Failures are retained per authority and passed to the proposition verifier,
    /// so a missing ID, empty response, cancellation, or network error cannot become
    /// clean merely because the packet label exists.
    private func rehydratedForVerification(
        _ packet: LegalSourcePacket,
        answer: String = ""
    ) async -> LegalVerificationHydration {
        var authorities = packet.authorities
        let citedIndices = LegalCitationVerifier.citedAuthorityIndices(
            in: answer,
            authorities: authorities
        )
        guard !citedIndices.isEmpty else {
            return LegalVerificationHydration(packet: packet, failuresByAuthorityID: [:])
        }
        let saved: [AuthorityRecord] = scopedMatterID
            .flatMap { try? store.authorities.fetchAuthorities(matterID: $0) } ?? []
        var failures: [String: LegalAuthorityTextFailure] = [:]

        for index in citedIndices where !LegalCitationVerifier.hasVerifiableSourceText(authorities[index]) {
            let authority = authorities[index]
            let exact = saved.first { record in
                guard record.opinionText?.isEmpty == false else { return false }
                if let clusterID = record.clusterID, clusterID == authority.clusterId { return true }
                if let opinionID = record.opinionID, opinionID == authority.opinionId { return true }
                return false
            }
            let caption = exact ?? saved.first { record in
                guard record.opinionText?.isEmpty == false else { return false }
                // Present-but-different IDs disqualify the caption fallback.
                if let clusterID = record.clusterID, let authorityCluster = authority.clusterId,
                   clusterID != authorityCluster { return false }
                if let opinionID = record.opinionID, let authorityOpinion = authority.opinionId,
                   opinionID != authorityOpinion { return false }
                let lookup = authority.caseName ?? authority.citation ?? ""
                return !lookup.isEmpty
                    && LegalCitationMatch.authority(Self.savedLegalAuthority(record), matchesLookup: lookup)
            }
            if let record = caption {
                authorities[index].text = record.opinionText
                authorities[index].textKind = .fullText
            }
        }

        var pending: [(index: Int, opinionID: Int)] = []
        for index in citedIndices where !LegalCitationVerifier.hasVerifiableSourceText(authorities[index]) {
            guard let opinionID = authorities[index].opinionId.flatMap(Int.init) else {
                failures[authorities[index].id] = .missingOpinionID
                continue
            }
            pending.append((index, opinionID))
        }

        let client = courtListenerClient
        let concurrencyLimit = 4
        for batchStart in stride(from: 0, to: pending.count, by: concurrencyLimit) {
            let batchEnd = min(batchStart + concurrencyLimit, pending.count)
            let batch = Array(pending[batchStart..<batchEnd])
            if Task.isCancelled {
                for item in batch {
                    failures[authorities[item.index].id] = .cancelled
                }
                continue
            }
            let attempts = await withTaskGroup(of: LegalAuthorityHydrationAttempt.self) { group in
                for item in batch {
                    let authority = authorities[item.index]
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let detail = try await client.fetchOpinion(id: item.opinionID)
                            guard let body = detail.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !body.isEmpty else {
                                return LegalAuthorityHydrationAttempt(
                                    index: item.index,
                                    body: nil,
                                    failure: .emptyResponse
                                )
                            }
                            var hydrated = authority
                            hydrated.text = body
                            hydrated.textKind = .fullText
                            return LegalAuthorityHydrationAttempt(
                                index: item.index,
                                body: body,
                                failure: LegalCitationVerifier.inferredTextFailure(for: hydrated)
                            )
                        } catch is CancellationError {
                            return LegalAuthorityHydrationAttempt(
                                index: item.index,
                                body: nil,
                                failure: .cancelled
                            )
                        } catch {
                            return LegalAuthorityHydrationAttempt(
                                index: item.index,
                                body: nil,
                                failure: .fetchFailed
                            )
                        }
                    }
                }
                var collected: [LegalAuthorityHydrationAttempt] = []
                for await attempt in group { collected.append(attempt) }
                return collected
            }
            for attempt in attempts {
                let authorityID = authorities[attempt.index].id
                if let body = attempt.body {
                    authorities[attempt.index].text = body
                    authorities[attempt.index].textKind = .fullText
                }
                if let failure = attempt.failure {
                    failures[authorityID] = failure
                } else {
                    failures.removeValue(forKey: authorityID)
                    persistHydratedTextIfSaved(
                        opinionID: authorities[attempt.index].opinionId,
                        body: authorities[attempt.index].text ?? ""
                    )
                }
            }
        }

        let hydratedPacket = LegalSourcePacket(
            queryTerms: packet.queryTerms,
            authorities: authorities,
            researchSessionID: packet.researchSessionID
        )
        return LegalVerificationHydration(
            packet: hydratedPacket,
            failuresByAuthorityID: failures
        )
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
    /// Carries the case a prior USER turn named into an anaphoric follow-up's
    /// classification. "What about the dissent?" re-classified alone yields no
    /// citation lookup, so retrieval ran on the follow-up's words and — because
    /// the named-case verification exemption keys off citationLookup — the
    /// matter's forum could quarantine turn 2 of a discussion turn 1 answered
    /// fine. Restricted to user turns (the assistant's answers cite many cases)
    /// and to prompts that plainly refer back to the discussed case; a follow-up
    /// that names its own authority keeps it.
    static func classificationInheritingNamedCase(
        _ classification: LegalQueryClassification,
        prompt: String,
        history: [GenerateRequest.Turn],
        activeAuthority: String? = nil
    ) -> LegalQueryClassification {
        guard classification.citationLookup == nil else { return classification }
        func inheriting(_ cite: String) -> LegalQueryClassification {
            var inherited = classification
            inherited.citationLookup = cite
            return inherited
        }
        if referencesPriorCase(prompt) {
            // Only the last two user turns: a citation from an older,
            // likely-changed topic must not hijack retrieval. And only
            // CASE-shaped citations — an inherited statute cite would flip a
            // case follow-up into the primary-law pipeline, and a misfire also
            // relaxes the jurisdiction check, so the inherited value must
            // plainly be a case.
            var scanned = 0
            for turn in history.reversed() where turn.role == .user {
                scanned += 1
                if scanned > 2 { break }
                if let cite = LegalQueryClassifier.firstCitation(in: turn.content),
                   isCaseShapedLookup(cite) {
                    return inheriting(cite)
                }
            }
            if let activeAuthority {
                return inheriting(activeAuthority)
            }
        }
        // Surname signal: an interrogative that names a party of the case under
        // discussion ("Did Peacock address laches?") is about that case even
        // though it uses no anaphor. Governmental/corporate caption boilerplate
        // is excluded so "state law claims" can't resurrect Smith v. State.
        if let activeAuthority, isInterrogative(prompt) {
            let lower = prompt.lowercased()
            let distinctive = LegalCitationMatch.significantTokens(in: activeAuthority)
                .filter { !captionBoilerplateTokens.contains($0) }
            if distinctive.contains(where: { token in
                lower.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: token) + #"\b"#, options: .regularExpression) != nil
            }) {
                return inheriting(activeAuthority)
            }
        }
        return classification
    }

    private static func isInterrogative(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let openers = ["what", "why", "how", "when", "who", "did", "does", "do", "is", "was", "were", "can", "could", "would", "should", "explain", "summarize"]
        return openers.contains { lower.hasPrefix($0 + " ") }
    }

    /// Caption tokens too generic to identify a case in running prose.
    private static let captionBoilerplateTokens: Set<String> = [
        "state", "states", "united", "people", "commonwealth", "government",
        "city", "county", "town", "village", "board", "department", "commission",
        "district", "school", "bank", "insurance", "trust", "national", "federal",
        "america", "american", "court", "judge", "sheriff", "warden", "director",
        "secretary", "attorney", "general"
    ]

    /// A caption ("X v. Y", "In re Z") or a bare reporter cite — never a statute
    /// or code reference.
    private static func isCaseShapedLookup(_ cite: String) -> Bool {
        if LegalCitationMatch.isCaseNameLookup(cite) { return true }
        let lower = cite.lowercased()
        if lower.contains("§") || lower.contains("u.s.c") || lower.contains("c.f.r")
            || lower.contains("stat") || lower.contains("code") {
            return false
        }
        return cite.range(of: #"^\d{1,4}\s+[A-Za-z. ]{1,30}\s+\d{1,5}$"#, options: .regularExpression) != nil
    }

    /// Anaphors that only make sense about a specific, already-named decision.
    /// Deliberately narrow: phrasing that is common in genuinely NEW questions
    /// must not pin a topical question to an old case — "this case" reads as
    /// the MATTER in a matter chat, and "the holding"/"the opinion" appear in
    /// topical prompts ("where the holding turned on…", "the opinion testimony").
    /// "In that case, …" is the conditional idiom ("if so"), not a reference.
    private static func referencesPriorCase(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .replacingOccurrences(of: "in that case,", with: "")
        let anaphors = [
            "the dissent", "the majority", "the concurrence", "the plurality",
            "that case", "that decision", "that ruling", "that opinion",
            "that holding", "the syllabus", "the oral argument"
        ]
        return anaphors.contains { lower.contains($0) }
    }

    /// A short prompt leaning on backward references — worth one cheap model
    /// pass to rewrite into a self-contained question before classification.
    static func looksLikeWeakFollowUp(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        return trimmed.lowercased().range(
            of: #"\b(it|that|this|they|them|those|why|same)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// One thinking-off model pass that rewrites a weak follow-up into a
    /// self-contained question (same pattern as the research query planner).
    /// Hallucination guard: a citation in the rewrite that doesn't trace back
    /// to the conversation discards the whole rewrite — the raw prompt stands.
    private func standaloneRewrittenQuestion(
        followUp: String,
        history: [GenerateRequest.Turn],
        route: ModelRoute,
        modelID: ModelID
    ) async -> String? {
        let recent = history.suffix(4)
        let convo = recent.map { turn in
            "\(turn.role == .user ? "User" : "Assistant"): \(String(turn.content.prefix(400)))"
        }.joined(separator: "\n")
        let prompt = """
        Rewrite the FOLLOW-UP below as ONE fully self-contained legal research question, carrying forward the specific case, statute, or issue under discussion. Stay faithful to the conversation — never introduce an authority it does not mention. Output ONLY the rewritten question, nothing else.

        Conversation:
        \(convo)

        FOLLOW-UP: \(followUp)
        """
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
            return nil
        }
        let rewritten = answer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))) ?? ""
        guard rewritten.count >= 12, rewritten.count <= 400 else { return nil }
        if let cite = LegalQueryClassifier.firstCitation(in: rewritten) {
            let historyText = history.map(\.content).joined(separator: " ").lowercased()
            let tokens = LegalCitationMatch.significantTokens(in: cite)
            guard !tokens.isEmpty, tokens.allSatisfy({ historyText.contains($0) }) else { return nil }
        }
        return rewritten
    }

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
    /// History replay for a chat: prior turns with stale `[A#]`/`[S#]` labels
    /// rewritten to the case/source names their persisted citations recorded.
    private func replayHistory(chatID: String) -> [GenerateRequest.Turn] {
        let messages = (try? store.chats.fetchMessages(chatID: chatID))?.map(ChatMessage.init) ?? []
        // Citation lookups only for turns that can SURVIVE the char budget —
        // a long matter chat must not pay one fetch per discarded message.
        // 1.5× covers the rewrite shrinking content slightly under the budget.
        var window: [String] = []
        var used = 0
        for message in messages.reversed() {
            if message.role == .assistant { window.append(message.id) }
            used += message.content.count
            if used > Self.historyCharBudget * 3 / 2 { break }
        }
        var names: [String: [String: String]] = [:]
        for messageID in window {
            let citations = (try? store.chats.fetchCitations(messageID: messageID)) ?? []
            guard !citations.isEmpty else { continue }
            var map: [String: String] = [:]
            for record in citations {
                if let display = record.displayName, !display.isEmpty {
                    map[record.label] = display
                }
            }
            if !map.isEmpty { names[messageID] = map }
        }
        return Self.conversationHistory(
            from: messages,
            budget: Self.historyCharBudget,
            citationNamesByMessageID: names
        )
    }

    static func conversationHistory(
        from messages: [ChatMessage],
        budget: Int,
        citationNamesByMessageID: [String: [String: String]] = [:]
    ) -> [GenerateRequest.Turn] {
        var turns: [GenerateRequest.Turn] = []
        var used = 0
        for message in messages.reversed() {
            let role: GenerateRequest.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: continue
            }
            var raw = message.role == .assistant
                ? ReasoningContent.answer(from: message.content)
                : message.content
            if message.role == .assistant {
                raw = Self.historyReplayAnswer(raw, citationNames: citationNamesByMessageID[message.id] ?? [:])
            }
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if !turns.isEmpty, used + content.count > budget { break }
            turns.append(GenerateRequest.Turn(role: role, content: content))
            used += content.count
        }
        return turns.reversed()
    }

    /// Prepares a stored assistant answer for HISTORY REPLAY. Three hazards:
    /// (1) `[A#]`/`[S#]` labels are numbered against a packet that no longer
    /// exists — replayed verbatim, the model copies them and the verifier
    /// validates the stale number against the NEW packet, so labels are
    /// rewritten to the actual case/source names the message's persisted
    /// citations recorded (unknown labels are dropped); (2) a quarantined
    /// answer replayed in full both wastes budget and teaches the model to
    /// refuse — it is replaced by a one-line placeholder; (3) app furniture
    /// (caveat banners, the Preliminary footer) is the app talking, not the
    /// model — stripped.
    private static let historyLabelRegex = try? NSRegularExpression(pattern: #"\s?\[([AS])(\d{1,3})\]"#)

    static func historyReplayAnswer(_ answer: String, citationNames: [String: String]) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip furniture BEFORE the quarantine check: the primary-law caveat
        // prepends "> ⚠️ …" above a blocked message, which would otherwise
        // defeat the prefix match and replay the whole verification report —
        // bad citations included — into model context.
        var content = strippingAssistantFurniture(trimmed)
        if content.hasPrefix("I cannot provide a source-grounded legal answer")
            || trimmed.contains("**UNVERIFIED DRAFT — DO NOT RELY.**") {
            return "[The previous answer was withheld by citation verification and must not be relied on or repeated.]"
        }
        guard let regex = Self.historyLabelRegex else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var replacements: [(Range<String.Index>, String)] = []
        regex.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let match,
                  let whole = Range(match.range, in: content),
                  let kindRange = Range(match.range(at: 1), in: content),
                  let numberRange = Range(match.range(at: 2), in: content) else { return }
            let label = String(content[kindRange]) + String(content[numberRange])
            if let name = citationNames[label], !name.isEmpty {
                let prefix = content[kindRange] == "A" ? "citing " : "from "
                replacements.append((whole, " (\(prefix)\(name))"))
            } else {
                replacements.append((whole, ""))
            }
        }
        for (target, replacement) in replacements.reversed() {
            content.replaceSubrange(target, with: replacement)
        }
        return content
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

    private func updateMessageAssurance(id: String, state: OutputAssuranceState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].assuranceState = state
    }

    private func groundedAssurance(messageID: String) -> OutputAssuranceState? {
        guard let sourceSet = try? store.documentSources.fetchSourceSet(messageID: messageID) else {
            return nil
        }
        if sourceSet.retrievalDepth == RetrievalDepth.fast.rawValue {
            return .preliminary
        }
        let rows = (try? store.documentSources.fetchSources(sourceSetID: sourceSet.id)) ?? []
        let results = rows.compactMap(\.warningsJSON).compactMap { json in
            try? JSONDecoder().decode([PropositionSupportResult].self, from: Data(json.utf8))
        }.first
        let status: OutputVerificationStatus? = if let results, !results.isEmpty {
            results.allSatisfy { $0.status == .supported } ? .allSupported : .needsReview
        } else {
            nil
        }
        return Self.groundedAssurance(depth: .deep, verificationStatus: status)
    }

    private nonisolated static func groundedAssurance(
        depth: RetrievalDepth,
        verificationStatus: OutputVerificationStatus?
    ) -> OutputAssuranceState {
        if depth == .fast { return .preliminary }
        return verificationStatus == .allSupported ? .propositionSupported : .supportNeedsReview
    }

    // MARK: - Authority reader ([A#], spec §2.5)

    /// Everything the in-app opinion reader shows before the text loads: the case
    /// header, the passage to highlight, and the hydration key.
    public struct AuthorityReaderModel: Identifiable, Sendable, Equatable {
        public let id: String
        public let caseName: String
        public let citationText: String?
        public let court: String?
        public let dateFiled: String?
        public let url: String?
        public let highlight: String?
        public let opinionID: String?
    }

    public func authorityReaderModel(for citation: MessageCitation) -> AuthorityReaderModel {
        AuthorityReaderModel(
            id: citation.id,
            caseName: citation.displayName ?? citation.authorityRef?.citation ?? "Authority",
            citationText: citation.authorityRef?.citation,
            court: citation.authorityRef?.court,
            dateFiled: citation.authorityRef?.dateFiled,
            url: citation.url,
            highlight: citation.matchText,
            opinionID: citation.authorityRef?.opinionID
        )
    }

    /// The reader's opinion text: the persisted copy on a SAVED authority first
    /// (offline, locked §8.3), else a one-shot CourtListener hydration. Nil when
    /// neither is available — the reader then offers the CourtListener link only.
    public func authorityOpinionText(opinionID: String?) async -> String? {
        guard let opinionID else { return nil }
        if let matterID = scopedMatterID,
           let saved = (try? store.authorities.fetchAuthorities(matterID: matterID))?
               .first(where: { $0.opinionID == opinionID }),
           let text = saved.opinionText, !text.isEmpty {
            return text
        }
        guard let id = Int(opinionID),
              let detail = try? await courtListenerClient.fetchOpinion(id: id),
              let body = detail.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return nil }
        return body
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
            // The reader pointer (spec §2.5): hydration keys + case header in the
            // locator column; the search snippet anchors the passage highlight.
            let ref = AuthorityCitationRef(
                opinionID: authority.opinionId,
                clusterID: authority.clusterId,
                citation: authority.citation ?? authority.citations.first,
                court: authority.court,
                dateFiled: authority.dateFiled
            )
            records.append(
                MessageCitationRecord(
                    messageID: messageID,
                    label: label,
                    kind: MessageCitation.Kind.authority.rawValue,
                    url: url,
                    locatorJSON: (try? JSONEncoder.encodeToString(ref)),
                    displayName: authority.caseName ?? authority.citation,
                    matchText: authority.snippet.map { String($0.prefix(280)) },
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

    /// Persists the complete grounded packet, including candidates omitted from
    /// the prompt, under the exact assistant message. Inline citations remain a
    /// reader convenience; this pending source set is the durable promotion and
    /// verification record.
    private func persistGroundedDocumentPacket(
        messageID: String,
        question: String,
        context: GroundedChatContext,
        verification: DocumentSupportReport?
    ) throws {
        guard let matterID = scopedMatterID,
              !context.sources.isEmpty,
              let packingReport = context.sourceSetPackingReport,
              let scope = context.sourceScope,
              let configuration = context.retrievalConfiguration else { return }
        let lineage = try DocumentSourceLineageBuilder.make(
            store: store,
            matterID: matterID,
            scope: scope,
            configuration: configuration,
            packingReport: packingReport
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID,
            mode: .autoSource,
            scopeJSON: try Self.canonicalJSON(scope),
            retrievalQuery: question,
            retrievalDepth: context.depth.rawValue,
            packingReportJSON: lineage.packingReportJSON,
            embeddingModelID: lineage.embeddingModelID,
            embeddingModelRevision: lineage.embeddingModelRevision,
            chunkerVersion: lineage.chunkerVersion,
            retrievalConfigJSON: lineage.retrievalConfigJSON,
            corpusSnapshotHash: lineage.corpusSnapshotHash,
            messageID: messageID
        )
        let verificationJSON = try Self.canonicalJSON(verification?.results ?? [])
        let rows = context.sources.enumerated().map { index, source in
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id,
                documentID: source.documentID,
                chunkID: source.chunkID,
                revisionID: source.revisionID,
                citationLabel: source.label,
                locatorJSON: source.locator.encodedJSON(),
                excerpt: source.excerpt,
                rank: index,
                warningsJSON: verificationJSON
            )
        }
        try store.documentSources.addOutputSources(rows)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
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

    /// Records generation latency (first-token + throughput) as a `performance`
    /// diagnostic for the Diagnostics timings readout. Best-effort.
    private func logGenerationTiming(_ metrics: RuntimeMetrics?, generationID: String) {
        guard let metrics else { return }
        var parts: [String] = []
        if let ftl = metrics.firstTokenLatencyMs { parts.append("first token \(ModelLibrary.formatMilliseconds(ftl))") }
        if let tps = metrics.tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        guard !parts.isEmpty else { return }
        try? store.diagnostics.recordDiagnosticEvent(
            DiagnosticEventRecord(
                severity: "info",
                category: "performance",
                message: "Generated — " + parts.joined(separator: ", "),
                generationID: generationID
            )
        )
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
