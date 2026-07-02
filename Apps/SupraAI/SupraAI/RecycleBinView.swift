import SupraSessions
import SwiftUI

/// Lists soft-deleted matters, chats, and documents that the discard policy hasn't
/// purged yet, with per-item Restore and (confirmed) permanent delete.
struct RecycleBinView: View {
    @ObservedObject var controller: RecycleBinController
    @ObservedObject var matters: MattersController
    @ObservedObject var chats: GlobalChatController

    private enum PendingDelete: Identifiable {
        case matter(id: String, name: String)
        case chat(id: String, name: String)
        case document(id: String, name: String)

        var id: String {
            switch self {
            case let .matter(id, _): return "m:\(id)"
            case let .chat(id, _): return "c:\(id)"
            case let .document(id, _): return "d:\(id)"
            }
        }

        var name: String {
            switch self {
            case let .matter(_, name), let .chat(_, name), let .document(_, name): return name
            }
        }

        var isMatter: Bool { if case .matter = self { return true } else { return false } }
    }

    @State private var pendingDelete: PendingDelete?

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
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)” permanently?" } ?? "Delete permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) { performDelete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.isMatter
                ? "“\(item.name)” and all of its chats, documents, and files will be permanently deleted. This cannot be undone."
                : "“\(item.name)” will be permanently deleted. This cannot be undone.")
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

    private func performDelete(_ item: PendingDelete) {
        switch item {
        case let .matter(id, _): controller.permanentlyDeleteMatter(id: id); matters.loadMatters()
        case let .chat(id, _): controller.permanentlyDeleteChat(id: id)
        case let .document(id, _): controller.permanentlyDeleteDocument(id: id)
        }
        pendingDelete = nil
    }
}
