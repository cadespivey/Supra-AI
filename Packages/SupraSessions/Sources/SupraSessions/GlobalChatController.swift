import Combine
import Foundation
import SupraCore
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
    private var activeGenerationID: GenerationID?

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil,
        scope: ChatScope = .global
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
        self.scope = scope
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

    // MARK: - Sending

    /// Sends a prompt in the selected chat against the given (already loaded) model.
    ///
    /// If no chat is selected, one is created automatically.
    public func send(
        prompt: String,
        modelID: ModelID,
        attachments: [ChatAttachmentContext] = [],
        systemPrompt: String? = nil,
        options: GenerationOptions? = nil
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        let effectiveSystemPrompt = systemPrompt ?? storedSystemPrompt() ?? defaultSystemPrompt
        let effectiveOptions = options ?? storedDefaultOptions()
        Task {
            await self.performSend(
                prompt: trimmed,
                attachments: attachments,
                modelID: modelID,
                systemPrompt: effectiveSystemPrompt,
                options: effectiveOptions
            )
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
        modelID: ModelID,
        systemPrompt: String?,
        options: GenerationOptions
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
        let displayContent = attachments.isEmpty
            ? prompt
            : prompt + "\n\nAttached: " + attachments.map(\.name).joined(separator: ", ")

        do {
            let chatID = try ensureSelectedChat().id

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

    private func ensureSelectedChat() throws -> ChatSummary {
        if let selectedChatID, let existing = chats.first(where: { $0.id == selectedChatID }) {
            return existing
        }
        return try createChat()
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
