import SupraSessions
import SwiftUI

/// The workspace for a single matter: a detail header plus the Milestone 2 tab
/// set (Chat, Research, Authorities, Outputs, Audit, and a disabled Documents
/// tab). Chat and Audit have real content here; Research/Authorities/Outputs are
/// placeholders until their work orders (WO 24–30) land.
struct MatterWorkspaceView: View {
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @State private var tab: MatterTab = .chat
    @State private var showEditor = false
    @State private var confirmingDelete = false

    enum MatterTab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case research = "Research"
        case authorities = "Authorities"
        case outputs = "Outputs"
        case audit = "Audit"
        case documents = "Documents"

        var id: String { rawValue }
        var isEnabled: Bool { self != .documents }
        var label: String { self == .documents ? "Documents — coming in next phase" : rawValue }
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
                    if item.isEnabled { tab = item }
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
                .disabled(!item.isEnabled)
                .help(item.isEnabled ? item.rawValue : "Documents are coming in a future phase.")
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func tabForeground(_ item: MatterTab) -> Color {
        if !item.isEnabled { return .secondary.opacity(0.6) }
        return tab == item ? .accentColor : .primary
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .chat:
            if let chatController = controller.chatController {
                GlobalChatsView(controller: chatController, library: library)
            } else {
                placeholder("Chat unavailable", "Select the matter again to load its chats.", systemImage: "bubble.left.and.bubble.right")
            }
        case .research:
            placeholder(
                "No Research Sessions",
                "Plan and run CourtListener research for this matter. Arriving in an upcoming work order.",
                systemImage: "magnifyingglass"
            )
        case .authorities:
            placeholder(
                "No Authorities Saved",
                "Save reviewed CourtListener results to build this matter's authority library.",
                systemImage: "books.vertical"
            )
        case .outputs:
            placeholder(
                "No Outputs",
                "Generate structured legal outputs (issue spotting, rule synthesis, drafting skeletons) for this matter.",
                systemImage: "doc.text"
            )
        case .audit:
            auditTab
        case .documents:
            placeholder(
                "Documents — coming in next phase",
                "Document ingestion isn't part of this milestone.",
                systemImage: "doc.on.doc"
            )
        }
    }

    @ViewBuilder
    private var auditTab: some View {
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

    private func placeholder(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
