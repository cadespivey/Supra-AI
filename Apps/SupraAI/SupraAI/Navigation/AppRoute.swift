import Foundation

enum AppRoute: String, CaseIterable, Identifiable {
    case globalChats
    case models
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalChats:
            "Global Chats"
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
}
