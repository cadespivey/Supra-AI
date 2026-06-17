import SupraSessions
import SwiftUI

/// Matters are legal workspaces. The left column lists matters; selecting one
/// opens its workspace (Chat, Research, Authorities, Outputs, Audit, Documents).
struct MattersView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    @State private var showNewMatter = false

    var body: some View {
        HStack(spacing: 0) {
            matterList
                .frame(width: 260)
            Divider()
            detail
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
        .sheet(isPresented: $showNewMatter) {
            MatterEditorSheet(mode: .create, draft: MatterDraft()) { draft in
                _ = try? controller.createMatter(draft)
            }
        }
        .task { controller.loadMatters() }
        .onChange(of: environment.newMatterRequests) { _, _ in showNewMatter = true }
    }

    private var matterList: some View {
        List(selection: matterSelection) {
            ForEach(controller.matters) { matter in
                VStack(alignment: .leading, spacing: 2) {
                    Text(matter.name)
                    Text("\(matter.jurisdiction) · \(matter.partyPerspective.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(matter.id)
            }
        }
        .overlay {
            if controller.matters.isEmpty {
                ContentUnavailableView {
                    Label("No Matters", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Create a matter to organize chats, research, and outputs.")
                } actions: {
                    Button("New Matter") { showNewMatter = true }
                }
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
    private var detail: some View {
        if let matter = controller.selectedMatter {
            MatterWorkspaceView(controller: controller, library: library, matter: matter)
        } else {
            ContentUnavailableView(
                "Select a Matter",
                systemImage: "folder",
                description: Text("Choose or create a matter to open its workspace.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
