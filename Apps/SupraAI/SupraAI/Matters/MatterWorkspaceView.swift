import SupraSessions
import SwiftUI

/// The workspace for a single matter: a detail header plus the matter tab set
/// (Chat, Research, Authorities, Outputs, Documents, and Audit). Audit is placed
/// last as the least frequently used tab.
struct MatterWorkspaceView: View {
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    @ObservedObject var queue: DocumentProcessingQueue
    @ObservedObject var settings: SettingsController
    let matter: MatterSummary

    @State private var tab: MatterTab = .chat
    @State private var showEditor = false
    @State private var confirmingDelete = false

    enum MatterTab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case research = "Research"
        case authorities = "Authorities"
        case outputs = "Outputs"
        case documents = "Documents"
        case audit = "Audit"

        var id: String { rawValue }
        var label: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showEditor) {
            MatterEditorSheet(
                mode: .edit,
                draft: controller.draft(forMatter: matter.id) ?? MatterDraft()
            ) { draft in
                try? controller.updateMatter(id: matter.id, draft: draft)
            }
        }
        .confirmationDialog(
            "Delete “\(matter.name)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Matter", role: .destructive) { controller.deleteMatter(id: matter.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This hides the matter and its chats. You can't undo this from the app.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(matter.name).font(.title2.weight(.semibold))
                Text("\(matter.jurisdiction) · \(matter.partyPerspective.rawValue.capitalized)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showEditor = true } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding()
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MatterTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.label)
                        .font(.callout.weight(tab == item ? .semibold : .regular))
                        .foregroundStyle(tabForeground(item))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            tab == item ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
                .accessibilityIdentifier("matterTab.\(item.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func tabForeground(_ item: MatterTab) -> Color {
        tab == item ? .accentColor : .primary
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .chat:
            if let chatController = controller.chatController {
                GlobalChatsView(controller: chatController, library: library, settings: settings, listStyle: .inline)
            } else {
                placeholder("Chat unavailable", "Select the matter again to load its chats.", systemImage: "bubble.left.and.bubble.right")
            }
        case .research:
            if let research = controller.researchController {
                MatterResearchView(controller: research, library: library, matter: matter)
            } else {
                placeholder(
                    "Research unavailable",
                    "Select the matter again to load its research sessions.",
                    systemImage: "magnifyingglass"
                )
            }
        case .authorities:
            if let authorities = controller.authoritiesController {
                MatterAuthoritiesView(controller: authorities, onNewResearch: { tab = .research })
            } else {
                placeholder(
                    "Authorities unavailable",
                    "Select the matter again to load its authority library.",
                    systemImage: "books.vertical"
                )
            }
        case .outputs:
            if let outputs = controller.outputsController {
                MatterOutputsView(controller: outputs, matter: matter, loadedModelID: library.loadedModelID)
            } else {
                placeholder(
                    "Outputs unavailable",
                    "Select the matter again to load its structured outputs.",
                    systemImage: "doc.text"
                )
            }
        case .audit:
            auditTab
        case .documents:
            if let documents = controller.documentsController {
                MatterDocumentsView(
                    controller: documents,
                    queue: queue,
                    qaController: controller.documentQAController,
                    chronologyController: controller.documentChronologyController,
                    loadedModelID: library.loadedModelID
                )
            } else {
                placeholder(
                    "Documents unavailable",
                    "Select the matter again to load its documents.",
                    systemImage: "doc.on.doc"
                )
            }
        }
    }

    @ViewBuilder
    private var auditTab: some View {
        MatterTabScaffold("Activity Log") {
            let entries = controller.auditEntries(forMatter: matter.id)
            if entries.isEmpty {
                placeholder("No Activity Yet", "Matter, research, authority, and output actions are logged here.", systemImage: "list.bullet.rectangle")
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.eventType).font(.callout.weight(.medium))
                            Spacer()
                            Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func placeholder(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Uniform chrome for a matter's list-style tabs (Research, Authorities, Outputs,
/// Audit): a title row with optional trailing actions, a divider, and a content
/// area that fills the remaining height — so empty states stay centered instead of
/// floating in the middle of the pane.
struct MatterTabScaffold<Actions: View, Content: View>: View {
    private let title: String
    private let actions: Actions
    private let content: Content

    init(
        _ title: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                actions
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
