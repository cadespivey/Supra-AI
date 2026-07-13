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
        public let matterName: String
        public let deletedAt: Date?
    }

    @Published public private(set) var matters: [DeletedMatter] = []
    @Published public private(set) var chats: [DeletedChat] = []
    @Published public private(set) var documents: [DeletedDocument] = []

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
        let freed = (try? store.matters.permanentlyDeleteMatter(id: id)) ?? []
        removeBlobFiles(freed)
        reload()
    }

    public func permanentlyDeleteChat(id: String) {
        try? store.chats.permanentlyDeleteChat(id: id)
        reload()
    }

    public func permanentlyDeleteDocument(id: String) {
        if let result = try? store.documentLibrary.permanentlyDeleteDocument(id: id) {
            removeBlobFiles(result.removedBlobPaths)
        }
        reload()
    }

    private func removeBlobFiles(_ managedPaths: [String]) {
        for path in managedPaths {
            try? FileManager.default.removeItem(at: storage.url(forManagedRelativePath: path))
        }
    }
}
