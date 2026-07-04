import Foundation

extension Notification.Name {
    /// Posted by the Go menu; observed by MainShellView to drive the sidebar.
    static let supraNavigateToRoute = Notification.Name("SupraNavigateToRoute")
}

enum AppRoute: String, CaseIterable, Identifiable {
    case globalChats
    case scratchpad
    case publicRecords
    case models
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalChats:
            "Global Chats"
        case .scratchpad:
            "ScratchPad"
        case .publicRecords:
            "Public Records"
        case .models:
            "Models"
        case .diagnostics:
            "Diagnostics"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .globalChats:
            "bubble.left.and.bubble.right"
        case .scratchpad:
            "note.text"
        case .publicRecords:
            "building.columns"
        case .models:
            "cpu"
        case .diagnostics:
            "waveform.path.ecg"
        case .settings:
            "gearshape"
        }
    }
}

/// What the primary sidebar can have selected: a top-level route, or a specific
/// matter. Matters are listed directly in the sidebar (there is no separate
/// Matters route or inner matters column).
enum SidebarSelection: Hashable {
    case route(AppRoute)
    case matter(String)
    /// The Recycle Bin module, pinned to the bottom of the sidebar (below Matters).
    /// Kept out of `AppRoute` so it isn't rendered among the top-level routes.
    case recycleBin
}
