import SupraSessions
import SwiftUI

enum PermanentDeletionTarget: Identifiable {
    case matter(id: String, name: String)
    case chat(id: String, name: String)
    case document(id: String, name: String)

    var id: String {
        switch self {
        case let .matter(id, _): "m:\(id)"
        case let .chat(id, _): "c:\(id)"
        case let .document(id, _): "d:\(id)"
        }
    }

    var confirmationTitle: String {
        switch self {
        case let .matter(_, name): "Delete “\(name)” permanently?"
        case let .chat(_, name): "Delete “\(name)” permanently?"
        case let .document(_, name): "Remove “\(name)” permanently?"
        }
    }

    var actionTitle: String {
        switch self {
        case .matter: "Delete Matter"
        case .chat: "Delete Chat"
        case .document: "Remove Source"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .matter:
            "This removes the matter’s source data, chats, saved in-app outputs, and export records. Prior audit history and previously written export files remain. This cannot be undone."
        case .document:
            "Removing this source invalidates dependent work. Saved output text, citation display excerpts and locators, and retained corpus-analysis proof records remain. Document classifications and relations are removed. Audit history and previously written export files remain. This cannot be undone."
        case .chat:
            "This permanently deletes the chat. This cannot be undone."
        }
    }
}

private struct PermanentDeletionConfirmationModifier: ViewModifier {
    @Binding var target: PermanentDeletionTarget?
    let perform: (PermanentDeletionTarget) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target?.confirmationTitle ?? "Delete permanently?",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            titleVisibility: .visible,
            presenting: target
        ) { item in
            Button(item.actionTitle, role: .destructive) {
                perform(item)
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { item in
            Text(item.confirmationMessage)
        }
    }
}

extension View {
    func permanentDeletionConfirmation(
        target: Binding<PermanentDeletionTarget?>,
        perform: @escaping (PermanentDeletionTarget) -> Void
    ) -> some View {
        modifier(PermanentDeletionConfirmationModifier(target: target, perform: perform))
    }
}

/// Lists soft-deleted matters, chats, and documents that the discard policy hasn't
/// purged yet, with per-item Restore and (confirmed) permanent delete.
struct RecycleBinView: View {
    @ObservedObject var controller: RecycleBinController
    @ObservedObject var matters: MattersController
    @ObservedObject var chats: GlobalChatController

    @State private var pendingDelete: PermanentDeletionTarget?

    var body: some View {
        Group {
            if controller.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Recycle Bin")
        .onAppear { controller.reload() }
        .permanentDeletionConfirmation(target: $pendingDelete, perform: performDelete)
        .alert(
            "Deletion needs attention",
            isPresented: Binding(
                get: { controller.deletionError != nil },
                set: { if !$0 { controller.clearDeletionError() } }
            )
        ) {
            Button("OK") { controller.clearDeletionError() }
        } message: {
            Text(controller.deletionError ?? "The deletion could not be completed.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "trash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Recycle Bin is empty").font(.supraTitle)
            Text("Deleted matters, chats, and documents appear here until you restore them or the discard policy purges them.")
                .font(.supraSubheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("recycleBin.empty")
    }

    private var list: some View {
        List {
            if !controller.matters.isEmpty {
                Section("Matters") {
                    ForEach(controller.matters) { matter in
                        row(icon: "folder", title: matter.name, subtitle: "Matter", deletedAt: matter.deletedAt,
                            restore: { controller.restoreMatter(id: matter.id); matters.loadMatters() },
                            delete: { pendingDelete = .matter(id: matter.id, name: matter.name) })
                    }
                }
            }
            if !controller.chats.isEmpty {
                Section("Chats") {
                    ForEach(controller.chats) { chat in
                        let title = chat.title.isEmpty ? "Untitled chat" : chat.title
                        row(icon: "bubble.left.and.bubble.right", title: title, subtitle: chat.context, deletedAt: chat.deletedAt,
                            restore: { controller.restoreChat(id: chat.id); chats.loadChats() },
                            delete: { pendingDelete = .chat(id: chat.id, name: title) })
                    }
                }
            }
            if !controller.documents.isEmpty {
                Section("Documents") {
                    ForEach(controller.documents) { doc in
                        row(icon: "doc", title: doc.name, subtitle: doc.matterName, deletedAt: doc.deletedAt,
                            restore: { controller.restoreDocument(id: doc.id) },
                            delete: { pendingDelete = .document(id: doc.id, name: doc.name) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        icon: String, title: String, subtitle: String, deletedAt: Date?,
        restore: @escaping () -> Void, delete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                    if let deletedAt {
                        Text("·")
                        Text("deleted \(deletedAt, format: .relative(presentation: .numeric))")
                    }
                }
                .font(.supraCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: restore).buttonStyle(.ghost).controlSize(.small)
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.ghostDanger).help("Delete permanently")
        }
        .padding(.vertical, 2)
    }

    private func performDelete(_ item: PermanentDeletionTarget) {
        switch item {
        case let .matter(id, _): controller.permanentlyDeleteMatter(id: id); matters.loadMatters()
        case let .chat(id, _): controller.permanentlyDeleteChat(id: id)
        case let .document(id, _): controller.permanentlyDeleteDocument(id: id)
        }
    }
}
