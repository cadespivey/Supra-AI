import AppKit
import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// The first persisted global chat flow: pick or create a chat, route the prompt,
/// and watch the answer stream in.
struct GlobalChatsView: View {
    /// How the chat list is presented in the bar. The global Chats screen uses a
    /// dropdown; a matter's Chat tab shows its chats inline (no matter selector,
    /// since every chat here already belongs to this matter).
    enum ChatListStyle { case picker, inline }

    @ObservedObject var controller: GlobalChatController
    @ObservedObject var library: ModelLibrary
    @ObservedObject var settings: SettingsController
    var listStyle: ChatListStyle = .picker
    @State private var draft = ""
    @State private var showGenerationSettings = false
    @State private var attachments: [ChatAttachmentContext] = []
    @State private var attachmentError: String?
    @State private var isLoadingAttachment = false
    @FocusState private var inputFocused: Bool

    private let attachmentLoader = ChatAttachmentLoader()
    private static let maxAttachments = 10

    var body: some View {
        VStack(spacing: 0) {
            chatBar
            Divider()
            messageList
            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }
            Divider()
            composer
            Divider()
            chatStatusBar
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - Chat selector

    private var chatBar: some View {
        HStack(spacing: 12) {
            switch listStyle {
            case .picker:
                Text(selectedChatTitle ?? "New Chat")
                    .font(.headline)
                    .foregroundStyle(selectedChatTitle == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .inline:
                if controller.chats.isEmpty {
                    Text("No chats yet").foregroundStyle(.secondary)
                } else {
                    inlineChatList
                }
            }
            Spacer()
            if listStyle == .picker {
                chatHistoryMenu
            }
            Button {
                _ = try? controller.createChat()
                inputFocused = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .padding(12)
    }

    /// Reopen a saved chat without an always-visible dropdown (the inline picker
    /// was replaced by this compact history menu).
    private var chatHistoryMenu: some View {
        Menu {
            if controller.chats.isEmpty {
                Text("No previous chats")
            } else {
                ForEach(controller.chats) { chat in
                    Button {
                        controller.select(chatID: chat.id)
                    } label: {
                        if controller.selectedChatID == chat.id {
                            Label(chat.title, systemImage: "checkmark")
                        } else {
                            Text(chat.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent chats")
    }

    private var selectedChatTitle: String? {
        controller.chats.first { $0.id == controller.selectedChatID }?.title
    }

    /// A horizontal, always-visible list of this matter's chats (replaces the
    /// dropdown so the user sees every chat for the matter at a glance).
    private var inlineChatList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controller.chats) { chat in
                    let selected = controller.selectedChatID == chat.id
                    Button {
                        controller.select(chatID: chat.id)
                    } label: {
                        Text(chat.title)
                            .lineLimit(1)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selected ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: controller.messages.last?.content) { _, _ in
                if let lastID = controller.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if controller.messages.isEmpty {
                ContentUnavailableView(
                    "Start a Conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Ask a question to begin.")
                )
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch library.loadState {
            case .loaded:
                EmptyView()
            case let .failed(message):
                Text("Model failed to load: \(message)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .loading:
                Text("Loading model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                Text("Task models load on demand. Assign them in Models for model answers; verification can run without one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if listStyle == .picker {
                attachmentArea
            }
            HStack(alignment: .bottom, spacing: 8) {
                if listStyle == .picker {
                    attachButton
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)

                if controller.isGenerating {
                    Button(role: .cancel, action: controller.cancel) {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } else {
                    Button(action: send) {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Attachments (global chat only)

    /// Attach files/images/screenshots into the model's context. Heavy documents
    /// (PDF, Word, Excel) are declined with a nudge to open a matter.
    private var attachButton: some View {
        Button {
            attachmentError = nil
            presentAttachmentPicker()
        } label: {
            if isLoadingAttachment {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "plus")
            }
        }
        .help("Attach files or images (up to \(Self.maxAttachments)). Open a matter for PDFs and Word/Excel documents.")
        .disabled(controller.isGenerating || isLoadingAttachment || attachments.count >= Self.maxAttachments)
    }

    @ViewBuilder
    private var attachmentArea: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text(attachment.name).lineLimit(1)
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        if let attachmentError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(attachmentError).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { self.attachmentError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    /// A standalone, movable/resizable open panel (run modally) rather than a
    /// SwiftUI `.fileImporter` sheet, which on macOS attaches to the window and
    /// forced it to resize.
    private func presentAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text, .rtf, .data]
        panel.prompt = "Attach"
        panel.message = "Choose files or images to attach to this chat"
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    private func addAttachments(_ urls: [URL]) {
        attachmentError = nil
        let remaining = Self.maxAttachments - attachments.count
        guard remaining > 0 else {
            attachmentError = "You can attach up to \(Self.maxAttachments) items."
            return
        }
        let toLoad = Array(urls.prefix(remaining))
        if urls.count > remaining {
            attachmentError = "You can attach up to \(Self.maxAttachments) items; some were skipped."
        }
        Task { @MainActor in
            isLoadingAttachment = true
            defer { isLoadingAttachment = false }
            for url in toLoad {
                do {
                    let context = try await attachmentLoader.load(url: url)
                    attachments.append(context)
                } catch {
                    attachmentError = (error as? ChatAttachmentLoader.LoadFailure)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let rawPrompt = draft
        let rawAttachments = attachments
        let router = ModelRouter(configuration: .fromEnvironment())
        let routed = router.routePrompt(rawPrompt)
        guard controller.canSendRoutedPrompt(routed) else {
            attachmentError = "Enter a prompt, paste text to verify, or use `/critique` after an assistant draft."
            return
        }

        Task { @MainActor in
            var modelID: ModelID?
            if controller.requiresRuntimeModel(for: routed) {
                switch await library.ensureLoadedRoutedModelID(
                    for: routed.route.role,
                    configuration: router.configuration
                ) {
                case let .success(loaded):
                    modelID = loaded
                case let .failure(issue):
                    attachmentError = issue.message
                    return
                }
            }
            draft = ""
            attachments = []
            attachmentError = nil
            // Keep the cursor in the composer so the user can type a follow-up
            // immediately instead of clicking back into the field.
            inputFocused = true
            controller.send(
                prompt: routed.prompt,
                modelID: modelID,
                attachments: rawAttachments,
                route: routed.route,
                displayPrompt: rawPrompt
            )
        }
    }

    // MARK: - Status bar

    /// Below the composer: which model is loaded, whether it's generating, and a
    /// quick generation-settings switcher (the same defaults as Settings).
    private var chatStatusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(modelStatusColor).frame(width: 7, height: 7)
                Text(modelStatusText).foregroundStyle(.secondary).lineLimit(1)
            }
            if controller.isGenerating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Generating…")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if listStyle == .picker {
                jurisdictionMenu
            }
            Button { showGenerationSettings.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(settings.preset.displayName)
                }
            }
            .buttonStyle(.plain)
            .help("Generation settings")
            .popover(isPresented: $showGenerationSettings, arrowEdge: .bottom) {
                generationSettings
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Bounds global-chat legal research (CourtListener) to a jurisdiction's
    /// courts. "Auto-detect" infers one from the prompt; picking a jurisdiction
    /// hard-bounds it. Sized to sit beside the model name and generation settings.
    private var jurisdictionMenu: some View {
        Menu {
            Picker("Jurisdiction", selection: $controller.jurisdictionOverrideID) {
                Text("Auto-detect from prompt").tag("")
                ForEach(controller.topLevelJurisdictions) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.columns")
                Text(jurisdictionLabel).lineLimit(1)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bounds legal research to this jurisdiction's courts on CourtListener")
    }

    private var jurisdictionLabel: String {
        guard !controller.jurisdictionOverrideID.isEmpty else { return "Auto-detect" }
        return controller.topLevelJurisdictions
            .first { $0.id == controller.jurisdictionOverrideID }?
            .displayName ?? "Auto-detect"
    }

    private var modelStatusText: String {
        switch library.loadState {
        case .loaded: library.loadedModel?.displayName ?? "Model loaded"
        case .loading: "Loading model…"
        case .failed: "Model failed to load"
        case .idle: "Runtime idle"
        }
    }

    private var modelStatusColor: Color {
        switch library.loadState {
        case .loaded: .green
        case .loading: .gray
        case .failed: .orange
        case .idle: .gray
        }
    }

    private var generationSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generation").font(.headline)
            Picker("Preset", selection: $settings.preset) {
                ForEach(GenerationPreset.userSelectableDefaults, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $settings.temperature, in: 0...1, step: 0.05)
            }
            Stepper("Max output tokens: \(settings.maxOutputTokens)", value: $settings.maxOutputTokens, in: 128...8192, step: 128)
            Text("Applies to all chats — same as Settings → Generation Defaults.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    /// nil until the user toggles. Until then the reasoning section auto-expands
    /// only while the response is still generating, and stays collapsed for
    /// completed/reloaded messages so chat history isn't a wall of reasoning.
    @State private var reasoningExpandedOverride: Bool?

    private var reasoningExpanded: Binding<Bool> {
        Binding(
            get: { reasoningExpandedOverride ?? message.isStreaming },
            set: { reasoningExpandedOverride = $0 }
        )
    }

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantRow
        }
    }

    /// User turns: a right-aligned bubble with blue text, like a text
    /// conversation. The bubble itself is a neutral tint so the blue text stays
    /// legible (blue-on-blue fails contrast, especially in dark mode).
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(attributedContent)
                .textSelection(.enabled)
                .lineLimit(nil)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(Text("You said: \(displayContent)"))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Assistant (and system) turns: full-width, with the collapsible reasoning.
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }
                statusBadge
            }
            if let reasoning {
                DisclosureGroup(isExpanded: reasoningExpanded) {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                } label: {
                    Label("Reasoning", systemImage: "brain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
            Text(attributedContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(roleColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The answer rendered as Markdown (bold/italic/code/links/lists), with line
    /// breaks preserved. Falls back to plain text if it can't be parsed (e.g. a
    /// partially-streamed message), so streaming never shows a parse error.
    private var attributedContent: AttributedString {
        // Only the assistant's answer is rendered as Markdown. User/system rows are
        // shown verbatim so a prompt containing literal **/`code`/[label](…) is
        // preserved exactly in the transcript.
        guard message.role == .assistant else { return AttributedString(displayContent) }
        return (try? AttributedString(
            markdown: displayContent,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(displayContent)
    }

    /// The model's chain-of-thought, available once its `</think>` boundary has
    /// streamed in. Nil for non-reasoning output and while still mid-thought.
    private var reasoning: String? {
        guard message.role == .assistant else { return nil }
        let block = ReasoningContent.reasoning(from: message.content)
        return (block?.isEmpty ?? true) ? nil : block
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Supra"
        case .system: "System"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user: .accentColor
        case .assistant: .secondary
        case .system: .orange
        }
    }

    private var displayContent: String {
        if message.content.isEmpty {
            return message.isStreaming ? "…" : message.content
        }
        // Show the answer, not the model's chain-of-thought. The full raw text
        // (reasoning included) stays persisted; once the reasoning block exists it
        // is surfaced in the collapsible section above, never duplicated here.
        let answer = ReasoningContent.answer(from: message.content)
        if answer.isEmpty {
            // Reasoning parsed but the answer hasn't started (just past </think>):
            // a brief placeholder rather than echoing the raw reasoning text.
            if reasoning != nil { return message.isStreaming ? "…" : "" }
            return message.isStreaming ? "Thinking…" : message.content
        }
        return answer
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch message.status {
        case .cancelled:
            badge("Cancelled", color: .secondary)
        case .failed:
            badge("Failed", color: .orange)
        case .interrupted:
            badge("Interrupted", color: .orange)
        case .pending, .completed, .deleted:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }
}
