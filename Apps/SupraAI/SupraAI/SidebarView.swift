import SupraSessions
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @ObservedObject var matters: MattersController
    var onNewMatter: () -> Void
    /// The row under the cursor, so its background can match the selection pill.
    @State private var hoveredRow: SidebarSelection?
    @State private var recycleBinHovering = false

    var body: some View {
        List(selection: $selection) {
            ForEach(AppRoute.allCases) { route in
                Label(route.title, systemImage: route.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { setRowHover($0, .route(route)) }
                    .listRowBackground(rowHoverBackground(.route(route)))
                    .tag(SidebarSelection.route(route))
            }

            // All matters live directly in the primary sidebar (no inner column).
            // List selection drives the highlight; the "+" creates a new matter.
            Section {
                ForEach(matters.matters) { matter in
                    Label(matter.name, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onHover { setRowHover($0, .matter(matter.id)) }
                        .listRowBackground(rowHoverBackground(.matter(matter.id)))
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
                    // Centered and destructive-tinted, mirroring the matter view's Delete
                    // button (red with a red hover wash) — sized as an inset pill for the bar.
                    Label("Recycle Bin", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(recycleBinFill)
                        )
                }
                .buttonStyle(.plain)
                .onHover { recycleBinHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: recycleBinHovering)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .accessibilityIdentifier("sidebar.recycleBin")
            }
            .background(.bar)
        }
        .onAppear {
            Task { @MainActor in matters.loadMatters() }
        }
    }

    private func setRowHover(_ inside: Bool, _ row: SidebarSelection) {
        if inside {
            hoveredRow = row
        } else if hoveredRow == row {
            hoveredRow = nil
        }
    }

    /// A row's hover wash, driven through `listRowBackground` so the system gives it the
    /// exact inset + rounding of the native selection pill — hover and selection then
    /// match by construction. The selected row is left to the native highlight.
    private func rowHoverBackground(_ row: SidebarSelection) -> Color {
        (hoveredRow == row && selection != row) ? Color.primary.opacity(0.09) : .clear
    }

    /// Recycle Bin fill: a stronger red when it's the active view, a lighter red on
    /// hover (matching the matter Delete button's danger wash), clear otherwise.
    private var recycleBinFill: Color {
        if selection == .recycleBin { return Color.red.opacity(0.18) }
        return recycleBinHovering ? Color.red.opacity(0.14) : .clear
    }
}
