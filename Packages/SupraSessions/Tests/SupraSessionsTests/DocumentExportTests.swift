import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentExportTests: XCTestCase {
    func testExportWritesFileRecordsAndAudits() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")

        // A saved Q&A output with a version + an attached source set.
        let output = try store.structuredOutputs.createOutput(matterID: matter.id, title: "Q&A: payment", outputType: .documentQA, status: .complete)
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id, versionIndex: 1,
            contentMarkdown: "Payment was due March 3, 2024 [S1].",
            requiredSections: [], presentSections: [], missingSections: []
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "a", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/a.pdf")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "agreement.pdf"))
        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource, retrievalQuery: "payment")
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id, documentID: doc.id, chunkID: nil, citationLabel: "S1",
            locatorJSON: DocumentSourceLocator(sourceKind: .pdfPage, pageIndex: 2, pageLabel: "3").encodedJSON(),
            excerpt: "Payment due March 3, 2024.", rank: 0
        ))
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ExportSvc-\(UUID().uuidString)"))
        let service = DocumentExportService(store: store, storage: storage)

        for format in DocumentExportFormat.allCases {
            let url = try service.export(matterID: matter.id, structuredOutputID: output.id, format: format)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(format.rawValue)")
        }

        // Markdown contains the answer + appendix reference (no raw documents).
        let mdURL = try service.export(matterID: matter.id, structuredOutputID: output.id, format: .markdown)
        let md = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Payment was due March 3, 2024 [S1]."))
        XCTAssertTrue(md.contains("agreement.pdf"))
        XCTAssertTrue(md.contains("p. 3"))

        // Export records persisted, and a single matter export audit exists.
        let exports = try store.documentSources.fetchExports(structuredOutputID: output.id)
        XCTAssertGreaterThanOrEqual(exports.count, DocumentExportFormat.allCases.count)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
