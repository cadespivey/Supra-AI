import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraStore
import UniformTypeIdentifiers

/// A search hit for the Documents tab: the matched chunk plus its document name.
public struct DocumentSearchHit: Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let documentName: String
    public let excerpt: String
    public let locatorDisplay: String
}

/// Drives the per-matter Documents tab: folders, document instances, tags, import,
/// search, and trash (plan §39). Import is gated on completed Document Intelligence
/// setup and routed through the app-wide processing queue.
@MainActor
public final class MatterDocumentsController: ObservableObject {
    @Published public private(set) var folders: [DocumentFolderRecord] = []
    @Published public private(set) var documents: [MatterDocumentRecord] = []
    @Published public private(set) var trashedDocuments: [MatterDocumentRecord] = []
    @Published public private(set) var trashedFolders: [DocumentFolderRecord] = []
    @Published public private(set) var tags: [DocumentTagRecord] = []
    /// Sidebar selection. A non-optional value so the List can always select the
    /// "All Documents" row — a nil-tagged row in an Optional-bound single-selection
    /// List can't be re-selected, which is why "All Documents" appeared dead after
    /// a folder had been picked.
    @Published public var selectedSidebarID: String = MatterDocumentsController.allDocumentsTag
    @Published public var searchText: String = ""

    /// Sentinel sidebar selection meaning "show every document, no folder filter".
    public static let allDocumentsTag = "__all_documents__"

    /// The selected folder, or nil when "All Documents" is selected. Preserves the
    /// existing nil = whole-matter semantics used by scope and folder creation.
    public var selectedFolderID: String? {
        selectedSidebarID == Self.allDocumentsTag ? nil : selectedSidebarID
    }
    @Published public private(set) var searchHits: [DocumentSearchHit] = []
    @Published public var message: String?

    public let matterID: String
    private let store: SupraStore
    private let queue: DocumentProcessingQueue
    private let isImportReady: @MainActor () -> Bool
    private let storage: DocumentStorage
    private let previewLoader: DocumentPreviewLoader
    private var processingObserver: AnyCancellable?
    private var pollTimer: AnyCancellable?

    public init(
        matterID: String,
        store: SupraStore,
        queue: DocumentProcessingQueue,
        isImportReady: @escaping @MainActor () -> Bool,
        storage: DocumentStorage = .makeDefault()
    ) {
        self.matterID = matterID
        self.store = store
        self.queue = queue
        self.isImportReady = isImportReady
        self.storage = storage
        self.previewLoader = DocumentPreviewLoader(store: store, storage: storage)
        reload()
        observeProcessing()
    }

