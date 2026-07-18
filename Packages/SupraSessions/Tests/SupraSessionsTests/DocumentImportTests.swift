import CoreGraphics
import CoreText
import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentImportTests: XCTestCase {
    private var sourceRoot = URL(fileURLWithPath: "/tmp")
    private var storageRoot = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = base.appendingPathComponent("Validation Matter", isDirectory: true)
        storageRoot = base.appendingPathComponent("ManagedStorage", isDirectory: true)
        try buildSourceTree()
    }

    @MainActor
    func testTOPS05EditingTextEnqueuesExactlyOneReindexAndRefreshesFTS() async throws {
        // T-OPS-05 expected RED: DocumentImportService has no
        // setReindexEnqueuer seam and updateExtractedText only marks stale.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic edit reindex")
        let service = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: storageRoot),
            ocr: nil
        )
        _ = try await service.importSources(
            [sourceRoot.appendingPathComponent("Contracts/agreement.txt")],
            matterID: matter.id
        )
        _ = try await DocumentIndexingService(store: store, embedder: nil)
            .indexMatter(matterID: matter.id)
        let document = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        let part = try XCTUnwrap(store.documentIndex.fetchParts(documentID: document.id).first)
        XCTAssertFalse(try store.documentIndex.searchChunks(
            matterID: matter.id,
            query: "effective 2024",
            documentIDs: [document.id]
        ).isEmpty)

        let queue = DocumentProcessingQueue(
            store: store,
            importService: service,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: EditReindexNotifier()
        )
        service.setReindexEnqueuer { [weak queue] matterID in
            _ = queue?.enqueueReindex(matterID: matterID)
        }

        try service.updateExtractedText(
            documentID: document.id,
            partID: part.id,
            text: "ZEPHYR_NONDEFAULT_EDIT proves the saved correction reached FTS."
        )

        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: document.id)?.indexStatus,
            DocumentIndexStatus.stale.rawValue
        )
        XCTAssertEqual(try store.documentJobs.fetchJobs(matterID: matter.id).count, 1)
        await queue.waitUntilIdle()
        XCTAssertFalse(try store.documentIndex.searchChunks(
            matterID: matter.id,
            query: "ZEPHYR_NONDEFAULT_EDIT",
            documentIDs: [document.id]
        ).isEmpty)
        XCTAssertTrue(try store.documentIndex.searchChunks(
            matterID: matter.id,
            query: "effective 2024",
            documentIDs: [document.id]
        ).isEmpty)
    }

    func testRecursiveImportPreservesHierarchyDedupsAndExpandsAttachments() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let storage = DocumentStorage(root: storageRoot)
        let service = DocumentImportService(store: store, storage: storage)

        let outcome = try await service.importSources([sourceRoot], matterID: matter.id)

        // Folder hierarchy preserved (root + 4 subfolders).
        let folders = try store.documentLibrary.fetchFolders(matterID: matter.id)
        XCTAssertTrue(folders.contains { $0.name == "Validation Matter" })
        XCTAssertTrue(folders.contains { $0.name == "Contracts" })
        XCTAssertTrue(folders.contains { $0.name == "Duplicates" })
        XCTAssertTrue(folders.contains { $0.name == "Emails" })

        // Duplicate content → one blob, two instances.
        let allDocs = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        let agreementInstances = allDocs.filter { $0.displayName.hasPrefix("agreement") }
        XCTAssertEqual(agreementInstances.count, 2)
        XCTAssertEqual(Set(agreementInstances.map(\.blobID)).count, 1, "identical files should share one blob")

        // Files copied into managed storage; original is untouched.
        let blob = try XCTUnwrap(store.documentLibrary.fetchBlob(id: agreementInstances[0].blobID))
        let managedURL = storage.url(forManagedRelativePath: blob.managedRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
        let originalContent = try String(contentsOf: sourceRoot.appendingPathComponent("Contracts/agreement.txt"), encoding: .utf8)
        XCTAssertEqual(originalContent, "Service agreement effective 2024-01-01.")

        // Extraction produced normalized text parts.
        let contractsDoc = try XCTUnwrap(agreementInstances.first)
        let parts = try store.documentIndex.fetchParts(documentID: contractsDoc.id)
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts.first?.normalizedText.contains("Service agreement") ?? false)

        // Email body imported + attachment as a child document.
        let emailDoc = try XCTUnwrap(allDocs.first { $0.displayName == "notice.eml" })
        let children = allDocs.filter { $0.parentDocumentID == emailDoc.id }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.displayName, "attached.txt")

        // Unsupported file appears in the report and as a failed instance.
        XCTAssertTrue(outcome.report.items.contains { $0.disposition == DocumentImportDisposition.unsupported.rawValue })
        XCTAssertTrue(allDocs.contains { $0.displayName == "weird.xyz" && $0.status == MatterDocumentStatus.failed.rawValue })

        // Report accounts for every discovered file (+ the attachment).
        XCTAssertGreaterThanOrEqual(outcome.report.discoveredCount, 5)
        XCTAssertGreaterThanOrEqual(outcome.report.importedCount, 3)

        // Batch finalized with the report.
        let batch = try XCTUnwrap(store.documentJobs.fetchBatch(id: outcome.batchID))
        XCTAssertNotNil(batch.completedAt)
        XCTAssertNotNil(batch.reportJSON)
    }

    func testMockedOCRFillsImageTextWithLowConfidenceReview() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let imageURL = sourceRoot.appendingPathComponent("Images/scanned-notice.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-png-bytes".utf8).write(to: imageURL)

        let ocr = MockOCRService(imageResult: OCRTextResult(text: "Notice of default dated 2024-05-01.", confidence: 0.40))
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([imageURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        // Low-confidence OCR routes to needs_review and records a summary.
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.ocrComplete.rawValue)
        XCTAssertTrue(doc.ocrConfidenceSummary?.contains("low") ?? false)

        let parts = try store.documentIndex.fetchParts(documentID: doc.id)
        XCTAssertEqual(parts.first?.normalizedText, "Notice of default dated 2024-05-01.")
        XCTAssertEqual(parts.first?.ocrConfidence ?? 1, 0.40, accuracy: 0.001)

        // Editing the OCR text marks the doc edited + stale for re-index.
        try await service.updateExtractedText(documentID: doc.id, partID: parts[0].id, text: "Notice of default dated May 1, 2024.")
        let edited = try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id))
        XCTAssertEqual(edited.indexStatus, DocumentIndexStatus.stale.rawValue)
        XCTAssertTrue(edited.hasUserEditedText)
        XCTAssertEqual(try store.documentIndex.fetchParts(documentID: doc.id).first?.normalizedText, "Notice of default dated May 1, 2024.")
    }

    func testMixedPDFOCRsOnlySparsePages() async throws {
        // Expected RED: assertion failure — `recordedPageIndices` is empty because the
        // document-average threshold marks the mixed PDF `needsOCR == false`, so
        // `applyOCR` never runs and the blank pages keep empty text / nil confidence.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let pdfURL = sourceRoot.appendingPathComponent("Scans/mixed-scan.pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let richText = "Retainer agreement between McKernon Motors and outside counsel, "
            + "executed on 2024 01 15. This page carries substantial embedded text so the "
            + "extractor treats it as a text page and not a scanned image. Distinctive anchor "
            + "token ZQXCANARY marks this page for scoped assertions. The remaining two pages "
            + "are intentionally blank so only they require OCR."
        try makePDF(at: pdfURL, pages: [.text(richText), .empty, .empty])

        let ocr = MockOCRService(pageResults: [
            1: OCRTextResult(text: "OCR recovered page two text QVX2.", confidence: 0.9),
            2: OCRTextResult(text: "OCR recovered page three text QVX3.", confidence: 0.9)
        ])
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([pdfURL], matterID: matter.id)

        // (a) OCR is invoked exactly once, over only the two sparse pages.
        XCTAssertEqual(ocr.recordedPageIndices.count, 1, "OCR should be invoked exactly once for the mixed PDF")
        XCTAssertEqual(ocr.recordedPageIndices.first ?? nil, [1, 2], "only the two blank pages should be sent to OCR")

        // (b) The rich first page keeps its embedded text (scoped to part 0).
        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        let parts = try store.documentIndex.fetchParts(documentID: doc.id)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts[0].normalizedText.contains("ZQXCANARY"), "page 0 must retain its embedded anchor text")

        // (c) The two blank pages carry the mocked OCR text + its confidence.
        XCTAssertTrue(parts[1].normalizedText.contains("page two text QVX2"), "page 1 should carry the OCR text")
        XCTAssertEqual(parts[1].ocrConfidence ?? 0, 0.9, accuracy: 0.001)
        XCTAssertTrue(parts[2].normalizedText.contains("page three text QVX3"), "page 2 should carry the OCR text")
        XCTAssertEqual(parts[2].ocrConfidence ?? 0, 0.9, accuracy: 0.001)
    }

    func testEmptyOCRLeavesDocumentInNeedsReview() async throws {
        // Expected RED: assertion failure — observed `extractionStatus == .extracted`
        // and `status == .indexing`; empty OCR output is laundered into a successful
        // extraction today, and no "OCR produced no usable text" warning is recorded.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let pdfURL = sourceRoot.appendingPathComponent("Scans/all-blank.pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(at: pdfURL, pages: [.empty, .empty])

        let ocr = MockOCRService(pageResults: [
            0: OCRTextResult(text: "", confidence: 0),
            1: OCRTextResult(text: "", confidence: 0)
        ])
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([pdfURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.ocrComplete.rawValue)
        let warningsJSON = try XCTUnwrap(doc.extractionWarningsJSON, "empty-OCR documents must record a review warning")
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertTrue(
            warnings.contains { $0.contains("OCR produced no usable text") },
            "warnings should explain the empty-OCR review; got \(warnings)"
        )
    }

    func testAllPagesRenderFailedOCRStillNeedsReview() async throws {
        // Expected RED: assertion failure — observed `.extracted`/`.indexing`. With an
        // empty page-results map no confidences are recorded at all, proving the review
        // gate must key off an explicit ocrApplied flag, not recorded confidences.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let pdfURL = sourceRoot.appendingPathComponent("Scans/all-blank-failed.pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(at: pdfURL, pages: [.empty, .empty])

        let ocr = MockOCRService(pageResults: [:])
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([pdfURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.ocrComplete.rawValue)
        let warningsJSON = try XCTUnwrap(doc.extractionWarningsJSON, "failed-render OCR must record a review warning")
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertTrue(
            warnings.contains { $0.contains("OCR produced no usable text") },
            "warnings should explain the failed-render review; got \(warnings)"
        )
    }

    func testIndexingPreservesNeedsReview() async throws {
        // Expected RED: assertion failure — observed `status == .ready` after indexing
        // (DocumentIndexingService.indexDocument unconditionally promotes to ready,
        // clobbering the needs_review state).
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        // A scanned image with low-confidence OCR routes to needs_review.
        let imageURL = sourceRoot.appendingPathComponent("Images/scanned-notice.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-png-bytes".utf8).write(to: imageURL)
        let ocr = MockOCRService(imageResult: OCRTextResult(text: "Notice of default dated 2024-05-01.", confidence: 0.40))
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([imageURL], matterID: matter.id)

        // A normal text file lands in `indexing` (extracted, no OCR).
        _ = try await service.importSources([sourceRoot.appendingPathComponent("Contracts/agreement.txt")], matterID: matter.id)

        let reviewDoc = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "scanned-notice.png" }
        )
        XCTAssertEqual(reviewDoc.status, MatterDocumentStatus.needsReview.rawValue, "precondition: low-confidence OCR routes to needs_review")

        let indexed = try await DocumentIndexingService(store: store, embedder: nil).indexMatter(matterID: matter.id)
        XCTAssertGreaterThanOrEqual(indexed, 2, "both the review doc and the text doc should be indexed")

        // Indexing must NOT clobber the manual-review status.
        let reviewedAfter = try XCTUnwrap(store.documentLibrary.fetchDocument(id: reviewDoc.id))
        XCTAssertEqual(reviewedAfter.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertEqual(reviewedAfter.indexStatus, DocumentIndexStatus.textIndexed.rawValue)

        // The normal text path still promotes to ready.
        let textDoc = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "agreement.txt" }
        )
        XCTAssertEqual(textDoc.status, MatterDocumentStatus.ready.rawValue, "normal indexing still reaches ready")
    }

    func testEditedTextMarksDocumentStaleForReindex() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot))
        _ = try await service.importSources([sourceRoot.appendingPathComponent("Contracts/agreement.txt")], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertNotEqual(doc.indexStatus, DocumentIndexStatus.stale.rawValue)

        try store.documentLibrary.markTextEdited(documentID: doc.id)
        let edited = try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id))
        XCTAssertTrue(edited.hasUserEditedText)
        XCTAssertEqual(edited.extractionStatus, DocumentExtractionStatus.edited.rawValue)
        XCTAssertEqual(edited.indexStatus, DocumentIndexStatus.stale.rawValue)
    }

    func testImportSourcesFilesTopLevelItemsIntoTargetFolder() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let folder = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot))

        _ = try await service.importSources(
            [sourceRoot.appendingPathComponent("Contracts/agreement.txt")],
            matterID: matter.id,
            targetFolderID: folder.id
        )

        let imported = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "agreement.txt" }
        )
        XCTAssertEqual(imported.folderID, folder.id, "a top-level import should land in the target folder, not root")
    }

    func testImportReusesExistingSameNamedFolder() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        // Pre-existing root folder with the same name as an imported directory
        // (e.g. a seeded template folder) — the import must file into it, not
        // create a duplicate "Contracts" sibling.
        let seeded = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot))

        _ = try await service.importSources([sourceRoot.appendingPathComponent("Contracts")], matterID: matter.id)

        let folders = try store.documentLibrary.fetchFolders(matterID: matter.id)
        XCTAssertEqual(folders.filter { $0.name.caseInsensitiveCompare("Contracts") == .orderedSame }.count, 1)
        let imported = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "agreement.txt" }
        )
        XCTAssertEqual(imported.folderID, seeded.id)
    }

    // MARK: - Fixtures

    private func buildSourceTree() throws {
        let fm = FileManager.default
        func mk(_ path: String) throws -> URL {
            let url = sourceRoot.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        try "Service agreement effective 2024-01-01.".write(to: try mk("Contracts/agreement.txt"), atomically: true, encoding: .utf8)
        try "Service agreement effective 2024-01-01.".write(to: try mk("Duplicates/agreement-copy.txt"), atomically: true, encoding: .utf8)
        try "Intake notes for the matter.".write(to: try mk("Notes/intake.md"), atomically: true, encoding: .utf8)

        let attachment = Data("attachment body".utf8).base64EncodedString()
        let eml = """
        From: a@example.com
        To: b@example.com
        Subject: Notice
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Notice body text.
        --B
        Content-Type: text/plain
        Content-Disposition: attachment; filename="attached.txt"
        Content-Transfer-Encoding: base64

        \(attachment)
        --B--
        """
        try eml.write(to: try mk("Emails/notice.eml"), atomically: true, encoding: .utf8)
        try "not a real format".write(to: try mk("Unsupported/weird.xyz"), atomically: true, encoding: .utf8)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    /// Builds a real PDF whose `.text` pages carry extractable embedded text (drawn
    /// with Core Text so PDFKit's `page.string` recovers it) and whose `.empty`
    /// pages carry none. Mirrors the CG `makePDF` pattern in HostileImportPolicyTests.
    private func makePDF(at url: URL, pages: [PDFPageContent]) throws {
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for page in pages {
            context.beginPDFPage(nil)
            if case let .text(string) = page {
                try drawTextPage(string, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Draws `text` into the current PDF page as word-wrapped Core Text lines. Words
    /// (including anchor tokens) are never split across lines, and ligatures are
    /// disabled, so PDFKit extraction recovers each token contiguously.
    private func drawTextPage(_ text: String, in context: CGContext) throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let ligaturesOff = NSNumber(value: 0)
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= 60 {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }

        var baseline: CGFloat = 740
        for lineText in lines {
            let attributed = try XCTUnwrap(CFAttributedStringCreate(
                nil,
                lineText as CFString,
                [kCTFontAttributeName: font, kCTLigatureAttributeName: ligaturesOff] as CFDictionary
            ))
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 36, y: baseline)
            CTLineDraw(line, context)
            baseline -= 18
        }
    }

    func testACRBLOB009ExtractionUsesVerifiedManagedBytesAfterSourceMutation() async throws {
        // Expected RED: extraction currently reads the mutable original URL after hashing/copying it.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Managed Bytes Matter")
        let source = sourceRoot.appendingPathComponent("mutable-source.txt")
        let original = Data("ORIGINAL-CANARY-42".utf8)
        let mutated = Data("MUTATED!-CANARY-42".utf8)
        try original.write(to: source)
        let storage = DocumentStorage(root: storageRoot) { stage in
            if stage == .afterSourceReadChunk { try mutated.write(to: source) }
        }
        let service = DocumentImportService(store: store, storage: storage, ocr: nil)

        let outcome = try await service.importSources([source], matterID: matter.id)

        let document = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        let blob = try XCTUnwrap(store.documentLibrary.fetchBlob(id: document.blobID))
        let managed = storage.url(forManagedRelativePath: blob.managedRelativePath)
        XCTAssertEqual(try Data(contentsOf: managed), original)
        XCTAssertEqual(blob.sha256, DocumentStorage.sha256Hex(of: original))
        XCTAssertEqual(blob.byteSize, original.count)
        XCTAssertEqual(blob.integrityStatus, DocumentBlobIntegrityStatus.verified.rawValue)
        XCTAssertEqual(document.extractedTextChecksum, blob.sha256, "the text fixture's extracted bytes must agree with the managed digest")
        XCTAssertEqual(outcome.report.importedCount, 1)
        XCTAssertEqual(try store.documentIndex.fetchParts(documentID: document.id).first?.normalizedText, "ORIGINAL-CANARY-42")
        XCTAssertFalse(try store.documentIndex.fetchParts(documentID: document.id).contains { $0.normalizedText.contains("MUTATED!") })
    }

    func testACRBLOB010DatabaseFailureLeavesValidOrphanAndNoBlobRow() async throws {
        // Expected RED: hash/copy/upsert ordering is not an explicit durable-orphan policy and is not reconciler-safe.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Database Failure Matter")
        let source = sourceRoot.appendingPathComponent("database-failure.txt")
        let bytes = Data("DATABASE-FAILURE-CANARY".utf8)
        try bytes.write(to: source)
        try await store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER acr_blob_insert_failure
                BEFORE INSERT ON document_blobs
                BEGIN SELECT RAISE(FAIL, 'ACR-BLOB database canary'); END
                """)
        }
        let storage = DocumentStorage(root: storageRoot)
        let service = DocumentImportService(store: store, storage: storage, ocr: nil)

        let outcome = try await service.importSources([source], matterID: matter.id)

        let digest = DocumentStorage.sha256Hex(of: bytes)
        let orphan = storage.blobURL(sha256: digest, fileExtension: "txt")
        XCTAssertEqual(outcome.report.failedCount, 1)
        XCTAssertNil(try store.documentLibrary.fetchBlob(sha256: digest))
        XCTAssertEqual(try Data(contentsOf: orphan), bytes, "valid content-addressed orphan should survive for reconciliation")
    }

    // MARK: - OCR warning hygiene (review finding: stale/contradictory warnings)

    func testSuccessfulOCRDropsStaleExtractorAdvisory() async throws {
        // Expected RED: assertion failure — after a healthy OCR (confidence 0.90, ample
        // recovered text) the persisted warnings still carry the extractor's pre-OCR
        // advisory, so the decoded array is exactly
        //   ["PDF has little embedded text; OCR recommended."]
        // instead of empty. The advisory recommends OCR that has already run, so both
        // `XCTAssertFalse(contains(advisory))` and `XCTAssertTrue(isEmpty)` fail.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let pdfURL = sourceRoot.appendingPathComponent("Scans/mixed-recovered.pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let richText = "Retainer agreement between McKernon Motors and outside counsel, "
            + "executed on 2024 01 15. This first page carries substantial embedded text so "
            + "the extractor keeps it as a text page; only the trailing blank page is routed "
            + "to OCR."
        try makePDF(at: pdfURL, pages: [.text(richText), .empty])

        // OCR recovers ample high-confidence text for the one blank page.
        let ocr = MockOCRService(pageResults: [
            1: OCRTextResult(text: "OCR recovered the full body text of the scanned second page for indexing.", confidence: 0.9)
        ])
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([pdfURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        // Healthy recovery: OCR ran, text is ample, confidence is high — not review.
        XCTAssertEqual(doc.status, MatterDocumentStatus.indexing.rawValue, "high-confidence recovered OCR is healthy, not review")

        // Post-fix a healthy result carries no warnings (nil JSON); tolerate either shape.
        let warnings: [String]
        if let warningsJSON = doc.extractionWarningsJSON {
            warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        } else {
            warnings = []
        }
        // The pre-OCR advisory recommends work that already happened — it must be dropped.
        XCTAssertFalse(
            warnings.contains("PDF has little embedded text; OCR recommended."),
            "the pre-OCR advisory must not survive a successful OCR; got \(warnings)"
        )
        // A healthy recovery carries no OCR warnings at all.
        XCTAssertTrue(warnings.isEmpty, "successful high-confidence OCR should leave no warnings; got \(warnings)")
    }

    func testEmptyOCRWarningIsSingleAndAccurate() async throws {
        // Expected RED: assertion failure — the persisted warnings stack three lines,
        //   ["PDF has little embedded text; OCR recommended.",
        //    "OCR confidence is low; verify the extracted text before relying on it.",
        //    "OCR produced no usable text; the original may be blank or illegible. Review the document."]
        // The extractor advisory is stale and the low-confidence line is nonsense (there
        // is no extracted text to verify), so the array is not the single accurate line.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let pdfURL = sourceRoot.appendingPathComponent("Scans/all-blank-warn.pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(at: pdfURL, pages: [.empty, .empty])

        let ocr = MockOCRService(pageResults: [
            0: OCRTextResult(text: "", confidence: 0),
            1: OCRTextResult(text: "", confidence: 0)
        ])
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([pdfURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue, "empty OCR still routes to review")

        let warningsJSON = try XCTUnwrap(doc.extractionWarningsJSON, "empty-OCR documents must record a review warning")
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertEqual(
            warnings,
            ["OCR produced no usable text; the original may be blank or illegible. Review the document."],
            "empty OCR should record exactly one accurate warning, with no stale advisory or low-confidence line; got \(warnings)"
        )
    }

    func testLittleTextOCRWarningIsAccurate() async throws {
        // Expected RED: assertion failure — the persisted warnings are
        //   ["Image requires OCR to extract text.",
        //    "OCR confidence is low; verify the extracted text before relying on it.",
        //    "OCR produced no usable text; the original may be blank or illegible. Review the document."]
        // OCR recovered 31 non-whitespace chars (> 0 but < 40), so the "no usable text"
        // line is factually wrong and the extractor advisory is stale.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let imageURL = sourceRoot.appendingPathComponent("Images/faint-notice.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-png-bytes".utf8).write(to: imageURL)

        // "Notice of default dated 2024-05-01." is 31 non-whitespace characters.
        let ocr = MockOCRService(imageResult: OCRTextResult(text: "Notice of default dated 2024-05-01.", confidence: 0.40))
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([imageURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue, "sparse OCR still routes to review")

        let warningsJSON = try XCTUnwrap(doc.extractionWarningsJSON, "sparse-OCR documents must record a review warning")
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertEqual(
            warnings,
            ["OCR recovered very little text; review the document before relying on it."],
            "little-text OCR should record exactly the little-text warning, with no stale advisory, low-confidence, or no-usable-text line; got \(warnings)"
        )
    }

    func testLowConfidenceWithUsableTextKeepsOnlyConfidenceWarning() async throws {
        // Expected RED: assertion failure — the persisted warnings are
        //   ["Image requires OCR to extract text.",
        //    "OCR confidence is low; verify the extracted text before relying on it."]
        // OCR recovered ample text (>= 40 non-whitespace chars) at low confidence, so the
        // low-confidence line is correct but the stale extractor advisory must be dropped.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let imageURL = sourceRoot.appendingPathComponent("Images/lowconf-notice.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-png-bytes".utf8).write(to: imageURL)

        // 67 non-whitespace characters — comfortably >= the 40-char usable-text floor.
        let ocr = MockOCRService(imageResult: OCRTextResult(
            text: "Notice of default and acceleration for the McKernon account dated 2024-05-01.",
            confidence: 0.30
        ))
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: ocr)
        _ = try await service.importSources([imageURL], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.needsReview.rawValue, "low-confidence OCR still routes to review")

        let warningsJSON = try XCTUnwrap(doc.extractionWarningsJSON, "low-confidence OCR must record a review warning")
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertEqual(
            warnings,
            ["OCR confidence is low; verify the extracted text before relying on it."],
            "low-confidence OCR with usable text should keep only the confidence warning, dropping the stale extractor advisory; got \(warnings)"
        )
    }

    // MARK: - Reprocess (re-extract from the managed blob)

    func testReprocessFailedDocumentReextractsAndRemarksFailedIdempotently() async throws {
        // Expected RED: compile error — `reprocessDocument(documentID:)` is not a member of
        // DocumentImportService.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        // A .docx whose bytes are not a zip: it passes type detection (no contradicting
        // signature) but the DOCX extractor throws `.malformed`, so the instance persists as
        // .failed with a valid managed blob. Reprocessing re-reads that same blob and fails
        // identically — the idempotent re-mark case.
        let corrupt = sourceRoot.appendingPathComponent("Broken/not-a-zip.docx")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "this is not a zip archive".write(to: corrupt, atomically: true, encoding: .utf8)
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        _ = try await service.importSources([corrupt], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        XCTAssertEqual(doc.status, MatterDocumentStatus.failed.rawValue, "precondition: a corrupt .docx imports as failed")
        XCTAssertEqual(doc.extractionStatus, DocumentExtractionStatus.failed.rawValue)

        // A prior (now-stale) classification is the observable proof that reprocess actually ran
        // even though the re-extraction fails again: reprocess clears the classification up front.
        try store.documentLibrary.updateClassification(documentID: doc.id, classificationMetadataJSON: #"{"primary_tag":"contracts_and_agreements"}"#)

        try await service.reprocessDocument(documentID: doc.id)

        let after = try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id))
        // Re-extraction fails the same way → the instance is re-marked .failed cleanly (idempotent).
        XCTAssertEqual(after.status, MatterDocumentStatus.failed.rawValue)
        XCTAssertEqual(after.extractionStatus, DocumentExtractionStatus.failed.rawValue)
        // Proof reprocess ran and left no partial state: classification cleared, no parts leaked.
        XCTAssertNil(after.classificationMetadataJSON, "reprocess must clear the stale classification")
        XCTAssertTrue(try store.documentIndex.fetchParts(documentID: doc.id).isEmpty, "a failed re-extraction must leave no parts")
    }

    func testReprocessHealthyDocumentClearsClassificationStalesIndexAndRepopulatesParts() async throws {
        // Expected RED: compile error — `reprocessDocument(documentID:)` is not a member of
        // DocumentImportService.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let service = DocumentImportService(store: store, storage: DocumentStorage(root: storageRoot), ocr: nil)
        _ = try await service.importSources([sourceRoot.appendingPathComponent("Contracts/agreement.txt")], matterID: matter.id)

        let doc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first)
        let partID = try XCTUnwrap(store.documentIndex.fetchParts(documentID: doc.id).first?.id)

        // Drive the doc into a fully-processed, classified, indexed state, then overwrite the
        // extracted text with a sentinel so a genuine re-extraction is observable.
        try store.documentLibrary.updateClassification(documentID: doc.id, classificationMetadataJSON: #"{"primary_tag":"contracts_and_agreements"}"#)
        try store.documentLibrary.updateIndexStatus(documentID: doc.id, indexStatus: .ready)
        try store.documentIndex.updatePartText(partID: partID, text: "STALE-SENTINEL-TEXT-DO-NOT-KEEP")

        try await service.reprocessDocument(documentID: doc.id)

        let after = try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id))
        XCTAssertNil(after.classificationMetadataJSON, "reprocess must clear the prior classification")
        XCTAssertEqual(after.indexStatus, DocumentIndexStatus.stale.rawValue, "reprocess must mark the index stale")
        XCTAssertEqual(after.status, MatterDocumentStatus.indexing.rawValue, "a healthy re-extraction returns the doc to .indexing")
        XCTAssertEqual(after.extractionStatus, DocumentExtractionStatus.extracted.rawValue)

        // Parts were repopulated from the managed blob — the stale sentinel is gone, replaced by
        // a fresh extraction of the original bytes.
        let repopulated = try store.documentIndex.fetchParts(documentID: doc.id)
        XCTAssertEqual(repopulated.count, 1)
        XCTAssertEqual(repopulated.first?.normalizedText, "Service agreement effective 2024-01-01.")
        XCTAssertFalse(repopulated.contains { $0.normalizedText.contains("STALE-SENTINEL") }, "the stale text must be replaced by the re-extraction")
    }
}

private struct EditReindexNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}

/// Deterministic OCR double. `recognizeImage` keeps the original single-result
/// behavior; `recognizePDFPages` returns `pageResults` (filtered to the requested
/// indices when a non-nil set is passed) and records every call's `pageIndices`
/// argument under an NSLock, following the StubRuntimeClient pattern.
private final class MockOCRService: DocumentOCRService, @unchecked Sendable {
    let imageResult: OCRTextResult
    let pageResults: [Int: OCRTextResult]
    private let lock = NSLock()
    private var _recordedPageIndices: [[Int]?] = []

    /// The `pageIndices` argument of every `recognizePDFPages` call, in call order.
    var recordedPageIndices: [[Int]?] {
        lock.withLock { _recordedPageIndices }
    }

    init(
        imageResult: OCRTextResult = OCRTextResult(text: "", confidence: 0),
        pageResults: [Int: OCRTextResult] = [:]
    ) {
        self.imageResult = imageResult
        self.pageResults = pageResults
    }

    func recognizeImage(at url: URL) async throws -> OCRTextResult { imageResult }

    func recognizePDFPages(at url: URL, pageIndices: [Int]?) async throws -> [Int: OCRTextResult] {
        lock.withLock { _recordedPageIndices.append(pageIndices) }
        guard let pageIndices else { return pageResults }
        return pageResults.filter { pageIndices.contains($0.key) }
    }
}

/// Page descriptor for the text-bearing `makePDF` fixture helper.
private enum PDFPageContent {
    case text(String)
    case empty
}
