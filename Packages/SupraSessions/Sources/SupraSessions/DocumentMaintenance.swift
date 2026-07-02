import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Periodic trash maintenance (plan §12.2): permanently purges document instances
/// that have been soft-deleted longer than the configured retention, removing
/// unreferenced blobs and recording a major audit event for each.
public final class DocumentMaintenance: @unchecked Sendable {
    public static let autoPurgeDaysKey = "documents.auto_purge_days"
    /// Default retention before auto-purge (plan §17 open decision, resolved).
    public static let defaultAutoPurgeDays = 30

    private let store: SupraStore
    private let storage: DocumentStorage

    public init(store: SupraStore, storage: DocumentStorage = .makeDefault()) {
        self.store = store
        self.storage = storage
    }

    public func autoPurgeDays() -> Int {
        (try? store.appSettings.getSetting(Self.autoPurgeDaysKey, as: Int.self)) ?? Self.defaultAutoPurgeDays
    }

    public func setAutoPurgeDays(_ days: Int) {
        try? store.appSettings.setSetting(Self.autoPurgeDaysKey, value: max(0, days))
    }

    /// Permanently deletes documents soft-deleted before the retention cutoff.
    /// A retention of 0 disables auto-purge. Returns the number purged.
    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int {
        let days = autoPurgeDays()
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = (try? store.documentLibrary.fetchDocumentsDeletedBefore(cutoff)) ?? []
        var purged = 0
        // A parent's permanent delete cascade-purges its attachment subtree, so a
        // child appearing later in `expired` is already gone — skip it to avoid an
        // over-count and a spurious second audit event.
        var alreadyPurged = Set<String>()
        for document in expired {
            if alreadyPurged.contains(document.id) { continue }
            do {
                let result = try store.documentLibrary.permanentlyDeleteDocument(id: document.id)
                for path in result.removedBlobPaths {
                    try? FileManager.default.removeItem(at: storage.url(forManagedRelativePath: path))
                }
                alreadyPurged.formUnion(result.removedDocumentIDs)
                _ = try? store.auditEvents.recordEvent(
                    matterID: document.matterID, eventType: "document_permanently_deleted", actor: "system",
                    summary: "Auto-purged a document deleted over \(days) days ago",
                    relatedTable: "matter_documents", relatedID: document.id
                )
                purged += 1
            } catch {
                // A document that can't be purged stays in the trash; record it so the
                // failure is visible in the audit trail rather than silently skipped.
                _ = try? store.auditEvents.recordEvent(
                    matterID: document.matterID, eventType: "document_permanent_delete_failed", actor: "system",
                    summary: "Auto-purge could not delete a document deleted over \(days) days ago: \(error.localizedDescription)",
                    relatedTable: "matter_documents", relatedID: document.id
                )
                continue
            }
        }
        return purged
    }

    /// Permanently deletes CHATS soft-deleted before the retention cutoff, using the
    /// same window as documents (0 disables). Matters are intentionally never
    /// auto-purged — they're removed only by an explicit permanent delete in the
    /// Recycle Bin. Returns the number purged.
    @discardableResult
    public func purgeExpiredChats(now: Date = Date()) -> Int {
        let days = autoPurgeDays()
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = (try? store.chats.fetchChatsDeletedBefore(cutoff)) ?? []
        var purged = 0
        for chat in expired {
            do {
                try store.chats.permanentlyDeleteChat(id: chat.id)
                // Matter chats get an audit trail; global chats have no matter to log under.
                if let matterID = chat.matterID {
                    _ = try? store.auditEvents.recordEvent(
                        matterID: matterID, eventType: "chat_permanently_deleted", actor: "system",
                        summary: "Auto-purged a chat deleted over \(days) days ago",
                        relatedTable: "chats", relatedID: chat.id
                    )
                }
                purged += 1
            } catch {
                // Matter chats get a failure audit; global chats have no matter to log
                // under (mirrors the success path), but a matter chat that won't purge
                // must not vanish silently.
                if let matterID = chat.matterID {
                    _ = try? store.auditEvents.recordEvent(
                        matterID: matterID, eventType: "chat_permanent_delete_failed", actor: "system",
                        summary: "Auto-purge could not delete a chat deleted over \(days) days ago: \(error.localizedDescription)",
                        relatedTable: "chats", relatedID: chat.id
                    )
                }
                continue
            }
        }
        return purged
    }
}
