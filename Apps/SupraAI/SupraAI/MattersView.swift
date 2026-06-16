import SupraSessions
import SwiftUI

/// Matters are folders that group chats. The left column lists matters; the
/// right side reuses the chat pane, scoped to the selected matter's chats.
struct MattersView: View {
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    @State private var showNewMatter = false
    @State private var newMatterName = ""

    var body: some View {
        HStack(spacing: 0) {
            matterList
                .frame(width: 240)
            Divider()
            conversation
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewMatter = true
                } label: {
                    Label("New Matter", systemImage: "folder.badge.plus")
                }
            }
        }
        .alert("New Matter", isPresented: $showNewMatter) {
            TextField("Matter name", text: $newMatterName)
            Button("Create") {
                let name = newMatterName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    try? controller.createMatter(name: name)
                }
                newMatterName = ""
            }
            Button("Cancel", role: .cancel) { newMatterName = "" }
        } message: {
            Text("Name this matter — e.g. a client or case.")
        }
        .task { controller.loadMatters() }
    }

    private var matterList: some View {
        List(selection: matterSelection) {
            ForEach(controller.matters) { matter in
                Label(matter.name, systemImage: "folder")
                    .tag(matter.id)
            }
        }
        .overlay {
            if controller.matters.isEmpty {
                ContentUnavailableView(
                    "No Matters",
                    systemImage: "folder.badge.gearshape",
                    description: Text("Create a matter to group related chats.")
                )
            }
        }
    }

    private var matterSelection: Binding<String?> {
        Binding(
            get: { controller.selectedMatterID },
            set: { controller.select(matterID: $0) }
        )
    }

    @ViewBuilder
    private var conversation: some View {
        if let chatController = controller.chatController {
            GlobalChatsView(controller: chatController, library: library)
        } else {
            ContentUnavailableView(
                "Select a Matter",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose or create a matter to start its chats.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
