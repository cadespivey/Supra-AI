import Foundation

enum AppRoute: String, CaseIterable, Identifiable {
    case globalChats
    case matters
    case models
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalChats:
            "Global Chats"
        case .matters:
            "Matters"
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
        case .matters:
            "folder"
        case .models:
            "cpu"
        case .diagnostics:
            "waveform.path.ecg"
        case .settings:
            "gearshape"
        }
    }
}
