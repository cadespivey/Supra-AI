import SwiftUI

/// A three-level warning banner (spec §14.5): Info, Warning, Blocking. Blocking
/// is styled most prominently; the caller is responsible for also disabling the
/// blocked action.
public struct SupraWarningBanner: View {
    public enum Level: Sendable {
        case info
        case warning
        case blocking
    }

    private let level: Level
    private let title: String
    private let message: String?

    public init(_ level: Level, title: String, message: String? = nil) {
        self.level = level
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }

    private var color: Color {
        switch level {
        case .info: .blue
        case .warning: .orange
        case .blocking: .red
        }
    }
}
