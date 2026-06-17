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

    func testRecursiveImportPreservesHierarchyDedupsAndExpandsAttachments() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme v. Roe")
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
        let matter = try store.matters.createMatter(name: "Acme v. Roe")
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
        try service.updateExtractedText(documentID: doc.id, partID: parts[0].id, text: "Notice of default dated May 1, 2024.")
        let edited = try XCTUnwrap(store.documentLibrary.fetchDocument(id: doc.id))
        XCTAssertEqual(edited.indexStatus, DocumentIndexStatus.stale.rawValue)
        XCTAssertTrue(edited.hasUserEditedText)
        XCTAssertEqual(try store.documentIndex.fetchParts(documentID: doc.id).first?.normalizedText, "Notice of default dated May 1, 2024.")
    }

    func testEditedTextMarksDocumentStaleForReindex() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme v. Roe")
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
}

private struct MockOCRService: DocumentOCRService {
    let imageResult: OCRTextResult
    func recognizeImage(at url: URL) async throws -> OCRTextResult { imageResult }
    func recognizePDFPages(at url: URL, pageIndices: [Int]?) async throws -> [Int: OCRTextResult] {
        [0: imageResult]
    }
}
