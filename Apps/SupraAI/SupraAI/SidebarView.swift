import SupraSessions
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @ObservedObject var matters: MattersController
    var onNewMatter: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(AppRoute.allCases) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(SidebarSelection.route(route))
            }

            // All matters live directly in the primary sidebar (no inner column).
            // List selection drives the highlight; the "+" creates a new matter.
            Section {
                ForEach(matters.matters) { matter in
                    Label(matter.name, systemImage: "folder")
                        .tag(SidebarSelection.matter(matter.id))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(matter.name)
                        .accessibilityIdentifier("matter.row.\(matter.name)")
                }
            } header: {
                HStack {
                    Text("Matters")
                    Spacer()
                    Button(action: onNewMatter) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Matter")
                }
            }
        }
        .navigationTitle("Supra AI")
        // Pinned to the very bottom of the sidebar (below the Matters list, which can
        // grow), so deleted items always have a clear, fixed home.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    selection = .recycleBin
                } label: {
                    Label("Recycle Bin", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selection == SidebarSelection.recycleBin ? Color.accentColor.opacity(0.15) : Color.clear)
                .accessibilityIdentifier("sidebar.recycleBin")
            }
            .background(.bar)
        }
        .onAppear {
            Task { @MainActor in matters.loadMatters() }
        }
    }
}
