import Darwin
import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Per-file outcome line in an import report (plan §5.1). Every discovered file
/// and attachment is accounted for.
public struct DocumentImportReportItem: Codable, Sendable {
    public var displayName: String
    public var sourceDisplayPath: String
    public var disposition: String
    public var reason: String?
    public var documentID: String?
    public var parentDocumentID: String?
    /// Stable machine-readable reason when policy rejected this item.
    public var rejectionCode: String? = nil
}

/// Deterministic fault-injection and audit boundaries for pinned-root traversal.
public enum ImportTraversalStage: String, Sendable {
    case afterRootPinned = "after_root_pinned"
    case beforeCandidateRead = "before_candidate_read"
    case afterCandidateValidated = "after_candidate_validated"
}

public typealias ImportTraversalFaultInjector = @Sendable (ImportTraversalStage, URL) throws -> Void
public typealias ImportSourceStateObserver = @Sendable (DocumentImportSourceRecord) throws -> Void

/// The final import report stored on the batch (plan §5.1).
public struct DocumentImportReport: Codable, Sendable {
    public var items: [DocumentImportReportItem]
    public var counts: [String: Int]

    public init(items: [DocumentImportReportItem] = [], counts: [String: Int] = [:]) {
        self.items = items
        self.counts = counts
    }

    public var discoveredCount: Int { items.count }
    public var importedCount: Int {
        items.filter {
            $0.disposition == DocumentImportDisposition.imported.rawValue
                || $0.disposition == DocumentImportDisposition.duplicateBlobReused.rawValue
                || $0.disposition == DocumentImportSourceState.admitted.rawValue
        }.count
    }
    public var failedCount: Int {
        items.filter {
            $0.disposition == DocumentImportDisposition.extractionFailed.rawValue
                || $0.disposition == DocumentImportDisposition.unsupported.rawValue
                || $0.disposition == DocumentImportDisposition.ocrFailed.rawValue
                || $0.disposition == DocumentImportSourceState.rejected.rawValue
                || $0.disposition == DocumentImportSourceState.unsupportedByPolicy.rawValue
                || $0.disposition == DocumentImportSourceState.failed.rawValue
                || $0.disposition == DocumentImportSourceState.cancelled.rawValue
                || $0.disposition == DocumentImportSourceState.interrupted.rawValue
        }.count
    }
}

