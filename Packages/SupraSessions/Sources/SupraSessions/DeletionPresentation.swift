import Foundation

/// The user-owned aggregate affected by a deletion action. Keeping this typed
/// prevents each surface from inventing different permanence language.
public enum DeletionTargetKind: String, CaseIterable, Equatable, Sendable {
    case matter
    case chat
    case document
    case folder
}

public enum DeletionActionKind: Equatable, Sendable {
    case moveToRecycleBin
    case deletePermanently
}

public enum DeletionPresentationTone: Equatable, Sendable {
    case neutral
    case destructive
}

public struct DeletionActionPresentation: Equatable, Sendable {
    public let actionTitle: String
    public let confirmationTitle: String
    public let message: String
    public let tone: DeletionPresentationTone

    public static func make(
        action: DeletionActionKind,
        target: DeletionTargetKind,
        displayName: String
    ) -> Self {
        switch action {
        case .moveToRecycleBin:
            return Self(
                actionTitle: "Move to Recycle Bin",
                confirmationTitle: "Move “\(displayName)” to Recycle Bin?",
                message: softDeletionMessage(for: target),
                tone: .neutral
            )
        case .deletePermanently:
            return Self(
                actionTitle: "Delete Permanently",
                confirmationTitle: "Delete “\(displayName)” permanently?",
                message: permanentDeletionMessage(for: target),
                tone: .destructive
            )
        }
    }

    private static func softDeletionMessage(for target: DeletionTargetKind) -> String {
        switch target {
        case .matter:
            "This moves the matter and its chats to the Recycle Bin. You can restore them from the Recycle Bin."
        case .chat:
            "This moves the chat to the Recycle Bin. You can restore it from the Recycle Bin."
        case .document:
            "This moves the document to the Recycle Bin. You can restore it from the Recycle Bin."
        case .folder:
            "This moves the folder and its documents to the Recycle Bin. You can restore them from the Recycle Bin."
        }
    }

    private static func permanentDeletionMessage(for target: DeletionTargetKind) -> String {
        switch target {
        case .matter:
            "This removes the matter’s source data, chats, saved in-app outputs, and export records. Prior audit history and previously written export files remain. This cannot be undone."
        case .chat:
            "This permanently deletes the chat. This cannot be undone."
        case .document:
            "This removes the source and invalidates dependent work. Saved output text, citation display excerpts and locators, and retained proof records remain. Document classifications and relations are removed. Audit history and previously written export files remain. This cannot be undone."
        case .folder:
            "This permanently deletes the folder and its contents. This cannot be undone."
        }
    }
}

public struct RecycleBinNavigationPresentation: Equatable, Sendable {
    public let title: String
    public let accessibilityDescription: String
    public let tone: DeletionPresentationTone

    public static let standard = Self(
        title: "Recycle Bin",
        accessibilityDescription: "Restorable deleted items",
        tone: .neutral
    )
}
