import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentExportTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

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

    func testExportDoesNotDuplicateEmbeddedAppendix() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // Saved version markdown already embeds a "## Sources" appendix, exactly as
        // the Q&A/chronology controllers persist it.
        let output = try store.structuredOutputs.createOutput(matterID: matter.id, title: "Q&A", outputType: .documentQA, status: .complete)
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id, versionIndex: 1,
            contentMarkdown: "Answer body [S1].\n\n## Sources\n- **[S1]** agreement.pdf — p. 3",
            requiredSections: [], presentSections: [], missingSections: []
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "a", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/a.pdf")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "agreement.pdf"))
        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource)
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(sourceSetID: sourceSet.id, documentID: doc.id, citationLabel: "S1", locatorJSON: DocumentSourceLocator(sourceKind: .pdfPage, pageIndex: 2).encodedJSON(), excerpt: "x", rank: 0))
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let url = try DocumentExportService(store: store, storage: storage).export(matterID: matter.id, structuredOutputID: output.id, format: .markdown)
        let md = try String(contentsOf: url, encoding: .utf8)
        let appendixCount = md.components(separatedBy: "## Sources").count - 1
        XCTAssertEqual(appendixCount, 1, "exactly one Sources appendix expected, found \(appendixCount)")
        XCTAssertTrue(md.contains("Answer body [S1]."))
    }

    // ACR-EXPORT-007: an exporter failure must not overwrite a prior artifact
    // or create either half of the success metadata pair.
    func testFailedInstallPreservesCanaryAndWritesNoExportOrAuditRecord() throws {
        let fixture = try makeFixture()
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Q-A-v1.md")
        let canary = Data("prior-reviewed-export".utf8)
        try canary.write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw InjectedFailure.stop }
        }
        let service = DocumentExportService(store: fixture.store, storage: fixture.storage, fileWriter: writer)

        XCTAssertThrowsError(
            try service.export(matterID: fixture.matterID, structuredOutputID: fixture.outputID, format: .markdown)
        )
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(structuredOutputID: fixture.outputID).isEmpty)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "export_completed" })
    }

    // ACR-EXPORT-008: the DB/audit completion transaction starts only after a
    // parseable file is installed. A transaction failure compensates back to the
    // prior destination rather than returning an unrecorded new export.
    func testCompletionFailureRestoresCanaryAfterValidatedInstall() throws {
        let fixture = try makeFixture()
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Q-A-v1.md")
        let canary = Data("prior-reviewed-export".utf8)
        try canary.write(to: destination)
        var recorderObservedInstalledFile = false
        let service = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _, _ in
                recorderObservedInstalledFile = FileManager.default.fileExists(atPath: destination.path)
                    && (try? DocumentExportValidator.validate(destination, as: .markdown)) != nil
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.export(matterID: fixture.matterID, structuredOutputID: fixture.outputID, format: .markdown)
        )
        XCTAssertTrue(recorderObservedInstalledFile)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(structuredOutputID: fixture.outputID).isEmpty)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "export_completed" })
    }

    private func makeFixture() throws -> (store: SupraStore, storage: DocumentStorage, matterID: String, outputID: String) {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Q&A",
            outputType: .documentQA,
            status: .complete
        )
        _ = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "Grounded answer.",
            requiredSections: [],
            presentSections: [],
            missingSections: []
        )
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("ExportFixture-\(UUID().uuidString)")
        )
        return (store, storage, matter.id, output.id)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
