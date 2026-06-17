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
}

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
        }.count
    }
    public var failedCount: Int {
        items.filter {
            $0.disposition == DocumentImportDisposition.extractionFailed.rawValue
                || $0.disposition == DocumentImportDisposition.unsupported.rawValue
                || $0.disposition == DocumentImportDisposition.ocrFailed.rawValue
        }.count
    }
}

/// Imports files and folders into a matter: copies each into content-addressed
/// managed storage, preserves folder hierarchy, deduplicates blobs, expands
/// email attachments as child documents, extracts text, and produces an import
/// report (plan §4–§5). Originals are never modified.
///
/// OCR is applied later by `DocumentOCRPass` (WO 36); files that need OCR are
/// left with `needs_ocr` status here.
public final class DocumentImportService: @unchecked Sendable {
    private let store: SupraStore
    private let storage: DocumentStorage
    private let extraction: ExtractionService

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        extraction: ExtractionService = ExtractionService()
    ) {
        self.store = store
        self.storage = storage
        self.extraction = extraction
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
        let batch = try resolveBatch(matterID: matterID, batchID: batchID, sources: sources)

        var report = DocumentImportReport()
        var folderCache: [String: String?] = [:]  // managed relative dir path -> folder id

        for source in sources {
            try await importEntry(
                at: source,
                relativeDir: "",
                rootName: source.lastPathComponent,
                matterID: matterID,
                batchID: batch.id,
                rootFolderID: targetFolderID,
                folderCache: &folderCache,
                report: &report
            )
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

    // MARK: - Discovery / recursion

    private func importEntry(
        at url: URL,
        relativeDir: String,
        rootName: String,
        matterID: String,
        batchID: String,
        rootFolderID: String?,
        folderCache: inout [String: String?],
        report: inout DocumentImportReport
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            let childDir = relativeDir.isEmpty ? url.lastPathComponent : "\(relativeDir)/\(url.lastPathComponent)"
            let folderID = try folder(
                forRelativeDir: childDir,
                matterID: matterID,
                rootFolderID: rootFolderID,
                folderCache: &folderCache
            )
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try await importEntryWithFolder(
                    at: child,
                    parentRelativeDir: childDir,
                    parentFolderID: folderID,
                    rootName: rootName,
                    matterID: matterID,
                    batchID: batchID,
                    rootFolderID: rootFolderID,
                    folderCache: &folderCache,
                    report: &report
                )
            }
        } else {
            try await importFile(
                at: url,
                folderID: rootFolderID,
                sourceDisplayPath: relativeDir.isEmpty ? url.lastPathComponent : "\(relativeDir)/\(url.lastPathComponent)",
                matterID: matterID,
                batchID: batchID,
                report: &report
            )
        }
    }

    private func importEntryWithFolder(
        at url: URL,
        parentRelativeDir: String,
        parentFolderID: String?,
        rootName: String,
        matterID: String,
        batchID: String,
        rootFolderID: String?,
        folderCache: inout [String: String?],
        report: inout DocumentImportReport
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            try await importEntry(
                at: url,
                relativeDir: parentRelativeDir,
                rootName: rootName,
                matterID: matterID,
                batchID: batchID,
                rootFolderID: rootFolderID,
                folderCache: &folderCache,
                report: &report
            )
        } else {
            try await importFile(
                at: url,
                folderID: parentFolderID,
                sourceDisplayPath: "\(parentRelativeDir)/\(url.lastPathComponent)",
                matterID: matterID,
                batchID: batchID,
                report: &report
            )
        }
    }

    // MARK: - Single file import

    @discardableResult
    private func importFile(
        at url: URL,
        folderID: String?,
        sourceDisplayPath: String,
        matterID: String,
        batchID: String,
        parentDocumentID: String? = nil,
        report: inout DocumentImportReport
    ) async throws -> String? {
        let displayName = url.lastPathComponent
        let format = SupportedDocumentTypes.format(for: url)

        // Copy + dedup the blob even for unsupported files so the instance can be
        // shown and managed; mark unsupported in the report.
        let blob: DocumentBlobRecord
        do {
            blob = try copyBlob(at: url)
        } catch {
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: DocumentImportDisposition.extractionFailed.rawValue,
                reason: "Unreadable: \(error.localizedDescription)", parentDocumentID: parentDocumentID
            ))
            return nil
        }

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
            return unsupported.id
        }

        try store.documentLibrary.insertDocument(document)

        // Extract.
        do {
            let result = try await extraction.extract(fileURL: url)
            try persistExtraction(result, documentID: document.id)
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: result.needsOCR ? DocumentImportDisposition.ocrNeeded.rawValue : DocumentImportDisposition.imported.rawValue,
                documentID: document.id, parentDocumentID: parentDocumentID
            ))
            // Expand email attachments as child documents.
            for attachment in result.attachments {
                try await importAttachment(
                    attachment,
                    parentDocument: document,
                    folderID: folderID,
                    matterID: matterID,
                    batchID: batchID,
                    report: &report
                )
            }
        } catch {
            try store.documentLibrary.updateStatus(documentID: document.id, status: .failed)
            try? markExtractionFailed(documentID: document.id, error: error)
            report.items.append(DocumentImportReportItem(
                displayName: displayName, sourceDisplayPath: sourceDisplayPath,
                disposition: DocumentImportDisposition.extractionFailed.rawValue,
                reason: error.localizedDescription, documentID: document.id, parentDocumentID: parentDocumentID
            ))
        }
        return document.id
    }

    private func importAttachment(
        _ attachment: ExtractedAttachment,
        parentDocument: MatterDocumentRecord,
        folderID: String?,
        matterID: String,
        batchID: String,
        report: inout DocumentImportReport
    ) async throws {
        // Write the attachment bytes to a unique temp directory keeping the
        // original filename, so the path-based import pipeline (copy/dedup/extract)
        // handles it and the child document keeps the attachment's display name.
        let tempDir = storage.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(attachment.fileName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try attachment.data.write(to: tempURL)
        } catch {
            report.items.append(DocumentImportReportItem(
                displayName: attachment.fileName, sourceDisplayPath: "\(parentDocument.sourceDisplayPath ?? parentDocument.displayName) ▸ \(attachment.fileName)",
                disposition: DocumentImportDisposition.extractionFailed.rawValue,
                reason: "Could not write attachment.", parentDocumentID: parentDocument.id
            ))
            return
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A failed attachment must not fail the parent email (plan §3.2).
        _ = try? await importFile(
            at: tempURL,
            folderID: folderID,
            sourceDisplayPath: "\(parentDocument.sourceDisplayPath ?? parentDocument.displayName) ▸ \(attachment.fileName)",
            matterID: matterID,
            batchID: batchID,
            parentDocumentID: parentDocument.id,
            report: &report
        )
    }

    // MARK: - Persistence

    private func persistExtraction(_ result: ExtractionResult, documentID: String) throws {
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
                ocrConfidence: part.ocrConfidence
            )
        }
        try store.documentIndex.replaceParts(documentID: documentID, parts: parts)

        let checksum = DocumentStorage.sha256Hex(of: Data(result.combinedText.utf8))
        let warningsJSON = result.warnings.isEmpty ? nil : (try? JSONEncoder.encodeToString(result.warnings))
        let extractionStatus: DocumentExtractionStatus = result.needsOCR ? .needsOCR : .extracted
        let status: MatterDocumentStatus = result.needsOCR ? .needsOCR : .indexing

        try store.documentLibrary.updateExtraction(
            documentID: documentID,
            status: status,
            extractionStatus: extractionStatus,
            method: result.method,
            checksum: checksum,
            pagePartCount: parts.count,
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

    private func copyBlob(at url: URL) throws -> DocumentBlobRecord {
        let sha = try DocumentStorage.sha256Hex(ofFileAt: url)
        if let existing = try store.documentLibrary.fetchBlob(sha256: sha) {
            return existing
        }
        let ext = url.pathExtension
        let relativePath = DocumentStorage.blobRelativePath(sha256: sha, fileExtension: ext)
        let destination = storage.url(forManagedRelativePath: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        let byteSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let result = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: sha,
                byteSize: byteSize ?? 0,
                originalExtension: ext,
                managedRelativePath: relativePath
            )
        )
        return result.blob
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
            let created = try store.documentLibrary.createFolder(matterID: matterID, name: component, parentFolderID: parentID)
            folderCache[accumulated] = created.id
            parentID = created.id
        }
        return parentID
    }

    private func resolveBatch(matterID: String, batchID: String?, sources: [URL]) throws -> DocumentImportBatchRecord {
        if let batchID, let existing = try store.documentJobs.fetchBatch(id: batchID) {
            return existing
        }
        let rootName = sources.first?.deletingLastPathComponent().lastPathComponent
        return try store.documentJobs.createBatch(matterID: matterID, sourceRootDisplay: rootName)
    }

    private static func tallyCounts(_ items: [DocumentImportReportItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.disposition, default: 0] += 1
        }
        return counts
    }
}

extension JSONEncoder {
    static func encodeToString<T: Encodable>(_ value: T) throws -> String? {
        String(data: try JSONEncoder().encode(value), encoding: .utf8)
    }
}
