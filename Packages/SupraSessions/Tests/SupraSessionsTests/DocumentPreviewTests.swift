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

    func testTREV06CitationPreviewResolvesRecordedRevisionAndLabelsLegacyUnknown() throws {
        // T-REV-06 expected RED: output-source rows have no revision binding and
        // DocumentPreviewLoader always substitutes the part's current text.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic revision preview")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "revision-preview-sha",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/revision-preview.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "revision-preview.txt"
        ))
        let part = DocumentPagePartRecord(
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: "REVISION-A repeated anchor",
            charCount: 26
        )
        try store.documentIndex.replaceParts(documentID: document.id, parts: [part])
        let revisionA = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "preview-revision-a",
            origin: "parser",
            method: "synthetic",
            text: "REVISION-A repeated anchor",
            charCount: 26
        ))
        _ = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revisionA.id,
            selectionKey: "preview-selection-a",
            selectedBy: "policy",
            policyVersion: 1,
            decisionJSON: #"{"selected":"A"}"#
        ))
        let locator = DocumentSourceLocator(
            sourceKind: .text,
            charStart: 0,
            charEnd: 10
        )
        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource)
        let boundSource = DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.id,
            revisionID: revisionA.id,
            citationLabel: "S1",
            locatorJSON: locator.encodedJSON(),
            excerpt: "REVISION-A",
            rank: 0
        )
        try store.documentSources.addOutputSource(boundSource)

        let revisionB = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "preview-revision-b",
            origin: "user_edit",
            method: "manual",
            text: "REVISION-B repeated anchor",
            charCount: 26,
            author: "Synthetic Reviewer",
            reason: "Correction",
            supersedesRevisionID: revisionA.id
        ))
        _ = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revisionB.id,
            selectionKey: "preview-selection-b",
            selectedBy: "user",
            policyVersion: 1,
            decisionJSON: #"{"selected":"B"}"#
        ))

        let loader = DocumentPreviewLoader(
            store: store,
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
        let recorded = loader.load(outputSource: boundSource)
        XCTAssertEqual(recorded.revisionID, revisionA.id)
        XCTAssertEqual(recorded.revisionOrigin, "parser")
        XCTAssertEqual(recorded.revisionCreatedAt, revisionA.createdAt)
        XCTAssertNotNil(recorded.revisionNotice)
        XCTAssertTrue(recorded.revisionNotice?.contains("parser") == true)
        if case let .text(content, start, end) = recorded.kind {
            XCTAssertEqual(content, "REVISION-A repeated anchor")
            XCTAssertEqual(start, 0)
            XCTAssertEqual(end, 10)
            XCTAssertFalse(content.contains("REVISION-B"))
        } else {
            XCTFail("expected revision-bound text preview, got \(recorded.kind)")
        }

        let legacySource = DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.id,
            revisionID: nil,
            citationLabel: "S2",
            locatorJSON: locator.encodedJSON(),
            excerpt: "historical excerpt",
            rank: 1
        )
        let legacy = loader.load(outputSource: legacySource)
        XCTAssertNil(legacy.revisionID)
        XCTAssertEqual(legacy.revisionNotice, "revision unknown (pre-lineage)")
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
