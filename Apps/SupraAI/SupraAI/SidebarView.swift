import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppRoute?

    var body: some View {
        List(selection: $selection) {
            ForEach(AppRoute.allCases) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }
        }
        .navigationTitle("Supra AI")
    }
}
