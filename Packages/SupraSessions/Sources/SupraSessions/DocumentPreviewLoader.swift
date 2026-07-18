import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// A resolved, renderable preview for a cited/searched source location
/// (plan §11). The view layer turns this into a PDFKit/image/text preview.
public struct DocumentPreviewModel: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Original PDF rendering, navigated to a page, with best-effort text
        /// highlight.
        case pdf(path: String, pageIndex: Int?, highlightText: String?)
        /// Original image rendering, with optional OCR bounding boxes.
        case image(path: String, boundingBoxesJSON: String?)
        /// Original file (Word, RTF, spreadsheet, email, …) rendered with QuickLook
        /// so it looks like Finder's preview instead of stripped plain text.
        /// QuickLook can't highlight a char range, so the cited `excerpt` (when a
        /// match is known) is surfaced in a banner above the preview so the reader
        /// can still find the cited passage.
        case quickLook(path: String, excerpt: String?)
        /// Normalized text preview with a best-effort char-range highlight.
        case text(content: String, highlightStart: Int?, highlightEnd: Int?)
        /// Preview could not be rendered; the normalized text is shown with the
        /// locator so the link never fails silently (plan §11.2).
        case unavailable(reason: String, fallbackText: String)
    }

    public var documentName: String
    public var locatorDisplay: String
    public var warnings: [String]
    /// Explicit provenance state for a cited output source. Nil means the
    /// preview was not opened from a persisted output citation.
    public var revisionNotice: String?
    public var kind: Kind
}

/// Resolves a document + locator into a `DocumentPreviewModel`, reading managed
/// blobs and normalized parts. Falls back to normalized text when a visual
/// preview is unavailable (plan §11.2).
public final class DocumentPreviewLoader: @unchecked Sendable {
    private let store: SupraStore
    private let storage: DocumentStorage

    public init(store: SupraStore, storage: DocumentStorage = .makeDefault()) {
        self.store = store
        self.storage = storage
    }

    public func load(documentID: String, locator: DocumentSourceLocator, matchText: String? = nil) -> DocumentPreviewModel {
        guard let document = try? store.documentLibrary.fetchDocument(id: documentID) else {
            return DocumentPreviewModel(
                documentName: "Document", locatorDisplay: locator.displayString,
                warnings: [], revisionNotice: nil,
                kind: .unavailable(reason: "Document not found.", fallbackText: "")
            )
        }
        let warnings = Self.warnings(for: document)
        let parts = (try? store.documentIndex.fetchParts(documentID: documentID)) ?? []
        let part = Self.part(matching: locator, in: parts)
        let fallbackText = part?.normalizedText ?? parts.first?.normalizedText ?? ""

        let blobURL = (try? store.documentLibrary.fetchBlob(id: document.blobID))
            .map { storage.url(forManagedRelativePath: $0.managedRelativePath) }
        let blobExists = blobURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        let kind: DocumentPreviewModel.Kind
        switch locator.sourceKind {
        case .pdfPage:
            if blobExists, let blobURL {
                kind = .pdf(path: blobURL.path, pageIndex: locator.pageIndex, highlightText: matchText)
            } else {
                kind = .unavailable(reason: "Original PDF unavailable.", fallbackText: fallbackText)
            }
        case .image:
            if blobExists, let blobURL {
                kind = .image(path: blobURL.path, boundingBoxesJSON: part?.boundingBoxesJSON ?? locator.boundingBoxesJSON)
            } else {
                kind = .unavailable(reason: "Original image unavailable.", fallbackText: fallbackText)
            }
        case .spreadsheetCellRange, .text, .markdown, .html, .xml, .emailBody, .emailAttachment, .convertedDocument:
            // Render the original file (Word/RTF/spreadsheet/email/…) with QuickLook so
            // it looks like Finder's preview; fall back to normalized text only when the
            // original blob is unavailable (plan §3.4 / §11.2). QuickLook can't paint a
            // char-range highlight, so carry the cited excerpt for a banner instead.
            if blobExists, let blobURL {
                let excerpt = (matchText?.isEmpty == false) ? matchText : nil
                kind = .quickLook(path: blobURL.path, excerpt: excerpt)
            } else if fallbackText.isEmpty {
                kind = .unavailable(reason: "No extracted text for this source.", fallbackText: "")
            } else {
                kind = .text(content: fallbackText, highlightStart: locator.charStart, highlightEnd: locator.charEnd)
            }
        }

        return DocumentPreviewModel(
            documentName: document.displayName,
            locatorDisplay: locator.displayString,
            warnings: warnings,
            revisionNotice: nil,
            kind: kind
        )
    }

