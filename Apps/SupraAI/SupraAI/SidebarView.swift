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
                if isGroupedSortMode {
                    // Grouped modes (client / practice area): a non-selectable
                    // group label above each run of matters (order comes from
                    // the controller, which sorts the groups).
                    ForEach(groupedRows) { row in
                        switch row {
                        case .groupLabel(_, let name):
                            Text(name)
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .selectionDisabled()
                        case .matter(let matter):
                            matterRow(matter)
                        }
                    }
                } else {
                    ForEach(matters.matters) { matter in
                        // Pinned rows float above the manual order and aren't
                        // draggable — a cross-partition drop would snap back.
                        matterRow(matter)
                            .moveDisabled(matter.isPinned)
                    }
                    // Drag-to-reorder only in manual mode; in the derived sorts a
                    // drop would be silently re-sorted away.
                    .onMove(perform: moveHandler)
                }
            } header: {
                // Sized up to read like the module rows above (supraBody), with
                // the + scaled to visually match the sort arrows' glyph.
                HStack {
                    Text("Matters")
                    Spacer()
                    Menu {
                        Picker("Sort By", selection: sortModeBinding) {
                            ForEach(MatterSortMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort Matters")
                    .accessibilityIdentifier("sidebar.sortMatters")
                    Button(action: onNewMatter) {
                        Image(systemName: "plus")
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .help("New Matter")
                }
                .font(.supraBody)
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

    private func matterRow(_ matter: MatterSummary) -> some View {
        HStack(spacing: 4) {
            Label(matter.name, systemImage: "folder")
            Spacer(minLength: 0)
            if matter.isPinned {
                Image(systemName: "pin.fill")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { setRowHover($0, .matter(matter.id)) }
        .listRowBackground(rowHoverBackground(.matter(matter.id)))
        .tag(SidebarSelection.matter(matter.id))
        .contextMenu {
            Button(matter.isPinned ? "Unpin" : "Pin") {
                matters.setPinned(matterID: matter.id, pinned: !matter.isPinned)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(matter.name)
        .accessibilityValue(matter.isPinned ? "Pinned" : "Not pinned")
        .accessibilityAction(named: matter.isPinned ? "Unpin" : "Pin") {
            matters.setPinned(matterID: matter.id, pinned: !matter.isPinned)
        }
        .accessibilityIdentifier("matter.row.\(matter.name)")
    }

    private var sortModeBinding: Binding<MatterSortMode> {
        Binding(
            get: { matters.sortMode },
            set: { matters.setSortMode($0) }
        )
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard matters.sortMode == .manual else { return nil }
        return { matters.moveMatters(fromOffsets: $0, toOffset: $1) }
    }

    private var isGroupedSortMode: Bool {
        matters.sortMode == .client || matters.sortMode == .practiceArea
    }

    /// A grouped-mode list with a label row opening each run of matters. The
    /// controller has already ordered matters by group, so groups are just runs
    /// of equal group key.
    private enum GroupedRow: Identifiable {
        case groupLabel(key: String, name: String)
        case matter(MatterSummary)

        var id: String {
            switch self {
            case .groupLabel(let key, _): return "group.\(key)"
            case .matter(let matter): return matter.id
            }
        }
    }

    private var groupedRows: [GroupedRow] {
        var rows: [GroupedRow] = []
        var currentKey: String?
        for matter in matters.matters {
            // Pinned matters (always first) sit under one "Pinned" label rather
            // than fragmenting the groups below them.
            let (key, name) = matter.isPinned ? ("pinned", "Pinned") : groupIdentity(matter)
            if key != currentKey {
                currentKey = key
                rows.append(.groupLabel(key: key, name: name))
            }
            rows.append(.matter(matter))
        }
        return rows
    }

    private func groupIdentity(_ matter: MatterSummary) -> (key: String, name: String) {
        switch matters.sortMode {
        case .practiceArea:
            // "pa:" namespaces the key so a practice area literally named
            // "Pinned" can't collide with the pinned sentinel row.
            let label = matter.practiceAreaGroupLabel
                ?? matter.practiceArea?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("pa:\(matter.practiceAreaGroupKey)", label?.isEmpty == false ? label! : "No Practice Area")
        default:
            return (matter.clientGroupKey, matter.clientGroupLabel ?? "No Client")
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
