import AppKit
import SupraCore
import SupraDocuments
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
    /// The app-wide generation default lives here; the chat reads/writes its own
    /// per-chat options on `controller`, but Settings is still where new chats'
    /// defaults come from.
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
    /// Tag/content search results (chats + ScratchPad notes), recomputed as the query
    /// changes. Drives both the content-matched chat list and the tag-matches section.
    @State private var tagHits: [TagSearchHit] = []
    @State private var suggestions: [ChatSuggestion] = []
    @State private var renamingChat: ChatSummary?
    @State private var renameText = ""
    @State private var pendingDeleteChat: ChatSummary?
    /// A tapped `[S#]` matter-document citation, shown in a trailing slide-over
    /// preview hosted over the message area (one host, not per-row).
    @State private var citationPreview: PreviewItem?
    @State private var citationPreviewWidth: CGFloat = 580

    private let attachmentLoader = ChatAttachmentLoader()
    private static let maxAttachments = 10

    var body: some View {
        // The searchable history sidebar is shown in both the global Chats screen
        // and a matter's Chat tab, so matter chats are a real store: start new ones
        // and reopen old ones (not just the cramped inline strip).
        HStack(spacing: 0) {
            chatHistorySidebar
            Divider()
            chatColumn
        }
        .onAppear {
            inputFocused = true
            matters?.loadMatters()
            if suggestions.isEmpty { suggestions = ChatSuggestions.sample() }
        }
        // Rotate the example prompts every time the chat window goes blank/empty
        // (new chat, deleted chat, or a moved chat) so they don't get stale.
        .onChange(of: controller.selectedChatID) { _, _ in
            suggestions = ChatSuggestions.sample()
        }
        .onChange(of: chatSearch) { _, newValue in
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            tagHits = query.count > 1 ? controller.tagSearch(term: query) : []
        }
    }

    // The conversation fills the pane; the sidebar owns chat selection and the New
    // Chat action, so there's no separate header bar.
    private var chatColumn: some View {
        // The composer + status row float directly over the conversation background
        // (no bracketing dividers), like Claude's chat view — the rounded input box
        // is its own visual separation.
        VStack(spacing: 0) {
            messageList
                // The cited source slides in OVER the conversation (it doesn't displace
                // the text), with a draggable leading edge to resize. Scoped to the
                // message area so it never covers the composer's Send/Stop controls.
                .overlay(alignment: .trailing) {
                    if let item = citationPreview {
                        PreviewSlideOver(model: item.model, width: $citationPreviewWidth) { citationPreview = nil }
                    }
                }
                .animation(.snappy(duration: 0.25), value: citationPreview != nil)
            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }
            composer
            chatStatusBar
        }
    }

    // MARK: - Chat history sidebar

    /// An interior sidebar listing every chat in scope (the global Chats screen or a
    /// matter's Chat tab), searchable by title, with per-chat rename / delete and —
    /// in the global scope only — a move-to-matter action.
    private var chatHistorySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.supraHeadline)
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

            if filteredChats.isEmpty && discoveryGroups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: chatSearch.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(chatSearch.isEmpty ? "No chats yet" : "No matches")
                        .font(.supraCaption)
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
                    if isTagMode && !discoveryGroups.isEmpty {
                        tagMatchesSection
                    }
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
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        // Matches the Documents tab's search field — a standard rounded-border text
        // field rather than a filled pill with an inline icon.
        TextField("Search chats or #tags", text: $chatSearch)
            .textFieldStyle(.roundedBorder)
    }

    private func chatHistoryRow(_ chat: ChatSummary) -> some View {
        let selected = controller.selectedChatID == chat.id
        return HStack(spacing: 4) {
            Button {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.row.\(chat.title)")

            // Always-visible action affordance (more discoverable than relying on
            // right-click alone); disabled while this chat is still generating.
            Menu {
                chatRowMenu(chat)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(selected ? 1 : 0.7)
            .disabled(controller.isGenerating && selected)
            .help("Chat actions")
            .accessibilityIdentifier("chat.menu.\(chat.title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            selected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .hoverShade(cornerRadius: 6)
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

        Button {
            exportChat(chat)
        } label: {
            Label("Export Chat", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("chat.export")

        Divider()

        Button(role: .destructive) {
            pendingDeleteChat = chat
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Saves the full conversation as a Markdown file via a save panel, then reveals
    /// it in Finder. Emojis are stripped (matching the per-message copy) and the
    /// filename is derived from the chat title.
    private func exportChat(_ chat: ChatSummary) {
        let markdown = EmojiStripper.strip(
            controller.exportTranscriptMarkdown(chatID: chat.id, title: chat.title)
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.sanitizedFilename(chat.title) + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                controller.reportError(error.localizedDescription)
            }
        }
    }

    /// Strips path separators and control characters from a chat title so it's safe
    /// as a filename; falls back to "chat" when nothing usable remains.
    private static func sanitizedFilename(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chat" : cleaned
    }

    /// In-scope chats matched by title OR by message content (a `#tag` or any text).
    /// Empty search shows everything, newest first (the controller's ordering).
    private var filteredChats: [ChatSummary] {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return controller.chats }
        // Content matches come from the search results (openable = in this scope).
        let contentMatched = Set(tagHits.compactMap { $0.kind == .chat ? $0.openableChatID : nil })
        return controller.chats.filter { $0.title.lowercased().contains(query) || contentMatched.contains($0.id) }
    }

    /// Tag mode: the query begins with `#`, so a discovery section of note + cross-
    /// matter hits is shown beneath the in-scope chat list.
    private var isTagMode: Bool {
        chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    private struct DiscoveryGroup: Identifiable {
        let id: String          // matter name (the group label)
        let hits: [TagSearchHit]
    }

    /// Hits surfaced for discovery (not openable in place): ScratchPad notes and
    /// cross-matter chats, grouped by matter.
    private var discoveryGroups: [DiscoveryGroup] {
        let discovery = tagHits.filter { $0.kind == .note || ($0.kind == .chat && $0.openableChatID == nil) }
        let grouped = Dictionary(grouping: discovery, by: \.group)
        return grouped.keys.sorted().map { DiscoveryGroup(id: $0, hits: grouped[$0] ?? []) }
    }

    /// Discovery results for a #tag query — ScratchPad notes and cross-matter chats,
    /// grouped by matter (informational; chats in other matters aren't opened here).
    private var tagMatchesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            Text("Tag matches")
                .font(.supraHeadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(discoveryGroups) { group in
                Text(group.id)
                    .font(.supraCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                ForEach(group.hits) { hit in
                    tagHitRow(hit)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func tagHitRow(_ hit: TagSearchHit) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hit.kind == .note ? "note.text" : "bubble.left")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(.supraCaption.weight(.medium))
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDeleteChat != nil }, set: { if !$0 { pendingDeleteChat = nil } })
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.messages) { message in
                        MessageRow(
                            message: message,
                            onOpenAuthority: { NSWorkspace.shared.open($0) },
                            onOpenSource: { citation in
                                guard let documentID = citation.documentID,
                                      let locator = citation.locator else { return }
                                let model = controller.citationPreview(
                                    documentID: documentID,
                                    locator: locator,
                                    matchText: citation.matchText
                                )
                                citationPreview = PreviewItem(model: model)
                            }
                        )
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
                suggestionsEmptyState
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
                    .font(.supraTitle)
                Text("Pick a starting point or ask anything.")
                    .font(.supraSubheadline)
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
            // Fill the composer (don't auto-send) so the user can add the
            // specifics legal prompts usually need — jurisdiction, party, or the
            // document the prompt refers to — before sending.
            draft = suggestion.prompt
            inputFocused = true
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
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .hoverShade(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .help("Use this prompt: \(suggestion.prompt)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.supraBody)
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
            modelLoadCaption
            attachmentArea
            slashCommandMenu
            inputBox
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// A `/`-triggered command palette: when the message starts with a `/` token, list
    /// the matching slash commands so they're discoverable. Picking one fills the
    /// composer; the routing itself is handled by `ModelRouter` on send.
    @ViewBuilder
    private var slashCommandMenu: some View {
        let matches = SlashCommandCatalog.suggestions(for: draft)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { command in
                    Button { applySlashCommand(command) } label: {
                        HStack(spacing: 10) {
                            Text(command.command)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(minWidth: 104, alignment: .leading)
                            Text(command.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if command.id != matches.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
            .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private func applySlashCommand(_ command: SlashCommand) {
        draft = command.command + " "
        inputFocused = true
    }

    /// A pill-styled entry matching the ScratchPad composer: a single rounded-border
    /// box holding the (optional) attach affordance, the growing text field, and a
    /// circular send/stop button — so every chat window shares the same input chrome.
    private var inputBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            TextField("Message — type / for commands", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                // Plain Return sends; Shift-Return (and ⌘-Return) fall through so the
                // field inserts a newline / the send button's shortcut fires. Replaces
                // .onSubmit so Return cannot fire twice.
                .onKeyPress(keys: [.return]) { keyPress in
                    guard keyPress.modifiers.isEmpty else { return .ignored }
                    send()
                    return .handled
                }
            if controller.isGenerating {
                Button(role: .cancel, action: controller.cancel) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop generating")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    /// Inline model-load feedback shown above the input (hidden once a model is
    /// loaded). The persistent model identity lives in the status bar below.
    @ViewBuilder
    private var modelLoadCaption: some View {
        switch library.loadState {
        case .loaded:
            EmptyView()
        case let .failed(message):
            Text("Model failed to load: \(message)")
                .font(.supraCaption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case .loading:
            Text("Loading model…")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        case .idle:
            Text("Task models load on demand. Assign them in Models for model answers; verification can run without one.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        }
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
                Image(systemName: "paperclip").font(.body)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Attach files or images for this chat only (up to \(Self.maxAttachments)). They're read into the conversation, not saved to the matter.")
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
                        .font(.supraCaption)
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
                Text(attachmentError).font(.supraCaption).foregroundStyle(.secondary)
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
                options: controller.activeChatOptions,
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
                    Text(controller.activeChatOptions.preset.displayName)
                }
            }
            .buttonStyle(.ghost)
            .help("Generation settings")
            .popover(isPresented: $showGenerationSettings, arrowEdge: .bottom) {
                generationSettings
            }
        }
        .font(.supraCaption)
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
        .buttonStyle(.ghost)
        .help("Bounds legal research (CourtListener) to a jurisdiction")
        .popover(isPresented: $showJurisdiction, arrowEdge: .bottom) {
            jurisdictionSettings
        }
    }

    private var jurisdictionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jurisdiction").font(.supraTitle)
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
                .font(.supraCaption).foregroundStyle(.secondary)
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
        // Scoped to THIS chat (not the app-wide default): edits here become a per-chat
        // override that sticks with the chat. New chats start from Settings → Generation
        // Defaults.
        VStack(alignment: .leading, spacing: 14) {
            Text("Generation").font(.supraTitle)
            GhostSegmentedControl(
                selection: Binding(
                    get: { controller.activeChatOptions.preset },
                    set: { controller.setActiveChatPreset($0) }
                ),
                segments: GenerationPreset.userSelectableDefaults.map { ($0, $0.displayName, "") }
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", controller.activeChatOptions.temperature))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { controller.activeChatOptions.temperature },
                        set: { controller.setActiveChatTemperature($0) }
                    ),
                    in: 0...1, step: 0.05
                )
            }
            Stepper(
                "Max output tokens: \(controller.activeChatOptions.maxOutputTokens)",
                value: Binding(
                    get: { controller.activeChatOptions.maxOutputTokens },
                    set: { controller.setActiveChatMaxOutputTokens($0) }
                ),
                in: 128...8192, step: 128
            )
            Text("Applies to this chat. New chats start from Settings → Generation Defaults.")
                .font(.supraCaption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    /// Opens a tapped `[A#]` authority's CourtListener page.
    var onOpenAuthority: (URL) -> Void = { _ in }
    /// Opens a tapped `[S#]` matter-document citation in the trailing slide-over preview.
    var onOpenSource: (MessageCitation) -> Void = { _ in }
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
                // Expose as one accessibility leaf. A selectable `Text` otherwise
                // exposes per-run children whose role resolution cycles (role↔label)
                // and overflows the stack when the a11y tree is walked (VoiceOver /
                // the XCUITest harness); mouse selection is unaffected.
                .accessibilityElement(children: .ignore)
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
                        Text("System").font(.supraCaption.weight(.semibold)).foregroundStyle(.orange)
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(EmojiStripper.strip(reasoning)))
                } label: {
                    Label("Reasoning", systemImage: "brain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
            MarkdownView(
                text: displayContent,
                citationLabels: citationLabels,
                onCitationTap: handleCitationTap
            )
            // The assistant's answer is a long-form reading surface — body text with
            // reading leading and a capped line length so long statutory lines stay
            // comfortable to scan.
            .supraReadingBody()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Expose the rendered answer as one accessibility leaf. Markdown text
            // (`Text(AttributedString(markdown:))`), text selection, and the inline
            // `supracite://` citation links otherwise create per-run children whose
            // role resolution cycles (role↔label) and overflows the stack when the
            // a11y tree is walked (VoiceOver / the XCUITest harness). Mouse clicks and
            // selection don't traverse the a11y tree, so they keep working; the
            // citations stay independently actionable via the sources block below.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(displayContent))
            if !message.citations.isEmpty {
                sourcesBlock
            }
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

    /// Citation labels that should render as tappable inline links.
    private var citationLabels: Set<String> {
        Set(message.citations.map(\.label))
    }

    /// Routes a tapped citation (inline marker or sources-block row) to its action:
    /// authorities open their CourtListener page, sources open the preview at a page.
    private func handleCitationTap(_ label: String) {
        guard let citation = message.citations.first(where: { $0.label == label }) else { return }
        switch citation.kind {
        case .authority:
            if let urlString = citation.url, let url = URL(string: urlString) {
                onOpenAuthority(url)
            }
        case .source:
            onOpenSource(citation)
        }
    }

    /// A footnote-style, lighter-grey, indented list of the message's sources, set
    /// apart from the answer prose. Each row shares the inline marker's tap action.
    private var sourcesBlock: some View {
        // A subtle footnote list of the cited sources — visually quiet, but each row
        // is a link that opens the source preview at the cited chunk (with a snippet
        // highlight where the format supports it), mirroring the inline `[S#]` marker.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(message.citations) { citation in
                Button {
                    handleCitationTap(citation.label)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: citation.kind == .authority ? "link" : "doc.text.magnifyingglass")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(sourceLine(citation))
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(citation.kind == .authority ? "Open on CourtListener" : "Open the cited source")
                // One labeled a11y leaf (deriving the label from the child Image+Text
                // would make accessibility resolve their roles, which cycles role↔label
                // like the message text above).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(sourceLine(citation)))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("message.source.\(citation.label)")
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 32)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "[A1] Doe v. Smith" or "[S1] agreement.pdf — p. 3".
    private func sourceLine(_ citation: MessageCitation) -> String {
        let name = citation.displayName ?? (citation.kind == .authority ? "Authority" : "Document")
        var line = "[\(citation.label)] \(name)"
        if citation.kind == .source, let display = citation.locator?.displayString, !display.isEmpty {
            line += " — \(display)"
        }
        return line
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
            .font(.supraCaption.weight(.semibold))
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
    /// Citation labels ("A1", "S1") that should render as tappable links. Empty for
    /// ordinary messages, which then parse byte-identically to before.
    var citationLabels: Set<String> = []
    /// Invoked with a citation label when its inline marker is tapped.
    var onCitationTap: ((String) -> Void)?
    @State private var blocks: [MarkdownBlock] = []
    @State private var sourceText: String = ""
    @State private var sourceLabels: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let label = Self.citationLabel(from: url) else { return .systemAction }
            onCitationTap?(label)
            return .handled
        })
        .onAppear(perform: refresh)
        .onChange(of: text) { _, _ in refresh() }
        // Citations attach AFTER a fresh answer is generated (the streamed text is
        // unchanged), so re-link the inline markers when the labels arrive — otherwise
        // they stay plain text until the chat is reloaded.
        .onChange(of: citationLabels) { _, _ in refresh() }
    }

    /// Parse only when the text or its citation labels actually change, so
    /// hover/selection re-renders don't re-parse. Emojis are stripped once here (never
    /// inside code spacing, because the stripper only removes real emoji glyphs). When
    /// the message has citations, inline `[A#]`/`[S#]` markers are rewritten to tappable
    /// links first.
    private func refresh() {
        guard text != sourceText || citationLabels != sourceLabels else { return }
        sourceText = text
        sourceLabels = citationLabels
        let stripped = EmojiStripper.strip(text)
        let linked = citationLabels.isEmpty
            ? stripped
            : Self.citationLinked(stripped, labels: citationLabels)
        blocks = MarkdownParser.parse(linked)
    }

    /// Rewrites standalone `[A#]`/`[S#]` markers whose label is a known citation into
    /// custom-scheme Markdown links, e.g. `[A1]` → `[\[A1\]](supracite://A1)`. The
    /// escaped brackets keep the visible text literal ("[A1]"); the lookbehind avoids
    /// corrupting link syntax or path-like text. Unknown labels are left untouched.
    static func citationLinked(_ text: String, labels: Set<String>) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w/])\[([AS]\d{1,3})\]"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if labels.contains(label) {
                result += "[\\[\(label)\\]](supracite://\(label))"
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Extracts an uppercased citation label from a tapped `supracite://A1` URL.
    static func citationLabel(from url: URL) -> String? {
        guard url.scheme == "supracite" else { return nil }
        let raw = url.host ?? String(url.absoluteString.dropFirst("supracite://".count))
        return raw.isEmpty ? nil : raw.uppercased()
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
