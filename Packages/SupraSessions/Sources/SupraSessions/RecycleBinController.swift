import Combine
import Foundation
import SupraDocuments
import SupraStore

/// Backs the Recycle Bin: lists soft-deleted matters, chats, and documents that the
/// retention policy hasn't yet purged, and restores or permanently removes them.
///
/// Scope notes:
/// - Documents trashed as part of a matter delete are restored *with* the matter, so
///   only individually-trashed documents (matter still live) are listed here.
/// - Matters are never auto-purged by the discard policy; permanent removal is manual
///   and irreversible (it deletes the matter and all its chats, documents, and blobs).
@MainActor
public final class RecycleBinController: ObservableObject {
    public struct DeletedMatter: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let deletedAt: Date?
    }

    public struct DeletedChat: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        /// "Global" or the owning matter's name.
        public let context: String
        public let deletedAt: Date?
    }

    public struct DeletedDocument: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let matterID: String
        public let matterName: String
        public let deletedAt: Date?
    }

    @Published public private(set) var matters: [DeletedMatter] = []
    @Published public private(set) var chats: [DeletedChat] = []
    @Published public private(set) var documents: [DeletedDocument] = []
    @Published public private(set) var deletionError: String?

    private let store: SupraStore
    private let storage: DocumentStorage

    public init(store: SupraStore, storage: DocumentStorage = .makeDefault()) {
        self.store = store
        self.storage = storage
    }

    public var isEmpty: Bool { matters.isEmpty && chats.isEmpty && documents.isEmpty }

    public func reload() {
        let deletedMatters = (try? store.matters.fetchSoftDeletedMatters()) ?? []
        let liveMatters = (try? store.matters.fetchMatters()) ?? []
        var nameByID: [String: String] = [:]
        for matter in liveMatters + deletedMatters { nameByID[matter.id] = matter.name }

        matters = deletedMatters.map { DeletedMatter(id: $0.id, name: $0.name, deletedAt: $0.deletedAt) }

        chats = ((try? store.chats.fetchSoftDeletedChats()) ?? []).map { record in
            let context = record.matterID.flatMap { nameByID[$0] } ?? "Global"
            return DeletedChat(id: record.id, title: record.title, context: context, deletedAt: record.deletedAt)
        }

        documents = ((try? store.documentLibrary.fetchAllSoftDeletedDocuments()) ?? []).map { record in
            DeletedDocument(
                id: record.id,
                name: record.displayName,
                matterID: record.matterID,
                matterName: nameByID[record.matterID] ?? "—",
                deletedAt: record.deletedAt
            )
        }
    }

    // MARK: - Restore

    public func restoreMatter(id: String) {
        _ = try? store.matters.restoreMatter(id: id)
        reload()
    }

    public func restoreChat(id: String) {
        _ = try? store.chats.restoreChat(id: id)
        reload()
    }

    public func restoreDocument(id: String) {
        _ = try? store.documentLibrary.restoreDocument(id: id)
        reload()
    }

    // MARK: - Permanent delete

    /// Irreversibly deletes a matter and everything it owns, freeing any blob files no
    /// longer referenced by a surviving document.
    public func permanentlyDeleteMatter(id: String) {
        deletionError = nil
        do {
            let freed = try store.matters.permanentlyDeleteMatter(id: id, actor: "user")
            let orphanedBlobCount = removeBlobFiles(freed)
            if orphanedBlobCount > 0 {
                deletionError = "The matter was removed, but \(orphanedBlobCount) managed file(s) still need cleanup."
                recordCleanupFailure(
                    matterID: nil,
                    eventType: "matter_blob_cleanup_failed",
                    relatedTable: "matters",
                    relatedID: id,
                    orphanedBlobCount: orphanedBlobCount
                )
            }
        } catch {
            deletionError = "Couldn’t permanently delete the matter: \(error.localizedDescription)"
        }
        reload()
    }

    public func permanentlyDeleteChat(id: String) {
        deletionError = nil
        do {
            try store.chats.permanentlyDeleteChat(id: id)
        } catch {
            deletionError = "Couldn’t permanently delete the chat: \(error.localizedDescription)"
        }
        reload()
    }

    public func permanentlyDeleteDocument(id: String) {
        deletionError = nil
        let owningMatterID = documents.first { $0.id == id }?.matterID
            ?? (try? store.documentLibrary.fetchDocument(id: id))?.matterID
        do {
            let result = try store.documentLibrary.permanentlyDeleteDocument(
                id: id,
                actor: "user"
            )
            let orphanedBlobCount = removeBlobFiles(result.removedBlobPaths)
            if orphanedBlobCount > 0 {
                deletionError = "The source was removed, but \(orphanedBlobCount) managed file(s) still need cleanup."
                recordCleanupFailure(
                    matterID: owningMatterID,
                    eventType: "document_blob_cleanup_failed",
                    relatedTable: "matter_documents",
                    relatedID: id,
                    orphanedBlobCount: orphanedBlobCount
                )
            }
        } catch {
            deletionError = "Couldn’t permanently delete the document: \(error.localizedDescription)"
        }
        reload()
    }

    public func clearDeletionError() {
        deletionError = nil
    }

    @discardableResult
    private func removeBlobFiles(_ managedPaths: [String]) -> Int {
        var orphanedBlobCount = 0
        for path in managedPaths {
            let fileURL = storage.url(forManagedRelativePath: path)
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    orphanedBlobCount += 1
                }
            }
        }
        return orphanedBlobCount
    }

    private func recordCleanupFailure(
        matterID: String?,
        eventType: String,
        relatedTable: String,
        relatedID: String,
        orphanedBlobCount: Int
    ) {
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: eventType,
            actor: "user",
            summary: "Managed blob cleanup remained incomplete after permanent deletion.",
            relatedTable: relatedTable,
            relatedID: relatedID,
            metadataJSON: "{\"orphaned_blob_count\":\(orphanedBlobCount),\"schema_version\":1}"
        )
    }
}
