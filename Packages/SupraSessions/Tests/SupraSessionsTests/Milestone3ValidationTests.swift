import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Milestone 3 deterministic pipeline validation (plan §15.3, §15.5). Builds the
/// synthetic Validation Matter, runs import → OCR (mocked) → index (stub embedder)
/// → search → Q&A → chronology → export, and asserts the §15.5 gates — all without
/// a chat model.
@MainActor
final class Milestone3ValidationTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/tmp")
    private var storageRoot = URL(fileURLWithPath: "/tmp")

    func testFullPipelineOverFixtureMatterMeetsGates() async throws {
        try buildFixtureMatter()
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Validation Matter")
        let storage = DocumentStorage(root: storageRoot)
        let ocr = ValidationOCR()
        let embedder = ValidationEmbedder()

        // --- Import (continue-on-failure) ---
        let importer = DocumentImportService(store: store, storage: storage, ocr: ocr)
        let outcome = try await importer.importSources([root], matterID: matter.id)

        // Gate: import report accounts for every discovered file + attachment.
        let report = outcome.report
        XCTAssertGreaterThanOrEqual(report.discoveredCount, 14)
        // Gate: unsupported/corrupt files are reported, not silently skipped.
        XCTAssertTrue(report.items.contains { $0.disposition == DocumentImportDisposition.unsupported.rawValue })
        XCTAssertTrue(report.failedCount >= 1)

        let docs = try store.documentLibrary.fetchDocuments(matterID: matter.id)

        // Gate: recursive hierarchy preserved.
        let folderNames = Set(try store.documentLibrary.fetchFolders(matterID: matter.id).map(\.name))
        for expected in ["Contracts", "Emails", "Finance", "Notes", "Web", "Images", "Duplicates"] {
            XCTAssertTrue(folderNames.contains(expected), "missing folder \(expected)")
        }

        // Gate: duplicate content → one blob, multiple instances.
        let pdfInstances = docs.filter { $0.displayName.hasPrefix("service-agreement") }
        XCTAssertEqual(pdfInstances.count, 2)
        XCTAssertEqual(Set(pdfInstances.map(\.blobID)).count, 1)

        // Gate: email attachments become child documents.
        let email = try XCTUnwrap(docs.first { $0.displayName == "notice-thread.eml" })
        XCTAssertFalse(docs.filter { $0.parentDocumentID == email.id }.isEmpty)

        // Gate: originals not modified.
        let originalMD = try String(contentsOf: root.appendingPathComponent("Notes/intake-notes.md"), encoding: .utf8)
        XCTAssertTrue(originalMD.contains("Intake"))

        // Gate: extraction produced normalized text for born-digital + office formats.
        let docx = try XCTUnwrap(docs.first { $0.displayName == "termination-letter.docx" })
        XCTAssertTrue(try store.documentIndex.fetchParts(documentID: docx.id).first?.normalizedText.contains("Termination") ?? false)
        let xlsx = try XCTUnwrap(docs.first { $0.displayName == "invoice-summary.xlsx" })
        XCTAssertTrue(try store.documentIndex.fetchParts(documentID: xlsx.id).contains { $0.normalizedText.contains("Acme") })

        // Gate: OCR persisted with confidence for the image.
        let image = try XCTUnwrap(docs.first { $0.displayName == "scanned-notice.png" })
        XCTAssertEqual(image.extractionStatus, DocumentExtractionStatus.ocrComplete.rawValue)
        XCTAssertNotNil(image.ocrConfidenceSummary)

        // --- Index ---
        let indexer = DocumentIndexingService(store: store, embedder: embedder)
        _ = try await indexer.indexMatter(matterID: matter.id)

        // Gate: FTS finds exact terms; chunks have stable locators.
        let hits = try store.documentIndex.searchChunks(matterID: matter.id, query: "indemnification")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertNotNil(hits.first?.chunkIndex)

        // Gate: source links resolve to a preview target.
        let preview = DocumentPreviewLoader(store: store, storage: storage)
            .load(documentID: hits[0].documentID, locator: DocumentSourceLocator(sourceKind: DocumentSourceKind(rawValue: hits[0].sourceKind) ?? .text, pageIndex: hits[0].pageIndex, charStart: hits[0].charStart, charEnd: hits[0].charEnd))
        if case .unavailable(let reason, _) = preview.kind {
            XCTFail("preview unavailable: \(reason)")
        }

        // Gate: soft-delete removes a doc from search; restore brings it back.
        let witness = try XCTUnwrap(docs.first { $0.displayName == "witness-notes.txt" })
        try store.documentLibrary.softDeleteDocument(id: witness.id)
        XCTAssertTrue(try store.documentIndex.searchChunks(matterID: matter.id, query: "deposition").isEmpty)
        try store.documentLibrary.restoreDocument(id: witness.id)

        // --- Q&A (stub model, cited) ---
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: "Indemnification survives termination [S1]."), .event(request, 1, .generationCompleted)])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: embedder)
        let qaGen = await qa.generate(question: "Does indemnification survive termination?", modelID: ModelID())
        let qaResult = try XCTUnwrap(qaGen)
        // Gate: Q&A has no unresolved citation ids.
        let qaSources = try store.documentSources.fetchSources(structuredOutputVersionID: qaResult.versionID)
        XCTAssertTrue(qaResult.citationLabels.allSatisfy { label in qaSources.contains { $0.citationLabel == label } })

        // --- Chronology (stub model) ---
        let chronoRuntime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-03-03 | Agreement executed [S1] | [S1] |"), .event(request, 1, .generationCompleted)])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: chronoRuntime)
        let chronoGen = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        let chronoResult = try XCTUnwrap(chronoGen)
        let chronoSources = try store.documentSources.fetchSources(structuredOutputVersionID: chronoResult.versionID)
        XCTAssertFalse(chronoSources.isEmpty)

        // --- Export (all formats; output + appendix, no raw docs) ---
        let exporter = DocumentExportService(store: store, storage: storage)
        for format in DocumentExportFormat.allCases {
            let url = try exporter.export(matterID: matter.id, structuredOutputID: qaResult.outputID, format: format)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let mdURL = try exporter.export(matterID: matter.id, structuredOutputID: qaResult.outputID, format: .markdown)
        XCTAssertTrue(try String(contentsOf: mdURL, encoding: .utf8).contains("## Sources"))

        // Gate: major audit events recorded.
        let events = Set(try store.auditEvents.fetchEvents(matterID: matter.id).map(\.eventType))
        XCTAssertTrue(events.contains("qa_generated"))
        XCTAssertTrue(events.contains("chronology_generated"))
        XCTAssertTrue(events.contains("export_completed"))
        XCTAssertTrue(events.contains { $0.hasPrefix("document_import_completed") })
    }

    // MARK: - Fixture authoring

    private func buildFixtureMatter() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("M3Validation-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Validation Matter", isDirectory: true)
        storageRoot = base.appendingPathComponent("Storage", isDirectory: true)

        // Born-digital PDF (real, via the export builder) + a byte-identical copy.
        let pdfURL = try mk("Contracts/service-agreement.pdf")
        try DocumentExportBuilder.write(
            DocumentExportPayload(title: "Service Agreement", contentMarkdown: "Indemnification survives termination. Executed March 3, 2024.", reviewWarning: "", sources: []),
            format: .pdf, to: pdfURL
        )
        try FileManager.default.copyItem(at: pdfURL, to: try mk("Duplicates/service-agreement-copy.pdf"))

        // DOCX + DOTX (real OOXML via the export builder).
        try DocumentExportBuilder.write(DocumentExportPayload(title: "Termination Letter", contentMarkdown: "This Termination Letter is effective March 3, 2024.", reviewWarning: "", sources: []), format: .docx, to: try mk("Contracts/termination-letter.docx"))
        try DocumentExportBuilder.write(DocumentExportPayload(title: "Notice Template", contentMarkdown: "Notice template body.", reviewWarning: "", sources: []), format: .docx, to: try mk("Contracts/notice-template.dotx"))
        // XLSX (real OOXML).
        try DocumentExportBuilder.write(DocumentExportPayload(title: "Invoices", contentMarkdown: "x", reviewWarning: "", sources: [.init(label: "S1", documentName: "Acme Corp", locator: "Invoice", excerpt: "5000")]), format: .xlsx, to: try mk("Finance/invoice-summary.xlsx"))

        // Text-family fixtures.
        try "# Intake\n\nClient: Acme Corp. Wire transfer discussed.".write(to: try mk("Notes/intake-notes.md"), atomically: true, encoding: .utf8)
        try "The deposition referenced a wire transfer on March 5, 2024.".write(to: try mk("Notes/witness-notes.txt"), atomically: true, encoding: .utf8)
        try #"{\rtf1\ansi Retainer note.\par}"#.write(to: try mk("Notes/rich-text-note.rtf"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Archived</h1><p>Filed 2024-01-10.</p></body></html>".write(to: try mk("Web/archived-page.html"), atomically: true, encoding: .utf8)
        try "<doc author=\"Jane Roe\"><note>Metadata 2023</note></doc>".write(to: try mk("Web/metadata.xml"), atomically: true, encoding: .utf8)

        // Email with a base64 attachment.
        let attachment = Data("Attached termination notice dated March 3, 2024.".utf8).base64EncodedString()
        let eml = """
        From: counsel@example.com
        To: client@example.com
        Subject: Notice of Termination
        Date: Wed, 3 Apr 2024 10:00:00 +0000
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Please see the attached notice. Indemnification applies.
        --B
        Content-Type: text/plain
        Content-Disposition: attachment; filename="attached-notice.txt"
        Content-Transfer-Encoding: base64

        \(attachment)
        --B--
        """
        try eml.write(to: try mk("Emails/notice-thread.eml"), atomically: true, encoding: .utf8)

        // Image for OCR (bytes arbitrary; OCR is mocked).
        try Data("png-bytes".utf8).write(to: try mk("Images/scanned-notice.png"))

        // Failure / unsupported fixtures.
        try "binary-junk".write(to: try mk("Finance/legacy-ledger.xls"), atomically: true, encoding: .utf8)
        try "ole-junk".write(to: try mk("Emails/board-approval.msg"), atomically: true, encoding: .utf8)
        try "not a zip".write(to: try mk("Unsupported-Or-Bad/corrupt-file.docx"), atomically: true, encoding: .utf8)
    }

    private func mk(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("M3ValStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }
}

/// Mocked OCR returning deterministic text + low-ish confidence for validation.
private struct ValidationOCR: DocumentOCRService {
    func recognizeImage(at url: URL) async throws -> OCRTextResult {
        OCRTextResult(text: "Scanned notice of default dated April 1, 2024.", confidence: 0.82)
    }
    func recognizePDFPages(at url: URL, pageIndices: [Int]?) async throws -> [Int: OCRTextResult] {
        [0: OCRTextResult(text: "Scanned page text.", confidence: 0.82)]
    }
}

/// Deterministic bag-of-words embedder for validation retrieval.
private struct ValidationEmbedder: TextEmbedder {
    let modelID = "val-bow"
    let modelDisplayName = "Validation BoW"
    let modelRevision: String? = nil
    let dimension = 64
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            for token in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where token.count >= 2 {
                var hash: UInt64 = 1469598103934665603
                for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
                vector[Int(hash % 64)] += 1
            }
            return vector
        }
    }
}
