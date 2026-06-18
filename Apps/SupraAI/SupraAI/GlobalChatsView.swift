import SupraCore
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// The first persisted global chat flow: pick or create a chat, send a prompt
/// to the loaded model, and watch the answer stream in.
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
    @State private var showAttachmentImporter = false
    @State private var isLoadingAttachment = false

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
    }

    // MARK: - Chat selector

    private var chatBar: some View {
        HStack(spacing: 12) {
            if controller.chats.isEmpty {
                Text("No chats yet")
                    .foregroundStyle(.secondary)
            } else {
                switch listStyle {
                case .picker:
                    Picker("Chat", selection: chatSelection) {
                        ForEach(controller.chats) { chat in
                            Text(chat.title).tag(chat.id as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                case .inline:
                    inlineChatList
                }
            }
            Spacer()
            Button {
                _ = try? controller.createChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .padding(12)
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

    private var chatSelection: Binding<String?> {
        Binding(
            get: { controller.selectedChatID },
            set: { controller.select(chatID: $0) }
        )
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
                    description: Text("Ask the loaded model a question to begin.")
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
                Text("Load a model in the Models tab to start chatting.")
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
                    .disabled(controller.isGenerating)
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
        .fileImporter(
            isPresented: $showAttachmentImporter,
            allowedContentTypes: [.image, .plainText, .text, .sourceCode, .pdf, .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { addAttachments(urls) }
        }
    }

    // MARK: - Attachments (global chat only)

    /// Attach files/images/screenshots into the model's context. Heavy documents
    /// (PDF, Word, Excel) are declined with a nudge to open a matter.
    private var attachButton: some View {
        Button {
            attachmentError = nil
            showAttachmentImporter = true
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
        library.loadedModelID != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let modelID = library.loadedModelID else { return }
        controller.send(prompt: draft, modelID: modelID, attachments: attachments)
        draft = ""
        attachments = []
        attachmentError = nil
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
            Button { showGenerationSettings.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(settings.preset.rawValue.capitalized)
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

    private var modelStatusText: String {
        switch library.loadState {
        case .loaded: library.loadedModel?.displayName ?? "Model loaded"
        case .loading: "Loading model…"
        case .failed: "Model failed to load"
        case .idle: "No model loaded"
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
                ForEach(GenerationPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue.capitalized).tag(preset)
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
    @State private var reasoningExpanded = false

    var body: some View {
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
                DisclosureGroup(isExpanded: $reasoningExpanded) {
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
            Text(displayContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(roleColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
