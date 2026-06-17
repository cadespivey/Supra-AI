import Foundation
import UserNotifications

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
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
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
