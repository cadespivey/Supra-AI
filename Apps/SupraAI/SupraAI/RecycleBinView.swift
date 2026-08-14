import SupraSessions
import SwiftUI

extension DeletionPresentationTone {
    var buttonRole: ButtonRole? {
        self == .destructive ? .destructive : nil
    }
}

extension View {
    @ViewBuilder
    func deletionButtonStyle(_ tone: DeletionPresentationTone) -> some View {
        switch tone {
        case .neutral:
            buttonStyle(.ghost)
        case .destructive:
            buttonStyle(.ghostDanger)
        }
    }
}

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

    var kind: DeletionTargetKind {
        switch self {
        case .matter: .matter
        case .chat: .chat
        case .document: .document
        }
    }

    var name: String {
        switch self {
        case let .matter(_, name), let .chat(_, name), let .document(_, name): name
        }
    }

    var presentation: DeletionActionPresentation {
        .make(action: .deletePermanently, target: kind, displayName: name)
    }
}

private enum RestoreTarget {
    case matter(String)
    case chat(String)
    case document(String)
}

private struct PermanentDeletionConfirmationModifier: ViewModifier {
    @Binding var target: PermanentDeletionTarget?
    let perform: (PermanentDeletionTarget) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target?.presentation.confirmationTitle ?? "Delete permanently?",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            titleVisibility: .visible,
            presenting: target
        ) { item in
            Button(item.presentation.actionTitle, role: item.presentation.tone.buttonRole) {
                perform(item)
                target = nil
            }
            .accessibilityIdentifier("recycleBin.deletePermanently.confirm")
            Button("Cancel", role: .cancel) { target = nil }
        } message: { item in
            Text(item.presentation.message)
                .accessibilityIdentifier("recycleBin.deletePermanently.message")
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
    @State private var pendingRestore: RestoreTarget?

    var body: some View {
        VStack(spacing: 0) {
            if let failure = controller.lastMutationFailure,
               pendingRestore != nil {
                UserMutationFailureBanner(
                    failure: failure,
                    retry: retryRestore,
                    correct: correctRestore
                )
                .padding([.horizontal, .top], 10)
                .accessibilityIdentifier("recycleBin.mutationFailure")
            }
            Group {
                if controller.isEmpty {
                    emptyState
                } else {
                    list
                }
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
                        row(kind: .matter, icon: "folder", title: matter.name, subtitle: "Matter", deletedAt: matter.deletedAt,
                            restore: { performRestore(.matter(matter.id)) },
                            delete: { pendingDelete = .matter(id: matter.id, name: matter.name) })
                    }
                }
            }
            if !controller.chats.isEmpty {
                Section("Chats") {
                    ForEach(controller.chats) { chat in
                        let title = chat.title.isEmpty ? "Untitled chat" : chat.title
                        row(kind: .chat, icon: "bubble.left.and.bubble.right", title: title, subtitle: chat.context, deletedAt: chat.deletedAt,
                            restore: { performRestore(.chat(chat.id)) },
                            delete: { pendingDelete = .chat(id: chat.id, name: title) })
                    }
                }
            }
            if !controller.documents.isEmpty {
                Section("Documents") {
                    ForEach(controller.documents) { doc in
                        row(kind: .document, icon: "doc", title: doc.name, subtitle: doc.matterName, deletedAt: doc.deletedAt,
                            restore: { performRestore(.document(doc.id)) },
                            delete: { pendingDelete = .document(id: doc.id, name: doc.name) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        kind: DeletionTargetKind, icon: String, title: String, subtitle: String, deletedAt: Date?,
        restore: @escaping () -> Void, delete: @escaping () -> Void
    ) -> some View {
        let permanentPresentation = DeletionActionPresentation.make(
            action: .deletePermanently,
            target: kind,
            displayName: title
        )
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
            Button("Restore", action: restore)
                .buttonStyle(.ghost)
                .controlSize(.small)
                .accessibilityIdentifier("recycleBin.restore.\(kind.rawValue).\(title)")
            Button(role: permanentPresentation.tone.buttonRole, action: delete) {
                Image(systemName: "trash")
            }
                .deletionButtonStyle(permanentPresentation.tone)
                .help(permanentPresentation.actionTitle)
                .accessibilityLabel(permanentPresentation.actionTitle)
                .accessibilityIdentifier("recycleBin.deletePermanently.\(kind.rawValue).\(title)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recycleBin.item.\(kind.rawValue).\(title)")
    }

    private func performDelete(_ item: PermanentDeletionTarget) {
        switch item {
        case let .matter(id, _): controller.permanentlyDeleteMatter(id: id); matters.loadMatters()
        case let .chat(id, _): controller.permanentlyDeleteChat(id: id)
        case let .document(id, _): controller.permanentlyDeleteDocument(id: id)
        }
    }

    private func performRestore(_ target: RestoreTarget) {
        pendingRestore = target
        let outcome: UserMutationOutcome<String>
        switch target {
        case let .matter(id):
            outcome = controller.attemptRestoreMatter(id: id)
        case let .chat(id):
            outcome = controller.attemptRestoreChat(id: id)
        case let .document(id):
            outcome = controller.attemptRestoreDocument(id: id)
        }
        guard outcome.allowsSuccessPresentation else { return }
        pendingRestore = nil
        switch target {
        case .matter:
            matters.loadMatters()
        case .chat:
            chats.loadChats()
        case .document:
            break
        }
    }

    private func retryRestore() {
        guard let pendingRestore else { return }
        performRestore(pendingRestore)
    }

    private func correctRestore() {
        pendingRestore = nil
        controller.reload()
    }
}