    /// Keeps the Documents tab live during background processing. The queue only
    /// publishes coarse phase transitions, and per-document status + classification
    /// are written to the store inside long-running phases — so we reload on each
    /// phase change AND poll while a job for this matter is active, so each
    /// document's status badge and classification chips appear as it completes.
    private func observeProcessing() {
        processingObserver = queue.$activeJob
            .receive(on: RunLoop.main)
            .sink { [weak self] job in
                guard let self else { return }
                self.reload()
                if job?.matterID == self.matterID {
                    self.startPolling()
                } else {
                    self.stopPolling()
                }
            }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.publish(every: 1.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Builds an in-app preview for a search hit (opens at the matched chunk).
    public func preview(chunkID: String) -> DocumentPreviewModel? {
        guard let chunk = try? store.documentIndex.fetchChunks(ids: [chunkID]).first else { return nil }
        let locator = DocumentSourceLocator(
            sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
            pageIndex: chunk.pageIndex, pageLabel: chunk.pageLabel,
            sheetName: chunk.sheetName, cellRange: chunk.cellRange,
            emailPartPath: chunk.emailPartPath, charStart: chunk.charStart, charEnd: chunk.charEnd,
            boundingBoxesJSON: chunk.boundingBoxesJSON
        )
        return previewLoader.load(documentID: chunk.documentID, locator: locator, matchText: chunk.normalizedText)
    }

    /// Builds an in-app preview opening a document at its first part.
    public func preview(documentID: String) -> DocumentPreviewModel? {
        previewLoader.loadDocument(documentID: documentID)
    }

    public var setupReady: Bool { isImportReady() }

    /// File-importer content types: every supported document type plus folders.
    public var allowedContentTypes: [UTType] {
        SupportedDocumentTypes.contentTypes() + [.folder]
    }

    /// The processing job currently running for this matter, if any.
    public var activeJob: DocumentProcessingJobRecord? {
        guard let job = queue.activeJob, job.matterID == matterID else { return nil }
        return job
    }

    public func reload() {
        folders = (try? store.documentLibrary.fetchFolders(matterID: matterID)) ?? []
        documents = (try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []
        trashedDocuments = (try? store.documentLibrary.fetchSoftDeletedDocuments(matterID: matterID)) ?? []
        trashedFolders = ((try? store.documentLibrary.fetchFolders(matterID: matterID, includeDeleted: true)) ?? []).filter { $0.deletedAt != nil }
        tags = (try? store.documentLibrary.fetchTags(matterID: matterID)) ?? []
    }

    /// Documents for the current sidebar selection: every document for
    /// "All Documents", otherwise just the selected folder's documents.
    public var visibleDocuments: [MatterDocumentRecord] {
        let roots = documents.filter { $0.parentDocumentID == nil }
        guard selectedSidebarID != Self.allDocumentsTag else { return roots }
        return roots.filter { $0.folderID == selectedSidebarID }
    }

    public func childAttachments(of documentID: String) -> [MatterDocumentRecord] {
        documents.filter { $0.parentDocumentID == documentID }
    }

    public func subfolders(of parentID: String?) -> [DocumentFolderRecord] {
        folders.filter { $0.parentFolderID == parentID }
    }

    // MARK: - Import

    /// The auto-created destination folder for research imported from Authorities.
    public static let researchFolderName = "Research"

    /// Imports dropped/picked files and folders, if setup is complete. Pass a
    /// `targetFolderID` to file the imports into a specific folder (nil = root).
    public func importItems(_ urls: [URL], targetFolderID: String? = nil) {
        guard isImportReady() else {
            message = "Finish Document Intelligence setup in Settings before importing."
            return
        }
        guard !urls.isEmpty else { return }
        let display = urls.first?.deletingLastPathComponent().lastPathComponent
        if queue.enqueueImport(matterID: matterID, sources: urls, sourceRootDisplay: display, targetFolderID: targetFolderID) == nil {
            // Enqueue failed (e.g. the batch/job could not be written) — surface it
            // instead of silently dropping the user's import.
            message = queue.lastError.map { "Couldn't start the import: \($0)" }
                ?? "Couldn't start the document import. Please try again."
        } else {
            message = nil
        }
    }

    /// Imports research uploaded from the Authorities tab into a dedicated
    /// "Research" folder (created if needed) so it's grouped rather than dropped
    /// into All Documents.
    public func importResearchDocuments(_ urls: [URL]) {
        guard isImportReady() else {
            message = "Finish Document Intelligence setup in Settings before importing."
            return
        }
        importItems(urls, targetFolderID: ensureResearchFolderID())
    }

    /// The id of the matter's top-level "Research" folder, creating it if absent.
    @discardableResult
    public func ensureResearchFolderID() -> String? {
        if let existing = folders.first(where: { $0.parentFolderID == nil && $0.name == Self.researchFolderName }) {
            return existing.id
        }
        let created = try? store.documentLibrary.createFolder(matterID: matterID, name: Self.researchFolderName)
        reload()
        return created?.id
    }

    // MARK: - Folders

    public func createFolder(name: String, parentFolderID: String?) {
        do {
            _ = try store.documentLibrary.createFolder(matterID: matterID, name: name, parentFolderID: parentFolderID)
            reload()
        } catch { message = error.localizedDescription }
    }

    public func renameFolder(id: String, name: String) {
        try? store.documentLibrary.renameFolder(id: id, name: name)
        reload()
    }

    public func deleteFolder(id: String) {
        try? store.documentLibrary.softDeleteFolder(id: id)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "folder_soft_deleted", actor: "user",
            summary: "Moved a folder and its documents to trash",
            relatedTable: "document_folders", relatedID: id
        )
        if selectedSidebarID == id { selectedSidebarID = Self.allDocumentsTag }
        reload()
    }

    public func restoreFolder(id: String) {
        try? store.documentLibrary.restoreFolder(id: id)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "folder_restored", actor: "user",
            summary: "Restored a folder and its documents from trash",
            relatedTable: "document_folders", relatedID: id
        )
        reload()
    }

    public func moveDocument(id: String, toFolderID: String?) {
        try? store.documentLibrary.moveDocument(id: id, toFolderID: toFolderID)
        reload()
    }

    // MARK: - Tags

    public func createTag(name: String) {
        do {
            _ = try store.documentLibrary.createTag(matterID: matterID, name: name)
            reload()
        } catch { message = error.localizedDescription }
    }

    public func tags(forDocument documentID: String) -> [DocumentTagRecord] {
        (try? store.documentLibrary.fetchTags(documentID: documentID)) ?? []
    }

    /// The classifier's suggested categorization for a document, if it has been
    /// classified (1.3.2). Decoded from the stored classification metadata.
    public func classification(forDocument documentID: String) -> DocumentClassification? {
        guard let json = documents.first(where: { $0.id == documentID })?.classificationMetadataJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentClassification.self, from: data)
    }

