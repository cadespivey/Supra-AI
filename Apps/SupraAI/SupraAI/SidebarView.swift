import SupraSessions
import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppRoute?
    @ObservedObject var matters: MattersController
    var onNewMatter: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(AppRoute.allCases) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }

            // Recent matters under the Matters route (spec §14.1): tappable, with
            // the active matter highlighted, plus a New Matter button.
            if !matters.matters.isEmpty {
                Section {
                    ForEach(matters.matters.prefix(5)) { matter in
                        Button {
                            selection = .matters
                            matters.select(matterID: matter.id)
                        } label: {
                            Label(matter.name, systemImage: "folder")
                                .fontWeight(matter.id == matters.selectedMatterID ? .semibold : .regular)
                                .foregroundStyle(matter.id == matters.selectedMatterID ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Recent Matters")
                        Spacer()
                        Button(action: onNewMatter) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Matter")
                    }
                }
            }
        }
        .navigationTitle("Supra AI")
        .onAppear { matters.loadMatters() }
    }
}
