import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentPreviewTests: XCTestCase {
    func testTextLocatorResolvesToHighlightedTextPreview() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "t", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/t.txt")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "note.txt"))
        let text = "Payment was due on March 3, 2024."
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])

        let loader = DocumentPreviewLoader(store: store, storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let model = loader.load(documentID: doc.id, locator: DocumentSourceLocator(sourceKind: .text, charStart: 0, charEnd: 7))
        XCTAssertEqual(model.documentName, "note.txt")
        if case let .text(content, start, end) = model.kind {
            XCTAssertEqual(content, text)
            XCTAssertEqual(start, 0)
            XCTAssertEqual(end, 7)
        } else {
            XCTFail("expected text kind, got \(model.kind)")
        }
    }

    func testMissingPDFBlobFallsBackToText() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "p", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/missing.pdf")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "scan.pdf"))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.pdfPage.rawValue, pageIndex: 0, normalizedText: "OCR text fallback.", charCount: 18)
        ])

        let loader = DocumentPreviewLoader(store: store, storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let model = loader.load(documentID: doc.id, locator: DocumentSourceLocator(sourceKind: .pdfPage, pageIndex: 0))
        if case let .unavailable(_, fallbackText) = model.kind {
            XCTAssertEqual(fallbackText, "OCR text fallback.")
        } else {
            XCTFail("expected unavailable fallback, got \(model.kind)")
        }
    }

    func testUnknownDocumentIsUnavailable() throws {
        let store = try makeStore()
        let loader = DocumentPreviewLoader(store: store, storage: DocumentStorage(root: FileManager.default.temporaryDirectory))
        let model = loader.load(documentID: "nope", locator: DocumentSourceLocator(sourceKind: .text))
        if case .unavailable = model.kind {} else { XCTFail("expected unavailable") }
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
