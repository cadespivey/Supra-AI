import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraStore
import UniformTypeIdentifiers

/// Drives a matter's Billing tab (Milestone 4 Phase 7, spec §9): the per-matter
/// override text and code set (persisted to its `MatterBillingProfileRecord`), plus
/// the client billing-guideline documents. Guideline docs are imported into the
/// matter's real document library (not a silo) and tagged "billing guideline", so
/// their extracted text reaches the draft prompt via the same retrieval path as
/// every other matter document. UI-agnostic.
@MainActor
public final class BillingProfileController: ObservableObject {
    /// The matter's free-text override layered over the global billing instructions.
    @Published public var overrideInstructions: String = ""
    /// Which UTBMS code set governs the matter's task codes.
    @Published public var codeSet: BillingCodeSet = .none
    /// Documents tagged "billing guideline" for this matter (the client's rules).
    @Published public private(set) var guidelineDocuments: [MatterDocumentRecord] = []
    @Published public var message: String?
    /// True after edits that haven't been saved yet (drives the Save button state).
    @Published public private(set) var hasUnsavedChanges = false
    /// The matter's LEDES identifiers (read-only here; edited in the matter's
    /// details), surfaced so the Billing tab shows whether export is unblocked.
    @Published public private(set) var clientID: String = ""
    @Published public private(set) var clientMatterID: String = ""
    @Published public private(set) var firmMatterID: String = ""

    /// True when the matter carries the LEDES IDs the exporter requires.
    public var ledesIdentifiersComplete: Bool { !clientID.isEmpty && !firmMatterID.isEmpty }

    public let matterID: String
    private let store: SupraStore
    private let queue: DocumentProcessingQueue?
    private let isImportReady: @MainActor () -> Bool

    private var loadedOverride: String = ""
    private var loadedCodeSet: BillingCodeSet = .none
    /// In-flight guideline imports (jobID → importBatchID). Documents created by
    /// these batches are auto-tagged "billing guideline". Keying on the import's own
    /// batch makes tagging immune to any other import (even to the same matter)
    /// landing in the queue meanwhile.
    private var pendingGuidelineJobs: [String: String] = [:]
    private var processingObserver: AnyCancellable?

    public init(
        matterID: String,
        store: SupraStore,
        queue: DocumentProcessingQueue? = nil,
        isImportReady: @escaping @MainActor () -> Bool = { true }
    ) {
        self.matterID = matterID
        self.store = store
        self.queue = queue
        self.isImportReady = isImportReady
        reload()
        observeProcessing()
    }

    public var importReady: Bool { isImportReady() }

    /// File types accepted for client billing-guideline uploads.
    public var allowedContentTypes: [UTType] { SupportedDocumentTypes.contentTypes() }

    public func reload() {
        let profile = try? store.billing.billingProfile(matterID: matterID)
        loadedOverride = profile?.overrideInstructions ?? ""
        loadedCodeSet = profile.flatMap { BillingCodeSet(rawValue: $0.billingCodeSet) } ?? .none
        overrideInstructions = loadedOverride
        codeSet = loadedCodeSet
        hasUnsavedChanges = false
        let matter = try? store.matters.fetchMatter(id: matterID)
        clientID = matter?.clientID ?? ""
        clientMatterID = matter?.clientMatterID ?? ""
        firmMatterID = matter?.internalMatterID ?? ""
        reloadGuidelineDocuments()
    }

    /// Re-reads edited fields against what's persisted to flag unsaved changes.
    public func markEdited() {
        hasUnsavedChanges = overrideInstructions != loadedOverride || codeSet != loadedCodeSet
    }