/// Imports files and folders into a matter: copies each into content-addressed
/// managed storage, preserves folder hierarchy, deduplicates blobs, expands
/// email attachments as child documents, extracts text, and produces an import
/// report (plan §4–§5). Originals are never modified.
///
/// OCR runs inline during `importFile` (via `applyOCR`) for files that lack
/// embedded text; a document keeps `needs_ocr` status only when the service is
/// constructed without an OCR service.
public final class DocumentImportService: @unchecked Sendable {
    private let store: SupraStore
    private let storage: DocumentStorage
    private let extraction: ExtractionService
    private let importPolicy: ImportPolicy
    private let ocr: (any DocumentOCRService)?
    private let traversalFaultInjector: ImportTraversalFaultInjector
    private let sourceStateObserver: ImportSourceStateObserver
    @MainActor private var reindexEnqueuer: (@MainActor @Sendable (String) -> Void)?

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        extraction: ExtractionService? = nil,
        importPolicy: ImportPolicy = .default,
        ocr: (any DocumentOCRService)? = VisionOCRService(),
        traversalFaultInjector: @escaping ImportTraversalFaultInjector = { _, _ in },
        sourceStateObserver: @escaping ImportSourceStateObserver = { _ in }
    ) {
        self.store = store
        self.storage = storage
        self.extraction = extraction ?? ExtractionService(policy: importPolicy)
        self.importPolicy = importPolicy
        self.ocr = ocr
        self.traversalFaultInjector = traversalFaultInjector
        self.sourceStateObserver = sourceStateObserver
    }

    public struct ImportOutcome: Sendable {
        public let batchID: String
        public let report: DocumentImportReport
    }

    /// Imports the given source URLs (files and/or directories) into a matter.
    /// `targetFolderID` is the destination for top-level items; nested folders are
    /// recreated under it.
    @discardableResult
    public func importSources(
        _ sources: [URL],
        matterID: String,
        targetFolderID: String? = nil,
        batchID: String? = nil
    ) async throws -> ImportOutcome {
        try storage.initializeStorage()
        let batch = try resolveBatch(
            matterID: matterID,
            batchID: batchID,
            sources: sources,
            targetFolderID: targetFolderID
        )

        var report = DocumentImportReport()
        var folderCache: [String: String?] = [:]  // managed relative dir path -> folder id
        let ledger = ImportBudgetLedger(policy: importPolicy)

        for (selectionIndex, source) in sources.enumerated() {
            // User-picked / dropped files are security-scoped under the App
            // Sandbox. Imports run asynchronously on the processing queue — long
            // after the picker callback — so we must (re)open scope here or every
            // read fails. App-owned/temp URLs return false and need no scope.
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let bookmarkOptions: URL.BookmarkCreationOptions = scoped
                ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                : []
            let bookmark = try? source.bookmarkData(
                options: bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let sourceKey = "selection:\(selectionIndex)"
            let sourceRow = try recordSource(
                batchID: batch.id,
                matterID: matterID,
                sourceKey: sourceKey,
                sourceDisplayPath: source.lastPathComponent,
                sourceBookmark: bookmark,
                state: .selected
            )
            do {
                let root = try PinnedImportRoot(url: source)
                try traversalFaultInjector(.afterRootPinned, source)
                try root.verifyUnchanged()
                var visited = Set<FileIdentity>()
                try await importEntry(
                    at: source,
                    relativePath: source.lastPathComponent,
                    depth: 0,
                    root: root,
                    ledger: ledger,
                    visited: &visited,
                    matterID: matterID,
                    batchID: batch.id,
                    sourceID: sourceRow.id,
                    sourceKey: sourceKey,
                    currentFolderID: targetFolderID,
                    rootFolderID: targetFolderID,
                    folderCache: &folderCache,
                    report: &report
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let violation as ImportPolicyViolation {
                try recordPolicyRejection(
                    violation,
                    url: source,
                    sourceDisplayPath: source.lastPathComponent,
                    sourceID: sourceRow.id,
                    report: &report
                )
            } catch {
                try recordFailure(
                    error,
                    displayName: source.lastPathComponent,
                    sourceDisplayPath: source.lastPathComponent,
                    sourceID: sourceRow.id,
                    report: &report
                )
            }
        }

        report.counts = Self.tallyCounts(report.items)
        let status: DocumentImportBatchStatus = report.failedCount > 0 ? .completeWithFailures : .complete
        let reportJSON = (try? JSONEncoder().encode(report)).flatMap { String(data: $0, encoding: .utf8) }
        try store.documentJobs.updateBatchProgress(
            id: batch.id,
            discoveredCount: report.discoveredCount,
            importedCount: report.importedCount,
            failedCount: report.failedCount
        )
        try store.documentJobs.finalizeBatch(id: batch.id, status: status, reportJSON: reportJSON)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: report.failedCount > 0 ? "document_import_completed_with_failures" : "document_import_completed",
            actor: "system",
            summary: "Imported \(report.importedCount)/\(report.discoveredCount) files",
            relatedTable: "document_import_batches",
            relatedID: batch.id
        )
        return ImportOutcome(batchID: batch.id, report: report)
    }

    /// Resumes a post-v059 batch exclusively from its persisted source ledger.
    /// Already-terminal rows are skipped; top-level interrupted rows reopen their
    /// bookmarks and re-enter at copying. A missing target or authorization is a
    /// per-source terminal failure, never a silent fallback to the matter root.
    @discardableResult
    public func resumeBatch(batchID: String, matterID: String) async throws -> ImportOutcome {
        try storage.initializeStorage()
        guard let batch = try store.documentJobs.fetchBatch(id: batchID), batch.matterID == matterID else {
            throw DocumentJobRepositoryError.batchMatterMismatch(batchID: batchID, matterID: matterID)
        }
        let initialRows = try store.documentJobs.fetchSources(batchID: batchID)
        guard !initialRows.isEmpty else {
            return ImportOutcome(batchID: batchID, report: DocumentImportReport())
        }

        let unfinished = initialRows.filter { !$0.isTerminal }
        let targetFolderID: String?
        if batch.targetFolderRequested {
            if let requestedID = batch.targetFolderID,
               let folder = try store.documentLibrary.fetchFolder(id: requestedID),
               folder.matterID == matterID,
               folder.deletedAt == nil {
                targetFolderID = requestedID
            } else {
                for source in unfinished {
                    try transitionSource(source.id, to: .failed, reason: "target_folder_unavailable")
                }
                return try finalizeLedgerBatch(batchID: batchID, matterID: matterID)
            }
        } else {
            targetFolderID = nil
        }

        var folderCache: [String: String?] = [:]
        let ledger = ImportBudgetLedger(policy: importPolicy)
        var compatibilityReport = DocumentImportReport()
        for source in unfinished where source.parentSourceID == nil {
            guard let url = Self.resolveSourceBookmark(source.sourceBookmark) else {
                try transitionSource(source.id, to: .failed, reason: "bookmark_unresolvable")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try transitionSource(source.id, to: .copying)
                let root = try PinnedImportRoot(url: url)
                try traversalFaultInjector(.afterRootPinned, url)
                try root.verifyUnchanged()
                var visited = Set<FileIdentity>()
                try await importEntry(
                    at: url,
                    relativePath: source.sourceDisplayPath,
                    depth: 0,
                    root: root,
                    ledger: ledger,
                    visited: &visited,
                    matterID: matterID,
                    batchID: batchID,
                    sourceID: source.id,
                    sourceKey: source.sourceKey,
                    currentFolderID: targetFolderID,
                    rootFolderID: targetFolderID,
                    folderCache: &folderCache,
                    report: &compatibilityReport,
                    sourceAlreadyCopying: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let violation as ImportPolicyViolation {
                try recordPolicyRejection(
                    violation,
                    url: url,
                    sourceDisplayPath: source.sourceDisplayPath,
                    sourceID: source.id,
                    report: &compatibilityReport
                )
            } catch {
                try recordFailure(
                    error,
                    displayName: url.lastPathComponent,
                    sourceDisplayPath: source.sourceDisplayPath,
                    sourceID: source.id,
                    report: &compatibilityReport
                )
            }
        }

        // Any nonterminal child that could not be rediscovered from its selected
        // root must be explicit rather than silently omitted from final accounting.
        for source in try store.documentJobs.unfinishedSources(batchID: batchID) {
            try transitionSource(source.id, to: .failed, reason: "bookmark_unresolvable")
        }
        return try finalizeLedgerBatch(batchID: batchID, matterID: matterID)
    }

    /// Finalizes a paused import after the user chooses Discard. Succeeded rows
    /// remain untouched; every re-entrant row becomes cancelled and releases its
    /// bookmark in the same transaction as its state transition.
    @discardableResult
    public func discardBatch(batchID: String, matterID: String) throws -> DocumentImportReport {
        guard let batch = try store.documentJobs.fetchBatch(id: batchID), batch.matterID == matterID else {
            throw DocumentJobRepositoryError.batchMatterMismatch(batchID: batchID, matterID: matterID)
        }
        for source in try store.documentJobs.unfinishedSources(batchID: batchID) {
            try transitionSource(source.id, to: .cancelled, reason: "Import discarded by user.")
        }
        let report = try ledgerReport(batchID: batchID)
        try store.documentJobs.updateBatchProgress(
            id: batchID,
            discoveredCount: report.discoveredCount,
            importedCount: report.importedCount,
            failedCount: report.failedCount
        )
        let reportJSON = try JSONEncoder.encodeToString(report)
        try store.documentJobs.finalizeBatch(id: batchID, status: .cancelled, reportJSON: reportJSON)
        return report
    }

    // MARK: - Discovery / recursion

    private func importEntry(
        at url: URL,
        relativePath: String,
        depth: Int,
        root: PinnedImportRoot,
        ledger: ImportBudgetLedger,
        visited: inout Set<FileIdentity>,
        matterID: String,
        batchID: String,
        sourceID: String,
        sourceKey: String,
        currentFolderID: String?,
        rootFolderID: String?,
        folderCache: inout [String: String?],
        report: inout DocumentImportReport,
        sourceAlreadyCopying: Bool = false
    ) async throws {
        try Task.checkCancellation()
        guard depth <= importPolicy.maxTreeDepth else {
            throw ImportPolicyViolation(
                .treeDepth,
                "Path exceeds the \(importPolicy.maxTreeDepth)-level tree-depth limit."
            )
        }
        try traversalFaultInjector(.beforeCandidateRead, url)
        let metadata = try root.validateCandidate(url)
        if metadata.isRegularFile, metadata.linkCount > 1 {
            throw ImportPolicyViolation(.hardLink, "Hard-linked files have ambiguous identity and are not imported.")
        }
        guard visited.insert(metadata.identity).inserted else {
            throw ImportPolicyViolation(.duplicateFileIdentity, "A filesystem object was encountered more than once.")
        }

        if metadata.isDirectory {
            if !sourceAlreadyCopying {
                try transitionSource(sourceID, to: .validated)
                try transitionSource(sourceID, to: .copying)
            }
            let folderID = try folder(
                forRelativeDir: relativePath,
                matterID: matterID,
                rootFolderID: rootFolderID,
                folderCache: &folderCache
            )
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isAliasFileKey,
                    .isHiddenKey,
                    .isSymbolicLinkKey,
                    .fileResourceIdentifierKey,
                ],
                options: []
            )
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let childPath = "\(relativePath)/\(child.lastPathComponent)"
                let childKey = "\(sourceKey)/\(child.lastPathComponent)"
                let childRow = try recordSource(
                    batchID: batchID,
                    matterID: matterID,
                    sourceKey: childKey,
                    sourceDisplayPath: childPath,
                    parentSourceID: sourceID
                )
                if childRow.isTerminal { continue }
                let isHidden = child.lastPathComponent.hasPrefix(".")
                    || (try? child.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
                if isHidden {
                    try transitionSource(
                        childRow.id,
                        to: .excludedHidden,
                        reason: "Hidden import source excluded by policy."
                    )
                    continue
                }
                do {
                    let childAlreadyCopying = childRow.sourceState == .interrupted
                        || childRow.sourceState == .copying
                    if childRow.sourceState == .interrupted {
                        try transitionSource(childRow.id, to: .copying)
                    }
                    try await importEntry(
                        at: child,
                        relativePath: childPath,
                        depth: depth + 1,
                        root: root,
                        ledger: ledger,
                        visited: &visited,
                        matterID: matterID,
                        batchID: batchID,
                        sourceID: childRow.id,
                        sourceKey: childKey,
                        currentFolderID: folderID,
                        rootFolderID: rootFolderID,
                        folderCache: &folderCache,
                        report: &report,
                        sourceAlreadyCopying: childAlreadyCopying
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let violation as ImportPolicyViolation {
                    try recordPolicyRejection(
                        violation,
                        url: child,
                        sourceDisplayPath: childPath,
                        sourceID: childRow.id,
                        report: &report
                    )
                } catch {
                    try recordFailure(
                        error,
                        displayName: child.lastPathComponent,
                        sourceDisplayPath: childPath,
                        sourceID: childRow.id,
                        report: &report
                    )
                }
            }
            try transitionSource(sourceID, to: .containerCompleted)
            return
        }

        guard metadata.isRegularFile else {
            throw ImportPolicyViolation(.duplicateFileIdentity, "Only regular files and directories may be imported.")
        }
        try importPolicy.validateSource(at: url)
        try ledger.consumeSource(byteSize: metadata.byteSize)
        try traversalFaultInjector(.afterCandidateValidated, url)
        if !sourceAlreadyCopying {
            try transitionSource(sourceID, to: .validated)
            try transitionSource(sourceID, to: .copying)
        }
        _ = try await importFile(
            at: url,
            folderID: currentFolderID,
            sourceDisplayPath: relativePath,
            matterID: matterID,
            batchID: batchID,
            sourceID: sourceID,
            sourceKey: sourceKey,
            pinnedSourceValidator: {
                let current = try root.validateCandidate(url)
                guard current.identity == metadata.identity,
                      current.isRegularFile,
                      current.linkCount == metadata.linkCount else {
                    throw ImportPolicyViolation(
                        .candidateChanged,
                        "The import item changed after it was discovered."
                    )
                }
            },
            ledger: ledger,
            report: &report
        )
    }

    // MARK: - Single file import

    @discardableResult
    private func importFile(
        at url: URL,
        folderID: String?,
        sourceDisplayPath: String,
        matterID: String,
        batchID: String,
        sourceID: String,
        sourceKey: String,
        parentDocumentID: String? = nil,
        attachmentDepth: Int = 0,
        pinnedSourceValidator: (@Sendable () throws -> Void)? = nil,
        ledger: ImportBudgetLedger,
        report: inout DocumentImportReport
    ) async throws -> String? {
        let displayName = url.lastPathComponent
        let format = SupportedDocumentTypes.format(for: url)

        do {
            try pinnedSourceValidator?()
            if let reason = SupportedDocumentTypes.unsupportedByPolicyReason(for: url) {
                try recordUnsupportedByPolicy(
                    reason: reason,
                    displayName: displayName,
                    sourceDisplayPath: sourceDisplayPath,
                    sourceID: sourceID,
                    parentDocumentID: parentDocumentID,
                    report: &report
                )
                return nil
            }
            if let format {
                _ = try DocumentTypeDetector.validate(fileURL: url, expected: format, policy: importPolicy)
            }
            try pinnedSourceValidator?()
        } catch let violation as ImportPolicyViolation {
            try recordPolicyRejection(
                violation,
                url: url,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceID,
                parentDocumentID: parentDocumentID,
                report: &report
            )
            return nil
        } catch {
            try recordFailure(
                error,
                displayName: displayName,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceID,
                parentDocumentID: parentDocumentID,
                report: &report
            )
            return nil
        }

        // Unknown formats retain the legacy managed-instance behavior. Explicit
        // policy formats (.xls/.msg) returned above before blob installation.
        let managedBlob: ManagedImportedBlob
        do {
            managedBlob = try ingestBlob(at: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try recordFailure(
                error,
                displayName: displayName,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceID,
                parentDocumentID: parentDocumentID,
                report: &report
            )
            return nil
        }
        let blob = managedBlob.record

        let document = MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            parentDocumentID: parentDocumentID,
            folderID: folderID,
            importBatchID: batchID,
            displayName: displayName,
            sourceDisplayPath: sourceDisplayPath,
            sourceKind: format?.sourceKind.rawValue
        )

        guard format != nil else {
            var unsupported = document
            unsupported.status = MatterDocumentStatus.failed.rawValue
            unsupported.extractionStatus = DocumentExtractionStatus.failed.rawValue
            unsupported.extractionErrorsJSON = try? JSONEncoder.encodeToString(["Unsupported file type."])
            try store.documentLibrary.insertDocument(unsupported)
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: DocumentImportDisposition.unsupported.rawValue,
                reason: "Unsupported file type.", documentID: unsupported.id, parentDocumentID: parentDocumentID
            ))
            try transitionSource(
                sourceID,
                to: .unsupportedByPolicy,
                reason: "Unsupported file type.",
                documentID: unsupported.id,
                blobSHA256: blob.sha256
            )
            return unsupported.id
        }

        try store.documentLibrary.insertDocument(document)

        // Extract, then OCR if needed.
        do {
            var result = try await extraction.extract(fileURL: managedBlob.verifiedURL)
            var ocrApplied = false
            if result.needsOCR, ocr != nil, let format {
                do {
                    result = try await applyOCR(to: result, blobURL: managedBlob.verifiedURL, family: format.family)
                    ocrApplied = true
                    _ = try? store.auditEvents.recordEvent(
                        matterID: matterID, eventType: "document_ocr_completed", actor: "system",
                        summary: "OCR completed for \(displayName)", relatedTable: "matter_documents", relatedID: document.id
                    )
                } catch {
                    _ = try? store.auditEvents.recordEvent(
                        matterID: matterID, eventType: "document_ocr_failed", actor: "system",
                        summary: "OCR failed for \(displayName)", relatedTable: "matter_documents", relatedID: document.id
                    )
                    throw error
                }
            }
            try ledger.consumeDecoded(result)
            try persistExtraction(result, documentID: document.id, ocrApplied: ocrApplied)
            let disposition: DocumentImportDisposition
            if result.needsOCR {
                disposition = .ocrNeeded
            } else if managedBlob.reused {
                disposition = .duplicateBlobReused
            } else {
                disposition = .imported
            }
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: disposition.rawValue,
                documentID: document.id, parentDocumentID: parentDocumentID
            ))
            // Expand email attachments as child documents.
            for (attachmentIndex, attachment) in result.attachments.enumerated() {
                try await importAttachment(
                    attachment,
                    parentDocument: document,
                    parentSourceID: sourceID,
                    sourceKey: "\(sourceKey)/attachment:\(attachmentIndex)",
                    folderID: folderID,
                    matterID: matterID,
                    batchID: batchID,
                    attachmentDepth: attachmentDepth + 1,
                    ledger: ledger,
                    report: &report
                )
            }
            try transitionSource(
                sourceID,
                to: .admitted,
                documentID: document.id,
                blobSHA256: blob.sha256
            )
        } catch is CancellationError {
            rollbackRejectedDocument(document.id)
            throw CancellationError()
        } catch let violation as ImportPolicyViolation {
            rollbackRejectedDocument(document.id)
            try recordPolicyRejection(
                violation,
                url: url,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceID,
                parentDocumentID: parentDocumentID,
                report: &report
            )
            return nil
        } catch let error as ExtractionError {
            if case .policyViolation(let violation) = error {
                rollbackRejectedDocument(document.id)
                try recordPolicyRejection(
                    violation,
                    url: url,
                    sourceDisplayPath: sourceDisplayPath,
                    sourceID: sourceID,
                    parentDocumentID: parentDocumentID,
                    report: &report
                )
                return nil
            }
            try store.documentLibrary.updateStatus(documentID: document.id, status: .failed)
            try? markExtractionFailed(documentID: document.id, error: error)
            let disposition: DocumentImportDisposition = {
                if case .unsupportedFormat = error { return .unsupported }
                return .extractionFailed
            }()
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: disposition.rawValue,
                reason: error.localizedDescription, documentID: document.id, parentDocumentID: parentDocumentID
            ))
            try transitionSource(
                sourceID,
                to: disposition == .unsupported ? .unsupportedByPolicy : .failed,
                reason: error.localizedDescription,
                documentID: document.id,
                blobSHA256: blob.sha256
            )
        } catch {
            try store.documentLibrary.updateStatus(documentID: document.id, status: .failed)
            try? markExtractionFailed(documentID: document.id, error: error)
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: DocumentImportDisposition.extractionFailed.rawValue,
                reason: error.localizedDescription, documentID: document.id, parentDocumentID: parentDocumentID
            ))
            try transitionSource(
                sourceID,
                to: .failed,
                reason: error.localizedDescription,
                documentID: document.id,
                blobSHA256: blob.sha256
            )
        }
        return document.id
    }

    /// Reduces an attachment filename to a safe bare component (no separators or
    /// traversal), falling back to a unique name. Mirrors the extractor-boundary
    /// sanitization so any attachment source is safe at the write sink.
    private static func safeAttachmentFileName(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." || last.contains("/") || last.contains("\\") {
            return "attachment-\(UUID().uuidString)"
        }
        return last
    }

    private func importAttachment(
        _ attachment: ExtractedAttachment,
        parentDocument: MatterDocumentRecord,
        parentSourceID: String,
        sourceKey: String,
        folderID: String?,
        matterID: String,
        batchID: String,
        attachmentDepth: Int,
        ledger: ImportBudgetLedger,
        report: inout DocumentImportReport
    ) async throws {
        let sourceDisplayPath = "\(parentDocument.sourceDisplayPath ?? parentDocument.displayName) ▸ \(attachment.fileName)"
        let sourceRow = try recordSource(
            batchID: batchID,
            matterID: matterID,
            sourceKey: sourceKey,
            sourceDisplayPath: sourceDisplayPath,
            parentSourceID: parentSourceID
        )
        do {
            try ledger.consumeAttachment(byteSize: attachment.data.count, depth: attachmentDepth)
        } catch let violation as ImportPolicyViolation {
            try recordPolicyRejection(
                violation,
                displayName: attachment.fileName,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceRow.id,
                parentDocumentID: parentDocument.id,
                report: &report
            )
            return
        }
        try transitionSource(sourceRow.id, to: .validated)
        try transitionSource(sourceRow.id, to: .copying)
        // Write the attachment bytes to a unique temp directory keeping the
        // original filename, so the path-based import pipeline (copy/dedup/extract)
        // handles it and the child document keeps the attachment's display name.
        let tempDir = storage.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Defense-in-depth against path traversal: the attachment name is reduced
        // to a bare component, and we verify the resolved write path stays inside
        // tempDir before writing.
        let safeName = Self.safeAttachmentFileName(attachment.fileName)
        let tempURL = tempDir.appendingPathComponent(safeName)
        let containedDir = tempDir.resolvingSymlinksInPath().path
        guard tempURL.resolvingSymlinksInPath().path.hasPrefix(containedDir + "/") else {
            try recordPolicyRejection(
                ImportPolicyViolation(.unsafeArchivePath, "Rejected an attachment with an unsafe filename."),
                displayName: attachment.fileName,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceRow.id,
                parentDocumentID: parentDocument.id,
                report: &report
            )
            return
        }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try attachment.data.write(to: tempURL)
        } catch {
            try recordFailure(
                error,
                displayName: attachment.fileName,
                sourceDisplayPath: sourceDisplayPath,
                sourceID: sourceRow.id,
                parentDocumentID: parentDocument.id,
                reason: "Could not write attachment.",
                report: &report
            )
            return
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A failed attachment must not fail the parent email (plan §3.2).
        _ = try await importFile(
            at: tempURL,
            folderID: folderID,
            sourceDisplayPath: sourceDisplayPath,
            matterID: matterID,
            batchID: batchID,
            sourceID: sourceRow.id,
            sourceKey: sourceKey,
            parentDocumentID: parentDocument.id,
            attachmentDepth: attachmentDepth,
            ledger: ledger,
            report: &report
        )
    }

    private func rollbackRejectedDocument(_ documentID: String) {
        guard let result = try? store.documentLibrary.permanentlyDeleteDocument(id: documentID) else { return }
        for relativePath in result.removedBlobPaths {
            try? FileManager.default.removeItem(at: storage.url(forManagedRelativePath: relativePath))
        }
    }

    // MARK: - Editable extracted text

    /// Connects saved text corrections to the app-wide FIFO queue. This is
    /// composed after queue construction to avoid a service/queue init cycle.
    @MainActor
    public func setReindexEnqueuer(
        _ enqueuer: @escaping @MainActor @Sendable (String) -> Void
    ) {
        reindexEnqueuer = enqueuer
    }

    /// Applies a user edit to one extracted part's text and marks the document
    /// edited + index-stale so a later indexing pass re-chunks/re-embeds it
    /// (plan §6.2). The OCR/extraction text is the editable source of truth.
    @MainActor
    public func updateExtractedText(documentID: String, partID: String, text: String) throws {
        let matterID = try store.documentLibrary.fetchDocument(id: documentID)?.matterID
        try store.documentIndex.updatePartText(partID: partID, text: TextNormalization.normalize(text))
        try store.documentLibrary.markTextEdited(documentID: documentID)
        if let matterID { reindexEnqueuer?(matterID) }
    }

    // MARK: - Reprocess (re-extract from the managed blob)

    /// A reprocess precondition that cannot be recovered per-document.
    public enum ReprocessError: Error, LocalizedError, Equatable, Sendable {
        case documentNotFound(String)
        case blobNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .documentNotFound(let id): "The document \(id) no longer exists."
            case .blobNotFound(let id): "The managed file for blob \(id) could not be found."
            }
        }
    }

    /// Re-extracts a single already-imported document from its verified managed blob,
    /// as a targeted retry for a failed/stale document. Clears the prior classification
    /// up front (the content is about to be re-derived), re-runs extraction (and OCR if
    /// the format needs it), repopulates the parts, and marks the index stale so a later
    /// indexing pass re-chunks/re-embeds it. A re-extraction that fails again re-marks the
    /// instance `.failed` cleanly and leaves no partial parts — it does NOT throw, so the
    /// queue's per-document loop and a direct caller both treat a re-mark as a normal
    /// outcome. Only unrecoverable preconditions (missing document/blob, a managed-blob
    /// integrity failure) throw.
    ///
    /// The managed bytes were already vetted against the full import policy when first
    /// admitted, so this does NOT re-consume the per-import budget ledger; the extractor
    /// still enforces the per-file source/parser/result limits internally.
    public func reprocessDocument(documentID: String) async throws {
        guard let document = try store.documentLibrary.fetchDocument(id: documentID) else {
            throw ReprocessError.documentNotFound(documentID)
        }
        guard let blob = try store.documentLibrary.fetchBlob(id: document.blobID) else {
            throw ReprocessError.blobNotFound(document.blobID)
        }
        // Verify the managed bytes against the recorded digest/size before re-reading
        // them (mirrors importFile's verified-bytes use). An integrity failure is
        // unrecoverable here and propagates.
        let verifiedURL = try storage.verifyManagedBlob(
            relativePath: blob.managedRelativePath,
            expectedSHA256: blob.sha256,
            expectedByteSize: blob.byteSize
        )

        // Clear any stale classification FIRST, unconditionally, before re-extraction —
        // the old category no longer applies until the document is re-classified. This
        // is the observable proof that reprocess ran even when the re-extraction fails.
        try store.documentLibrary.updateClassification(documentID: documentID, classificationMetadataJSON: nil)

        guard let format = SupportedDocumentTypes.format(for: verifiedURL) else {
            // No supported extractor — re-mark failed cleanly with no leaked parts
            // (mirrors importFile's unsupported path), and do not throw.
            try? store.documentIndex.replaceParts(documentID: documentID, parts: [])
            try markExtractionFailed(documentID: documentID, error: ExtractionError.unsupportedFormat(verifiedURL.pathExtension))
            return
        }

        do {
            var result = try await extraction.extract(fileURL: verifiedURL)
            var ocrApplied = false
            if result.needsOCR, ocr != nil {
                do {
                    result = try await applyOCR(to: result, blobURL: verifiedURL, family: format.family)
                    ocrApplied = true
                    _ = try? store.auditEvents.recordEvent(
                        matterID: document.matterID, eventType: "document_ocr_completed", actor: "system",
                        summary: "OCR completed for \(document.displayName)", relatedTable: "matter_documents", relatedID: documentID
                    )
                } catch {
                    _ = try? store.auditEvents.recordEvent(
                        matterID: document.matterID, eventType: "document_ocr_failed", actor: "system",
                        summary: "OCR failed for \(document.displayName)", relatedTable: "matter_documents", relatedID: documentID
                    )
                    throw error
                }
            }
            try persistExtraction(result, documentID: documentID, ocrApplied: ocrApplied)
            try store.documentLibrary.updateIndexStatus(documentID: documentID, indexStatus: .stale)
            _ = try? store.auditEvents.recordEvent(
                matterID: document.matterID, eventType: "document_reprocessed", actor: "user",
                summary: "Re-extracted \(document.displayName) from its managed copy",
                relatedTable: "matter_documents", relatedID: documentID
            )
        } catch {
            // A re-extraction that fails again re-marks the instance .failed cleanly and
            // clears any parts (markExtractionFailed only zeroes the count). The failure
            // is swallowed so a re-mark is a normal outcome for the caller.
            try? store.documentIndex.replaceParts(documentID: documentID, parts: [])
            try markExtractionFailed(documentID: documentID, error: error)
        }
    }

    // MARK: - OCR

    /// Runs OCR over a document that lacks embedded text and merges the results
    /// into the extraction (plan §6.2). Confidence flows to the page parts.
    private func applyOCR(
        to result: ExtractionResult,
        blobURL: URL,
        family: SupportedDocumentTypes.ExtractionFamily
    ) async throws -> ExtractionResult {
        guard let ocr else { return result }
        var merged = result
        switch family {
        case .image:
            let ocrResult = try await ocr.recognizeImage(at: blobURL)
            merged.parts = [ExtractedPart(
                sourceKind: .image, text: ocrResult.text, pageIndex: 0, pageLabel: "1",
                ocrConfidence: ocrResult.confidence, boundingBoxesJSON: ocrResult.boundingBoxesJSON
            )]
            merged.method = "vision-ocr-image"
            merged.needsOCR = false
        case .pdf:
            let pageResults = try await ocr.recognizePDFPages(at: blobURL, pageIndices: result.ocrPageIndices)
            let ocrTargets = Set(result.ocrPageIndices)
            merged.parts = result.parts.enumerated().map { index, part in
                var updated = part
                let pageIndex = part.pageIndex ?? index
                // Only the pages the extractor flagged for OCR are touched. Their
                // confidence is recorded even when OCR recovered nothing (so the
                // review gate can see it), but the OCR text only replaces the
                // embedded text when it is actually longer.
                if ocrTargets.contains(pageIndex), let ocrResult = pageResults[pageIndex] {
                    updated.ocrConfidence = ocrResult.confidence
                    if ocrResult.text.count > part.text.count {
                        updated.text = ocrResult.text
                        updated.boundingBoxesJSON = ocrResult.boundingBoxesJSON
                    }
                }
                return updated
            }
            merged.method = result.method + "+ocr"
            merged.needsOCR = false
        default:
            break
        }
        return merged
    }

    // MARK: - Persistence

    private func persistExtraction(_ result: ExtractionResult, documentID: String, ocrApplied: Bool = false) throws {
        let parts = result.parts.enumerated().map { index, part in
            DocumentPagePartRecord(
                documentID: documentID,
                partIndex: index,
                sourceKind: part.sourceKind.rawValue,
                pageIndex: part.pageIndex,
                pageLabel: part.pageLabel,
                sheetName: part.sheetName,
                cellRange: part.cellRange,
                emailPartPath: part.emailPartPath,
                normalizedText: part.text,
                charCount: part.text.count,
                ocrConfidence: part.ocrConfidence,
                boundingBoxesJSON: part.boundingBoxesJSON
            )
        }
        try store.documentIndex.replaceParts(documentID: documentID, parts: parts)

        let checksum = DocumentStorage.sha256Hex(of: Data(result.combinedText.utf8))

        // OCR confidence summary + low-confidence review gating (plan §6.2).
        let ocrConfidences = result.parts.compactMap(\.ocrConfidence)
        let meanOCR = ocrConfidences.isEmpty ? nil : ocrConfidences.reduce(0, +) / Double(ocrConfidences.count)
        let lowConfidence = (meanOCR.map { $0 < OCRPolicy.lowConfidenceThreshold } ?? false)
        let ocrSummary = meanOCR.map { String(format: "OCR mean confidence %.2f%@", $0, lowConfidence ? " (low)" : "") }

        // OCR ran but recovered little or no text — a blank or illegible original.
        // Route it to review instead of laundering the output into a clean
        // extraction. Keyed off `ocrApplied` so a fully failed render (no recorded
        // confidences at all) is still caught (plan §6.2, §8.4).
        let usableTextCount = result.combinedText.filter { !$0.isWhitespace }.count
        let insufficientOCRText = ocrApplied && usableTextCount < OCRPolicy.minimumUsableTextLength
        let convertedLossy = result.method == "converted_lossy"

        var warnings = result.warnings
        if ocrApplied {
            // OCR has now run, so the extractor's pre-OCR advisories would
            // recommend work that already happened — drop them and record one
            // outcome-specific warning instead: no text at all, too little text
            // to rely on, or usable text at low confidence (plan §6.2, §8.4).
            warnings.removeAll {
                $0 == PDFExtractor.ocrRecommendedWarning || $0 == ImageExtractor.ocrRequiredWarning
            }
            if usableTextCount == 0 {
                warnings.append("OCR produced no usable text; the original may be blank or illegible. Review the document.")
            } else if usableTextCount < OCRPolicy.minimumUsableTextLength {
                warnings.append("OCR recovered very little text; review the document before relying on it.")
            } else if lowConfidence {
                warnings.append("OCR confidence is low; verify the extracted text before relying on it.")
            }
        } else if lowConfidence {
            warnings.append("OCR confidence is low; verify the extracted text before relying on it.")
        }
        let warningsJSON = warnings.isEmpty ? nil : (try? JSONEncoder.encodeToString(warnings))

        let extractionStatus: DocumentExtractionStatus
        let status: MatterDocumentStatus
        if result.needsOCR {
            extractionStatus = .needsOCR
            status = .needsOCR
        } else if ocrApplied || !ocrConfidences.isEmpty {
            extractionStatus = .ocrComplete
            status = (lowConfidence || insufficientOCRText) ? .needsReview : .indexing
        } else {
            extractionStatus = .extracted
            status = convertedLossy ? .needsReview : .indexing
        }

        try store.documentLibrary.updateExtraction(
            documentID: documentID,
            status: status,
            extractionStatus: extractionStatus,
            method: DocumentToolchain.stamp(extractionMethod: result.method),
            checksum: checksum,
            pagePartCount: parts.count,
            ocrConfidenceSummary: ocrSummary,
            warningsJSON: warningsJSON,
            metadataCreatedAt: result.metadataCreatedAt,
            metadataModifiedAt: result.metadataModifiedAt
        )
    }

    private func markExtractionFailed(documentID: String, error: Error) throws {
        let json = try? JSONEncoder.encodeToString([error.localizedDescription])
        try store.documentLibrary.updateExtraction(
            documentID: documentID,
            status: .failed,
            extractionStatus: .failed,
            method: "failed",
            checksum: nil,
            pagePartCount: 0,
            errorsJSON: json
        )
    }

    private struct ManagedImportedBlob {
        let record: DocumentBlobRecord
        let verifiedURL: URL
        let reused: Bool
    }

    private func ingestBlob(at url: URL) throws -> ManagedImportedBlob {
        let ingested: DocumentStorage.IngestResult
        do {
            ingested = try storage.ingest(source: url)
        } catch let error as DocumentStorage.IntegrityError {
            if case .corruptManagedBlob(let digest, _, let reason) = error,
               let existing = try store.documentLibrary.fetchBlob(sha256: digest) {
                // A row that points somewhere else may still be valid (for example,
                // an older import kept a different extension). Prefer that verified
                // identity; otherwise persist the typed corrupt state.
                do {
                    let verified = try storage.verifyManagedBlob(
                        relativePath: existing.managedRelativePath,
                        expectedSHA256: existing.sha256,
                        expectedByteSize: existing.byteSize
                    )
                    try store.documentLibrary.updateBlobIntegrity(
                        id: existing.id,
                        status: .verified,
                        verifiedAt: Date(),
                        error: nil
                    )
                    let refreshed = try store.documentLibrary.fetchBlob(id: existing.id) ?? existing
                    return ManagedImportedBlob(record: refreshed, verifiedURL: verified, reused: true)
                } catch {
                    try? store.documentLibrary.updateBlobIntegrity(
                        id: existing.id,
                        status: .corrupt,
                        verifiedAt: nil,
                        error: reason
                    )
                }
            }
            throw error
        }

        if let existing = try store.documentLibrary.fetchBlob(sha256: ingested.sha256) {
            let verifiedURL: URL
            do {
                verifiedURL = try storage.verifyManagedBlob(
                    relativePath: existing.managedRelativePath,
                    expectedSHA256: existing.sha256,
                    expectedByteSize: existing.byteSize
                )
            } catch let integrityError as DocumentStorage.IntegrityError {
                let status: DocumentBlobIntegrityStatus
                if case .missingManagedBlob = integrityError { status = .missing } else { status = .corrupt }
                try? store.documentLibrary.updateBlobIntegrity(
                    id: existing.id,
                    status: status,
                    verifiedAt: nil,
                    error: Self.safeIntegrityReason(integrityError)
                )
                throw integrityError
            }
            try store.documentLibrary.updateBlobIntegrity(
                id: existing.id,
                status: .verified,
                verifiedAt: Date(),
                error: nil
            )
            if existing.managedRelativePath != ingested.managedRelativePath,
               ingested.disposition == .installed {
                // The unique sha row proves no database record can reference this
                // alternate-extension path. It is safe to remove this new orphan.
                try? FileManager.default.removeItem(at: ingested.managedURL)
            }
            let refreshed = try store.documentLibrary.fetchBlob(id: existing.id) ?? existing
            return ManagedImportedBlob(record: refreshed, verifiedURL: verifiedURL, reused: true)
        }

        let now = Date()
        let result = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: ingested.sha256,
                byteSize: ingested.byteSize,
                originalExtension: ingested.originalExtension,
                managedRelativePath: ingested.managedRelativePath,
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: now
            )
        )

        // A concurrent writer may have won the unique-sha race between our read
        // and upsert. Verify the returned row rather than trusting either path.
        let verifiedURL = try storage.verifyManagedBlob(
            relativePath: result.blob.managedRelativePath,
            expectedSHA256: result.blob.sha256,
            expectedByteSize: result.blob.byteSize
        )
        try store.documentLibrary.updateBlobIntegrity(
            id: result.blob.id,
            status: .verified,
            verifiedAt: now,
            error: nil
        )
        if result.reused,
           result.blob.managedRelativePath != ingested.managedRelativePath,
           ingested.disposition == .installed {
            try? FileManager.default.removeItem(at: ingested.managedURL)
        }
        let refreshed = try store.documentLibrary.fetchBlob(id: result.blob.id) ?? result.blob
        return ManagedImportedBlob(
            record: refreshed,
            verifiedURL: verifiedURL,
            reused: result.reused || ingested.disposition == .reusedVerified
        )
    }

    private static func safeIntegrityReason(_ error: DocumentStorage.IntegrityError) -> String {
        switch error {
        case .missingManagedBlob:
            return "missing_managed_file"
        case .corruptManagedBlob(_, _, let reason):
            return reason
        case .invalidManagedPath:
            return "invalid_managed_path"
        default:
            return "managed_blob_verification_failed"
        }
    }

    private func folder(
        forRelativeDir relativeDir: String,
        matterID: String,
        rootFolderID: String?,
        folderCache: inout [String: String?]
    ) throws -> String? {
        if relativeDir.isEmpty { return rootFolderID }
        if let cached = folderCache[relativeDir] { return cached }

        let components = relativeDir.split(separator: "/").map(String.init)
        var parentID = rootFolderID
        var accumulated = ""
        for component in components {
            accumulated = accumulated.isEmpty ? component : "\(accumulated)/\(component)"
            if let cached = folderCache[accumulated] {
                parentID = cached
                continue
            }
            // Reuse an existing same-named folder (seeded template folders,
            // prior imports) instead of creating a duplicate sibling.
            let folder = try store.documentLibrary.ensureFolder(
                matterID: matterID,
                name: component,
                parentFolderID: parentID
            )
            folderCache[accumulated] = folder.id
            parentID = folder.id
        }
        return parentID
    }

    private func resolveBatch(
        matterID: String,
        batchID: String?,
        sources: [URL],
        targetFolderID: String?
    ) throws -> DocumentImportBatchRecord {
        if let batchID, let existing = try store.documentJobs.fetchBatch(id: batchID) {
            guard existing.matterID == matterID else {
                throw DocumentJobRepositoryError.batchMatterMismatch(batchID: batchID, matterID: matterID)
            }
            guard existing.targetFolderRequested == (targetFolderID != nil),
                  existing.targetFolderID == targetFolderID else {
                throw DocumentJobRepositoryError.invalidTargetFolderIntent
            }
            return existing
        }
        let rootName = sources.first?.deletingLastPathComponent().lastPathComponent
        return try store.documentJobs.createBatch(
            matterID: matterID,
            sourceRootDisplay: rootName,
            targetFolderID: targetFolderID,
            targetFolderRequested: targetFolderID != nil
        )
    }

    private func finalizeLedgerBatch(batchID: String, matterID: String) throws -> ImportOutcome {
        let report = try ledgerReport(batchID: batchID)
        let status: DocumentImportBatchStatus = report.failedCount > 0 ? .completeWithFailures : .complete
        try store.documentJobs.updateBatchProgress(
            id: batchID,
            discoveredCount: report.discoveredCount,
            importedCount: report.importedCount,
            failedCount: report.failedCount
        )
        let reportJSON = try JSONEncoder.encodeToString(report)
        try store.documentJobs.finalizeBatch(id: batchID, status: status, reportJSON: reportJSON)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: report.failedCount > 0 ? "document_import_completed_with_failures" : "document_import_completed",
            actor: "system",
            summary: "Resumed import completed for \(report.importedCount)/\(report.discoveredCount) sources",
            relatedTable: "document_import_batches",
            relatedID: batchID
        )
        return ImportOutcome(batchID: batchID, report: report)
    }

    private func ledgerReport(batchID: String) throws -> DocumentImportReport {
        let sources = try store.documentJobs.fetchSources(batchID: batchID)
        let items = sources.map { source in
            DocumentImportReportItem(
                displayName: NSString(string: source.sourceDisplayPath).lastPathComponent,
                sourceDisplayPath: source.sourceDisplayPath,
                disposition: source.state,
                reason: source.reason,
                documentID: source.documentID,
                parentDocumentID: nil,
                rejectionCode: source.rejectionCode
            )
        }
        return DocumentImportReport(items: items, counts: Self.tallyCounts(items))
    }

    private static func resolveSourceBookmark(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        for options: URL.BookmarkResolutionOptions in [[.withSecurityScope], []] {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale, FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    @discardableResult
    private func recordSource(
        batchID: String,
        matterID: String,
        sourceKey: String,
        sourceDisplayPath: String,
        sourceBookmark: Data? = nil,
        parentSourceID: String? = nil,
        state: DocumentImportSourceState = .discovered
    ) throws -> DocumentImportSourceRecord {
        let row = try store.documentJobs.recordDiscovered(
            batchID: batchID,
            matterID: matterID,
            sourceKey: sourceKey,
            sourceDisplayPath: sourceDisplayPath,
            sourceBookmark: sourceBookmark,
            parentSourceID: parentSourceID,
            state: state
        )
        try sourceStateObserver(row)
        return row
    }

    @discardableResult
    private func transitionSource(
        _ sourceID: String,
        to state: DocumentImportSourceState,
        rejectionCode: String? = nil,
        reason: String? = nil,
        documentID: String? = nil,
        blobSHA256: String? = nil
    ) throws -> DocumentImportSourceRecord {
        let row = try store.documentJobs.markState(
            sourceID: sourceID,
            state: state,
            rejectionCode: rejectionCode,
            reason: reason,
            documentID: documentID,
            blobSHA256: blobSHA256
        )
        try sourceStateObserver(row)
        return row
    }

    private func recordPolicyRejection(
        _ violation: ImportPolicyViolation,
        url: URL,
        sourceDisplayPath: String,
        sourceID: String,
        parentDocumentID: String? = nil,
        report: inout DocumentImportReport
    ) throws {
        try recordPolicyRejection(
            violation,
            displayName: url.lastPathComponent,
            sourceDisplayPath: sourceDisplayPath,
            sourceID: sourceID,
            parentDocumentID: parentDocumentID,
            report: &report
        )
    }

    private func recordPolicyRejection(
        _ violation: ImportPolicyViolation,
        displayName: String,
        sourceDisplayPath: String,
        sourceID: String,
        parentDocumentID: String? = nil,
        report: inout DocumentImportReport
    ) throws {
        try transitionSource(
            sourceID,
            to: .rejected,
            rejectionCode: violation.code.rawValue,
            reason: violation.localizedDescription
        )
        report.items.append(DocumentImportReportItem(
            displayName: displayName,
            sourceDisplayPath: sourceDisplayPath,
            disposition: DocumentImportSourceState.rejected.rawValue,
            reason: violation.localizedDescription,
            parentDocumentID: parentDocumentID,
            rejectionCode: violation.code.rawValue
        ))
    }

    private func recordUnsupportedByPolicy(
        reason: String,
        displayName: String,
        sourceDisplayPath: String,
        sourceID: String,
        parentDocumentID: String? = nil,
        report: inout DocumentImportReport
    ) throws {
        try transitionSource(sourceID, to: .unsupportedByPolicy, reason: reason)
        report.items.append(DocumentImportReportItem(
            displayName: displayName,
            sourceDisplayPath: sourceDisplayPath,
            disposition: DocumentImportSourceState.unsupportedByPolicy.rawValue,
            reason: reason,
            parentDocumentID: parentDocumentID
        ))
    }

    private func recordFailure(
        _ error: Error,
        displayName: String,
        sourceDisplayPath: String,
        sourceID: String,
        parentDocumentID: String? = nil,
        reason: String? = nil,
        report: inout DocumentImportReport
    ) throws {
        let persistedReason = reason ?? "Unreadable: \(error.localizedDescription)"
        try transitionSource(sourceID, to: .failed, reason: persistedReason)
        report.items.append(DocumentImportReportItem(
            displayName: displayName,
            sourceDisplayPath: sourceDisplayPath,
            disposition: DocumentImportDisposition.extractionFailed.rawValue,
            reason: persistedReason,
            parentDocumentID: parentDocumentID
        ))
    }

    private static func tallyCounts(_ items: [DocumentImportReportItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.disposition, default: 0] += 1
        }
        return counts
    }
}

private struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct ImportFileMetadata: Sendable {
    let identity: FileIdentity
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let linkCount: UInt64
    let byteSize: Int
}

/// Pins the selected root's identity before enumeration and rechecks it before
/// every candidate access, closing root-replacement and link-following races.
private struct PinnedImportRoot: Sendable {
    private let selectedURL: URL
    private let canonicalPath: String
    private let identity: FileIdentity
    private let isDirectory: Bool

    init(url: URL) throws {
        let metadata = try Self.metadata(at: url)
        if metadata.isSymbolicLink {
            throw ImportPolicyViolation(.symbolicLink, "Symbolic-link roots are not imported.")
        }
        if Self.isAlias(url) {
            throw ImportPolicyViolation(.alias, "Finder-alias roots are not imported.")
        }
        self.selectedURL = url.standardizedFileURL
        self.canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.identity = metadata.identity
        self.isDirectory = metadata.isDirectory
    }

    func verifyUnchanged() throws {
        let current: ImportFileMetadata
        do {
            current = try Self.metadata(at: selectedURL)
        } catch {
            throw ImportPolicyViolation(.rootChanged, "The selected import root changed during traversal.")
        }
        guard !current.isSymbolicLink,
              current.identity == identity,
              current.isDirectory == isDirectory,
              !Self.isAlias(selectedURL) else {
            throw ImportPolicyViolation(.rootChanged, "The selected import root changed during traversal.")
        }
    }