    public func toggleTag(_ tagID: String, on documentID: String) {
        let assigned = tags(forDocument: documentID).contains { $0.id == tagID }
        if assigned {
            try? store.documentLibrary.unassignTag(tagID: tagID, documentID: documentID)
        } else {
            try? store.documentLibrary.assignTag(tagID: tagID, documentID: documentID)
        }
        objectWillChange.send()
    }

    // MARK: - Trash

    public func softDelete(documentID: String) {
        try? store.documentLibrary.softDeleteDocument(id: documentID)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "document_soft_deleted", actor: "user",
            summary: "Moved a document to trash", relatedTable: "matter_documents", relatedID: documentID
        )
        reload()
    }

    public func restore(documentID: String) {
        try? store.documentLibrary.restoreDocument(id: documentID)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "document_restored", actor: "user",
            summary: "Restored a document from trash", relatedTable: "matter_documents", relatedID: documentID
        )
        reload()
    }

    public func permanentlyDelete(documentID: String) {
        var orphanedBlobCount = 0
        if let result = try? store.documentLibrary.permanentlyDeleteDocument(id: documentID) {
            for path in result.removedBlobPaths {
                let fileURL = storage.url(forManagedRelativePath: path)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    // The DB rows (document + blob) are already gone inside the repo's
                    // transaction. If the file is still on disk we've orphaned a blob —
                    // count it for the audit trail rather than losing the signal. Never
                    // fail the delete over a stuck file.
                    if FileManager.default.fileExists(atPath: fileURL.path) { orphanedBlobCount += 1 }
                }
            }
        }
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "document_permanently_deleted", actor: "user",
            summary: orphanedBlobCount == 0
                ? "Permanently deleted a document"
                : "Permanently deleted a document; \(orphanedBlobCount) blob file(s) could not be removed and were left for cleanup",
            relatedTable: "matter_documents", relatedID: documentID
        )
        reload()
    }

    // MARK: - Search

    public func runSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { searchHits = []; return }
        let chunks: [DocumentChunkRecord]
        do {
            chunks = try store.documentIndex.searchChunks(matterID: matterID, query: trimmed, limit: 40)
        } catch {
            // Distinguish a failed search from a genuinely empty one, so the user isn't
            // shown "no results" when the index actually errored.
            searchHits = []
            message = "Search failed: \(error.localizedDescription)"
            return
        }
        let nameByID = Dictionary(documents.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var seenText = Set<String>()
        searchHits = chunks.compactMap { chunk in
            // Collapse duplicate content across instances by default (plan §4.5).
            let key = chunk.normalizedText
            guard seenText.insert(key).inserted else { return nil }
            let locator = DocumentSourceLocator(
                sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
                pageIndex: chunk.pageIndex, pageLabel: chunk.pageLabel,
                sheetName: chunk.sheetName, cellRange: chunk.cellRange,
                emailPartPath: chunk.emailPartPath, charStart: chunk.charStart, charEnd: chunk.charEnd
            )
            return DocumentSearchHit(
                id: chunk.id,
                documentID: chunk.documentID,
                documentName: nameByID[chunk.documentID] ?? "Document",
                excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                locatorDisplay: locator.displayString
            )
        }
    }
}
