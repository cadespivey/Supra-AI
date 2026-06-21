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
    /// Matters available as "move chat to…" targets, shown only in the global
    /// (`.picker`) chat. Nil inside a matter (chats there already belong to it).
    var matters: MattersController?
    @State private var draft = ""
    @State private var showGenerationSettings = false
    @State private var showJurisdiction = false
    @State private var attachments: [ChatAttachmentContext] = []
    @State private var attachmentError: String?
    @State private var isLoadingAttachment = false
    @FocusState private var inputFocused: Bool

    // Chat-history sidebar state (global chat only).
    @State private var chatSearch = ""
    @State private var suggestions: [ChatSuggestion] = []
    @State private var renamingChat: ChatSummary?
    @State private var renameText = ""
    @State private var pendingDeleteChat: ChatSummary?

    private let attachmentLoader = ChatAttachmentLoader()
    private static let maxAttachments = 10

    var body: some View {
        Group {
            if listStyle == .picker {
                HStack(spacing: 0) {
                    chatHistorySidebar
                    Divider()
                    chatColumn
                }
            } else {
                chatColumn
            }
        }
        .onAppear {
            inputFocused = true
            if listStyle == .picker {
                matters?.loadMatters()
                if suggestions.isEmpty { suggestions = ChatSuggestions.sample() }
            }
        }
        // Rotate the example prompts every time the chat window goes blank/empty
        // (new chat, deleted chat, or a moved chat) so they don't get stale.
        .onChange(of: controller.selectedChatID) { _, _ in
            if listStyle == .picker { suggestions = ChatSuggestions.sample() }
        }
    }

    private var chatColumn: some View {
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
            Button {
                controller.startNewChat()
                if listStyle == .picker { suggestions = ChatSuggestions.sample() }
                inputFocused = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .padding(12)
    }

    // MARK: - Chat history sidebar (global chat)

    /// An interior sidebar (within the global Chats detail) listing every chat,
    /// searchable by title, with per-chat rename / move-to-matter / delete actions.
    private var chatHistorySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button {
                    controller.startNewChat()
                    suggestions = ChatSuggestions.sample()
                    inputFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New chat")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            chatSearchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            if filteredChats.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: chatSearch.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(chatSearch.isEmpty ? "No chats yet" : "No matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredChats) { chat in
                            chatHistoryRow(chat)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 248)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Rename Chat", isPresented: renameAlertBinding) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingChat = nil }
            Button("Save") {
                if let chat = renamingChat {
                    controller.renameChat(chatID: chat.id, title: renameText)
                }
                renamingChat = nil
            }
        }
        .confirmationDialog(
            pendingDeleteChat.map { "Delete “\($0.title)”?" } ?? "Delete chat?",
            isPresented: deleteConfirmBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let chat = pendingDeleteChat { controller.deleteChat(chatID: chat.id) }
                pendingDeleteChat = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteChat = nil }
        } message: {
            Text("This removes the chat from your history. This can't be undone from the app.")
        }
    }

    private var chatSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Search chats", text: $chatSearch)
                .textFieldStyle(.plain)
                .font(.callout)
            if !chatSearch.isEmpty {
                Button { chatSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func chatHistoryRow(_ chat: ChatSummary) -> some View {
        let selected = controller.selectedChatID == chat.id
        return Button {
            controller.select(chatID: chat.id)
            inputFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .lineLimit(1)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Text(chat.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu { chatRowMenu(chat) }
    }

    @ViewBuilder
    private func chatRowMenu(_ chat: ChatSummary) -> some View {
        Button {
            renameText = chat.title
            renamingChat = chat
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        if let matters, !matters.matters.isEmpty {
            Menu {
                ForEach(matters.matters) { matter in
                    Button(matter.name) {
                        controller.moveChat(chatID: chat.id, toMatter: matter.id)
                    }
                }
            } label: {
                Label("Move to Matter", systemImage: "folder")
            }
        }

        Divider()

        Button(role: .destructive) {
            pendingDeleteChat = chat
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Chats whose title matches the search box (case-insensitive). Empty search
    /// shows everything, newest first (the controller's ordering).
    private var filteredChats: [ChatSummary] {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return controller.chats }
        return controller.chats.filter { $0.title.lowercased().contains(query) }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDeleteChat != nil }, set: { if !$0 { pendingDeleteChat = nil } })
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
            .onChange(of: controller.messages.last?.content) { _, _ in scrollToLast(proxy) }
            // A new turn whose content matches the prior last message (or a chat
            // switch) wouldn't trip the content observer, so anchor on count too.
            .onChange(of: controller.messages.count) { _, _ in scrollToLast(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if controller.messages.isEmpty {
                if listStyle == .picker {
                    suggestionsEmptyState
                } else {
                    ContentUnavailableView(
                        "Start a Conversation",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Ask a question to begin.")
                    )
                }
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let lastID = controller.messages.last?.id else { return }
        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
    }

    // MARK: - Example prompts (global chat empty state)

    /// The blank global-chat state: a friendly heading plus a 2×2 grid of rotating
    /// example prompts. Tapping one sends it (the same path as typing + Send).
    private var suggestionsEmptyState: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("§")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                    .foregroundStyle(.tertiary)
                Text("How can I help with your legal work?")
                    .font(.title3.weight(.semibold))
                Text("Pick a starting point or ask anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(suggestions) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            .frame(maxWidth: 620)

            Button {
                suggestions = ChatSuggestions.sample()
            } label: {
                Label("Show different examples", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionCard(_ suggestion: ChatSuggestion) -> some View {
        Button {
            submit(suggestion.prompt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.systemImage)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(suggestion.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Send: \(suggestion.prompt)")
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
        submit(draft)
    }

    /// The shared send path for both the composer and the example-prompt cards.
    /// Routes the prompt, loads the role model if needed, then streams the answer.
    private func submit(_ rawPrompt: String) {
        guard !rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              !controller.isGenerating else { return }
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

    /// Bounds global-chat legal research (CourtListener) to a jurisdiction. Styled
    /// like the generation-settings button to its right: a plain button opening a
    /// popover with the picker (Federal broken down by circuit) and the related-
    /// federal option.
    private var jurisdictionMenu: some View {
        Button { showJurisdiction.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.columns")
                Text(jurisdictionLabel).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Bounds legal research (CourtListener) to a jurisdiction")
        .popover(isPresented: $showJurisdiction, arrowEdge: .bottom) {
            jurisdictionSettings
        }
    }

    private var jurisdictionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jurisdiction").font(.headline)
            Picker("Jurisdiction", selection: $controller.jurisdictionOverrideID) {
                Text("Auto-detect from prompt").tag("")
                Section("Federal") {
                    Text("All federal courts").tag("federal-courts")
                    ForEach(controller.federalCircuits) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                Section("States & territories") {
                    ForEach(controller.stateJurisdictions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Toggle("Include related federal courts", isOn: $controller.includeRelatedFederal)
                .disabled(!selectedIsState)
                .help("For a state, also search the federal circuit and district courts that apply its law.")
            Text("Bounds CourtListener research to the selected jurisdiction. Auto-detect infers it from your prompt.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
    }

    private var jurisdictionLabel: String {
        let id = controller.jurisdictionOverrideID
        guard !id.isEmpty else { return "Auto-detect" }
        return JurisdictionCatalog.shared.option(id: id)?.displayName ?? "Auto-detect"
    }

    /// The related-federal toggle only affects an explicit state selection.
    private var selectedIsState: Bool {
        JurisdictionCatalog.shared.option(id: controller.jurisdictionOverrideID)?.system == .state
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
    @State private var isHovered = false

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

    /// User turns: a right-aligned bubble with blue text on a neutral tint, like a
    /// text conversation.
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(displayContent)
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

    /// Assistant (and system) turns: full-width on the plain window background —
    /// no bubble, no "Supra" heading (that's inherent) — rendered as rich-text
    /// Markdown, with the collapsible reasoning and a copy action on hover.
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 6) {
                    if message.role == .system {
                        Text("System").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    if message.isStreaming {
                        ProgressView().controlSize(.small)
                    }
                    statusBadge
                }
            }
            if let reasoning {
                DisclosureGroup(isExpanded: reasoningExpanded) {
                    Text(EmojiStripper.strip(reasoning))
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
            MarkdownView(text: displayContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsCopy {
                copyButton
                    .opacity(isHovered ? 1 : 0.35)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }

    /// The model's chain-of-thought, available once its `</think>` boundary has
    /// streamed in. Nil for non-reasoning output and while still mid-thought.
    private var reasoning: String? {
        guard message.role == .assistant else { return nil }
        let block = ReasoningContent.reasoning(from: message.content)
        return (block?.isEmpty ?? true) ? nil : block
    }

    private var hasStatusBadge: Bool {
        switch message.status {
        case .cancelled, .failed, .interrupted: true
        default: false
        }
    }

    /// Only show a header row when there's something to say — a system tag, the
    /// streaming spinner, or a status badge. Plain answers get no heading.
    private var showsHeader: Bool {
        message.role == .system || message.isStreaming || hasStatusBadge
    }

    private var showsCopy: Bool {
        message.role == .assistant && !message.isStreaming && !displayContent.isEmpty
    }

    private var copyButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // Emoji-stripped Markdown — clean to paste elsewhere.
            pasteboard.setString(EmojiStripper.strip(displayContent), forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc").font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy this response as Markdown")
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

// MARK: - Markdown rendering

/// A dependency-free Markdown renderer for assistant responses: headings, lists,
/// fenced code, block quotes, GitHub-style tables, and inline emphasis/code/links.
/// Renders the shapes an LLM commonly emits as rich text (not raw markup), and
/// degrades gracefully on partial/streaming input.
struct MarkdownView: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []
    @State private var sourceText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: text) { _, _ in refresh() }
    }

    /// Parse only when the text actually changes, so hover/selection re-renders
    /// don't re-parse. Emojis are stripped once here (never inside code spacing,
    /// because the stripper only removes real emoji glyphs).
    private func refresh() {
        guard text != sourceText else { return }
        sourceText = text
        blocks = MarkdownParser.parse(EmojiStripper.strip(text))
    }
}

enum MarkdownColumnAlign {
    case leading, center, trailing

    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case codeBlock(String)
    case quote(String)
    case table(headers: [String], rows: [[String]], aligns: [MarkdownColumnAlign])
    case rule
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownInline.attributed(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 2 : 0)
        case let .paragraph(text):
            Text(MarkdownInline.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { idx in
                    listRow(marker: "•", text: items[idx])
                }
            }
        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { idx in
                    listRow(marker: "\(idx + 1).", text: items[idx])
                }
            }
        case let .codeBlock(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(MarkdownInline.attributed(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .table(headers, rows, aligns):
            MarkdownTableView(headers: headers, rows: rows, aligns: aligns)
        case .rule:
            Divider()
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).foregroundStyle(.secondary).monospacedDigit()
            Text(MarkdownInline.attributed(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let aligns: [MarkdownColumnAlign]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(headers.indices, id: \.self) { column in
                    Text(MarkdownInline.attributed(headers[column]))
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: alignment(column))
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        Text(MarkdownInline.attributed(cell(row, column)))
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func cell(_ row: Int, _ column: Int) -> String {
        guard row < rows.count, column < rows[row].count else { return "" }
        return rows[row][column]
    }

    private func alignment(_ column: Int) -> Alignment {
        column < aligns.count ? aligns[column].alignment : .leading
    }
}

/// Inline spans (bold/italic/`code`/links) via Foundation's Markdown parser, with
/// a plain-text fallback so partial/streaming text never shows a parse error.
enum MarkdownInline {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// Splits raw Markdown into block elements. Line-based and forgiving: anything it
/// doesn't recognize becomes a paragraph, so it never throws on LLM output.
enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text)); i += 1; continue
            }

            if isRule(trimmed) {
                flushParagraph(); blocks.append(.rule); i += 1; continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let (table, consumed) = parseTable(lines, start: i)
                blocks.append(table); i += consumed; continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n"))); continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(bulletText(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.bulletList(items)); continue
            }

            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(numberedText(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.numberedList(items)); continue
            }

            if trimmed.isEmpty {
                flushParagraph(); i += 1; continue
            }

            paragraph.append(trimmed); i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1; index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        return (level, String(line[index...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func bulletText(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isNumbered(_ line: String) -> Bool {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber {
            digits += 1; index = line.index(after: index)
        }
        guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else { return false }
        let next = line.index(after: index)
        return next < line.endIndex && line[next] == " "
    }

    private static func numberedText(_ line: String) -> String {
        guard let marker = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return line }
        return String(line[line.index(after: marker)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTable(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        let headers = splitRow(lines[start])
        let aligns = splitRow(lines[start + 1]).map { spec -> MarkdownColumnAlign in
            let left = spec.hasPrefix(":")
            let right = spec.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            rows.append(splitRow(lines[i])); i += 1
        }
        return (.table(headers: headers, rows: rows, aligns: aligns), i - start)
    }
}

/// Removes emoji so they never reach the chat or the clipboard, WITHOUT touching
/// text symbols that double as content (✓ ✗ → ⚖ ™ © …) or code spacing. It strips
/// only default-emoji glyphs and characters forced to emoji presentation by a
/// variation selector — so it's safe to run over the whole answer, code included.
enum EmojiStripper {
    static func strip(_ text: String) -> String {
        guard text.contains(where: isEmoji) else { return text }
        return String(text.filter { !isEmoji($0) })
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
        }
    }
}
