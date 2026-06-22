import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// Notification permission + delivery for long-running document import/indexing
/// notices (plan §5.6). Abstracted behind a protocol so setup logic can be unit
/// tested without the system notification center / app entitlements.
public enum DocumentNotificationAuthorizationStatus: String, Sendable {
    case notDetermined = "not_determined"
    case denied
    case authorized
    case provisional
    case unknown
}

public protocol DocumentNotifying: Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus
    @discardableResult
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus
    func notify(title: String, body: String) async
}

/// System implementation backed by `UNUserNotificationCenter`.
public struct SystemDocumentNotifier: DocumentNotifying {
    public init() {}

    public func authorizationStatus() async -> DocumentNotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    @discardableResult
    public func requestAuthorization() async -> DocumentNotificationAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    public func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Attach the running app's own icon so the notification visibly carries the
        // Supra logo (a local notification otherwise shows only the system-resolved
        // bundle icon, which can be wrong/generic). Sourcing it from the live app
        // icon keeps it correct without bundling a separate image.
        if let attachment = await Self.appIconAttachment() {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Renders the app's icon to a temp PNG and wraps it as a notification
    /// attachment. Returns nil on platforms without AppKit or if rendering fails.
    private static func appIconAttachment() async -> UNNotificationAttachment? {
        #if canImport(AppKit)
        let pngData: Data? = await MainActor.run {
            let icon: NSImage? = NSApplication.shared.applicationIconImage
            guard let tiff = icon?.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        guard let pngData else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supra-notification-icon-\(UUID().uuidString).png")
        guard (try? pngData.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "appIcon", url: url, options: nil)
        #else
        return nil
        #endif
    }

    private static func map(_ status: UNAuthorizationStatus) -> DocumentNotificationAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .authorized
        @unknown default: .unknown
        }
    }
}