    /// Persists the override text and code set to the matter's billing profile.
    public func save() {
        let trimmed = overrideInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.billing.upsertBillingProfile(
                matterID: matterID,
                overrideInstructions: trimmed.isEmpty ? nil : trimmed,
                billingCodeSet: codeSet
            )
            loadedOverride = overrideInstructions
            loadedCodeSet = codeSet
            hasUnsavedChanges = false
            message = "Billing rules saved."
        } catch {
            message = "Couldn't save billing rules: \(error.localizedDescription)"
        }
    }

    // MARK: - Guideline documents

    /// Imports client billing-guideline documents into the matter's library and tags
    /// them "billing guideline" once the queue creates them. The import runs through
    /// the normal extract/index pipeline so the text is searchable and reaches the
    /// draft prompt.
    public func importGuidelines(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isImportReady() else {
            message = "Finish Document Intelligence setup in Settings before importing guidelines."
            return
        }
        guard let queue else {
            message = "Document import isn't available right now."
            return
        }
        guard let jobID = queue.enqueueImport(matterID: matterID, sources: urls, sourceRootDisplay: "Billing guidelines"),
              let batchID = (try? store.documentJobs.fetchJob(id: jobID))?.importBatchID else {
            message = queue.lastError.map { "Couldn't import the guideline: \($0)" }
                ?? "Couldn't start the guideline import. Please try again."
            return
        }
        pendingGuidelineJobs[jobID] = batchID
        message = nil
    }

    /// Removes a document from the guideline set by untagging it. The document stays
    /// in the matter's library (it was imported there, not into a silo).
    public func removeGuideline(documentID: String) {
        guard let tag = guidelineTag() else { return }
        try? store.documentLibrary.unassignTag(tagID: tag.id, documentID: documentID)
        reloadGuidelineDocuments()
    }

    /// Whether a guideline doc has finished extracting (its text is available to the
    /// engine). Surfaced in the UI so the attorney knows when a rule is "live".
    public func isExtracted(_ document: MatterDocumentRecord) -> Bool {
        document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
    }

    // MARK: - Helpers

    private func observeProcessing() {
        guard let queue else { return }
        processingObserver = queue.$activeJob
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcileGuidelineTags() }
    }

    /// Tags the documents created by in-flight guideline imports and drops imports
    /// whose job has finished. Idempotent and scoped to each import's own batch, so
    /// an unrelated import to the same matter is never mis-tagged. Driven by the
    /// queue observer; also callable directly (tests) once the queue is idle.
    func reconcileGuidelineTags() {
        guard !pendingGuidelineJobs.isEmpty else { return }
        tagGuidelineDocuments()
        // A guideline import is finished once its job is neither active nor queued.
        let inFlight = Set([queue?.activeJob?.id].compactMap { $0 } + (queue?.queuedJobs.map(\.id) ?? []))
        pendingGuidelineJobs = pendingGuidelineJobs.filter { inFlight.contains($0.key) }
        reloadGuidelineDocuments()
    }

    /// Assigns the guideline tag to every matter document belonging to a pending
    /// import batch. Idempotent (tag assignment ignores conflicts).
    private func tagGuidelineDocuments() {
        let batchIDs = Set(pendingGuidelineJobs.values)
        guard !batchIDs.isEmpty, let tag = ensureGuidelineTag() else { return }
        let docs = (try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []
        for doc in docs where doc.importBatchID.map(batchIDs.contains) == true {
            try? store.documentLibrary.assignTag(tagID: tag.id, documentID: doc.id)
        }
    }

    private func reloadGuidelineDocuments() {
        guard let tag = guidelineTag() else { guidelineDocuments = []; return }
        let ids = Set((try? store.documentLibrary.resolveScopeDocumentIDs(matterID: matterID, tagIDs: [tag.id])) ?? [])
        let all = (try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []
        guidelineDocuments = all.filter { ids.contains($0.id) }
    }

    private func guidelineTag() -> DocumentTagRecord? {
        (try? store.documentLibrary.fetchTags(matterID: matterID))?
            .first { $0.name.compare(BillingInstructions.guidelineTagName, options: .caseInsensitive) == .orderedSame }
    }

    /// Returns the matter's billing-guideline tag, creating it if it doesn't exist.
    private func ensureGuidelineTag() -> DocumentTagRecord? {
        if let existing = guidelineTag() { return existing }
        return try? store.documentLibrary.createTag(matterID: matterID, name: BillingInstructions.guidelineTagName)
    }
}