    func validateCandidate(_ url: URL) throws -> ImportFileMetadata {
        try Task.checkCancellation()
        try verifyUnchanged()
        let metadata = try Self.metadata(at: url)
        if metadata.isSymbolicLink {
            throw ImportPolicyViolation(.symbolicLink, "Symbolic links are not imported.")
        }
        if Self.isAlias(url) {
            throw ImportPolicyViolation(.alias, "Finder aliases are not imported.")
        }
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let contained = isDirectory
            ? candidatePath == canonicalPath || candidatePath.hasPrefix(canonicalPath + "/")
            : candidatePath == canonicalPath
        guard contained else {
            throw ImportPolicyViolation(.outsideRoot, "Import traversal attempted to leave the selected root.")
        }
        return metadata
    }

    private static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }

    private static func metadata(at url: URL) throws -> ImportFileMetadata {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let fileType = value.st_mode & mode_t(S_IFMT)
        let size = value.st_size > 0 ? Int(value.st_size) : 0
        return ImportFileMetadata(
            identity: FileIdentity(
                device: UInt64(bitPattern: Int64(value.st_dev)),
                inode: UInt64(value.st_ino)
            ),
            isDirectory: fileType == mode_t(S_IFDIR),
            isRegularFile: fileType == mode_t(S_IFREG),
            isSymbolicLink: fileType == mode_t(S_IFLNK),
            linkCount: UInt64(value.st_nlink),
            byteSize: size
        )
    }
}

