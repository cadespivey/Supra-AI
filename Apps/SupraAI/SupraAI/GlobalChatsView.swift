import SupraCore
import SupraSessions
import SwiftUI

/// The first persisted global chat flow: pick or create a chat, send a prompt
/// to the loaded model, and watch the answer stream in.
struct GlobalChatsView: View {
    @ObservedObject var controller: GlobalChatController
    @ObservedObject var library: ModelLibrary
    @State private var draft = ""

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
        }
    }

    // MARK: - Chat selector

    private var chatBar: some View {
        HStack(spacing: 12) {
            if controller.chats.isEmpty {
                Text("No chats yet")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Chat", selection: chatSelection) {
                    ForEach(controller.chats) { chat in
                        Text(chat.title).tag(chat.id as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
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
            if library.loadedModelID == nil {
                Text("Load a model in the Models tab to start chatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
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
    }

    private var canSend: Bool {
        library.loadedModelID != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let modelID = library.loadedModelID else { return }
        controller.send(prompt: draft, modelID: modelID)
        draft = ""
    }
}

private struct MessageRow: View {
    let message: ChatMessage

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
            Text(displayContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(roleColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
        // (reasoning included) stays persisted; we only strip it for display.
        // While a reasoning model is still inside its <think> block the answer
        // is empty, so show a thinking placeholder.
        let answer = ReasoningContent.answer(from: message.content)
        if answer.isEmpty {
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