    /// Resolves a persisted output citation against the exact immutable revision
    /// it recorded. Legacy nil bindings remain visibly unknown and continue to
    /// use their denormalized locator/excerpt-compatible preview path.
    public func load(outputSource: DocumentOutputSourceRecord) -> DocumentPreviewModel {
        let locator = (try? JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(outputSource.locatorJSON.utf8)
        )) ?? DocumentSourceLocator(sourceKind: .text)
        guard let documentID = outputSource.documentID else {
            return DocumentPreviewModel(
                documentName: "Document",
                locatorDisplay: locator.displayString,
                warnings: [],
                revisionNotice: outputSource.revisionID == nil
                    ? "revision unknown (pre-lineage)"
                    : nil,
                kind: .unavailable(
                    reason: "Cited document unavailable.",
                    fallbackText: outputSource.excerpt
                )
            )
        }

        guard let revisionID = outputSource.revisionID else {
            var legacy = load(
                documentID: documentID,
                locator: locator,
                matchText: outputSource.excerpt
            )
            legacy.revisionNotice = "revision unknown (pre-lineage)"
            return legacy
        }
        guard let revision = try? store.documentRevisions.fetchRevision(id: revisionID),
              revision.documentID == documentID,
              let document = try? store.documentLibrary.fetchDocument(id: documentID) else {
            return DocumentPreviewModel(
                documentName: "Document",
                locatorDisplay: locator.displayString,
                warnings: [],
                revisionNotice: nil,
                kind: .unavailable(
                    reason: "Recorded source revision unavailable.",
                    fallbackText: outputSource.excerpt
                )
            )
        }
        return DocumentPreviewModel(
            documentName: document.displayName,
            locatorDisplay: locator.displayString,
            warnings: Self.warnings(for: document),
            revisionNotice: nil,
            kind: .text(
                content: revision.text,
                highlightStart: locator.charStart,
                highlightEnd: locator.charEnd
            )
        )
    }

    /// Opens a document at its first part (used from the document list).
    public func loadDocument(documentID: String) -> DocumentPreviewModel {
        let parts = (try? store.documentIndex.fetchParts(documentID: documentID)) ?? []
        let first = parts.first
        let locator = DocumentSourceLocator(
            sourceKind: first.flatMap { DocumentSourceKind(rawValue: $0.sourceKind) } ?? .text,
            pageIndex: first?.pageIndex, pageLabel: first?.pageLabel,
            sheetName: first?.sheetName, cellRange: first?.cellRange,
            emailPartPath: first?.emailPartPath
        )
        return load(documentID: documentID, locator: locator)
    }

    private static func part(matching locator: DocumentSourceLocator, in parts: [DocumentPagePartRecord]) -> DocumentPagePartRecord? {
        switch locator.sourceKind {
        case .pdfPage, .image:
            if let pageIndex = locator.pageIndex, let match = parts.first(where: { $0.pageIndex == pageIndex }) {
                return match
            }
        case .spreadsheetCellRange:
            if let sheet = locator.sheetName, let match = parts.first(where: { $0.sheetName == sheet }) {
                return match
            }
        default:
            break
        }
        return parts.first
    }

    private static func warnings(for document: MatterDocumentRecord) -> [String] {
        var warnings: [String] = []
        if let json = document.extractionWarningsJSON, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            warnings.append(contentsOf: decoded)
        }
        if let summary = document.ocrConfidenceSummary, summary.contains("low") {
            warnings.append(summary)
        }
        return warnings
    }
}
