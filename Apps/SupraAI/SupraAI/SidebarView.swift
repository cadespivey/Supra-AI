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
        .onAppear { matters.loadMatters() }
    }
}
