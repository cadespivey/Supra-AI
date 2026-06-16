import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppRoute?

    var body: some View {
        List(AppRoute.allCases, selection: $selection) { route in
            Label(route.title, systemImage: route.systemImage)
                .tag(route as AppRoute?)
        }
        .navigationTitle("Supra AI")
    }
}