/// One ledger is shared by top-level files and recursively extracted
/// attachments so nesting cannot reset aggregate limits.
private final class ImportBudgetLedger: @unchecked Sendable {
    private let policy: ImportPolicy
    private var fileCount = 0
    private var attachmentCount = 0
    private var aggregateSourceBytes = 0
    private var aggregateDecodedBytes = 0

    init(policy: ImportPolicy) {
        self.policy = policy
    }

    func consumeSource(byteSize: Int) throws {
        fileCount += 1
        guard fileCount <= policy.maxFileCount else {
            throw ImportPolicyViolation(.fileCount, "Import exceeds the \(policy.maxFileCount)-file limit.")
        }
        let (next, overflow) = aggregateSourceBytes.addingReportingOverflow(byteSize)
        guard !overflow, next <= policy.maxAggregateSourceBytes else {
            throw ImportPolicyViolation(
                .aggregateSourceBytes,
                "Import exceeds the \(policy.maxAggregateSourceBytes)-byte aggregate source limit."
            )
        }
        aggregateSourceBytes = next
    }

    func consumeAttachment(byteSize: Int, depth: Int) throws {
        guard depth <= policy.maxMIMEDepth else {
            throw ImportPolicyViolation(
                .mimeDepthLimit,
                "Nested attachments exceed the \(policy.maxMIMEDepth)-level limit."
            )
        }
        attachmentCount += 1
        guard attachmentCount <= policy.maxAttachments else {
            throw ImportPolicyViolation(
                .attachmentCountLimit,
                "Import exceeds the \(policy.maxAttachments)-attachment limit."
            )
        }
        try consumeSource(byteSize: byteSize)
    }

    func consumeDecoded(_ result: ExtractionResult) throws {
        var bytes = result.combinedText.utf8.count
        for attachment in result.attachments {
            let (next, overflow) = bytes.addingReportingOverflow(attachment.data.count)
            guard !overflow else {
                throw ImportPolicyViolation(.expandedBytesLimit, "Decoded content size overflowed the aggregate counter.")
            }
            bytes = next
        }
        let (next, overflow) = aggregateDecodedBytes.addingReportingOverflow(bytes)
        guard !overflow, next <= policy.maxArchiveExpandedBytes else {
            throw ImportPolicyViolation(
                .expandedBytesLimit,
                "Import exceeds the \(policy.maxArchiveExpandedBytes)-byte aggregate decoded limit."
            )
        }
        aggregateDecodedBytes = next
    }
}

extension JSONEncoder {
    static func encodeToString<T: Encodable>(_ value: T) throws -> String? {
        String(data: try JSONEncoder().encode(value), encoding: .utf8)
    }
}
