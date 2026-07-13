import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentChronologyTests: XCTestCase {

    func testTableChronologyUsesScopeOnlyDatedFactsWithCitations() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contracts = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let notes = try store.documentLibrary.createFolder(matterID: matter.id, name: "Notes")

        try await indexDoc(store, matter.id, contracts.id, "agreement.txt", "The agreement was executed on March 3, 2024 and amended in July 2024.")
        try await indexDoc(store, matter.id, notes.id, "intake.txt", "Counsel met the client on January 5, 2024 about the dispute.")

        // The model echoes a chronology citing the provided sources.
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-01-05 | Counsel met client [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })

        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        // Narrative from the Notes folder only: must not include the contract date.
        let notesResult = try XCTUnwrapAsync(await chronology.generate(scope: RetrievalScope(folderIDs: [notes.id]), format: .narrative, modelID: ModelID()))
        XCTAssertEqual(notesResult.status, StructuredOutputStatus.complete.rawValue)
        // The source set for the notes-only chronology references only the notes doc.
        let notesSources = try store.documentSources.fetchSources(structuredOutputVersionID: notesResult.versionID)
        XCTAssertFalse(notesSources.isEmpty)
        let notesDoc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "intake.txt" })
        XCTAssertTrue(notesSources.allSatisfy { $0.documentID == notesDoc.id })

        // Whole-matter table chronology references both documents.
        let allResult = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))
        let allOutput = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first { $0.id == allResult.outputID })
        XCTAssertEqual(allOutput.outputType, StructuredOutputType.factChronologyTable.rawValue)
        let allSources = try store.documentSources.fetchSources(structuredOutputVersionID: allResult.versionID)
        XCTAssertEqual(Set(allSources.map(\.documentID)).count, 2)
    }

    func testRegenerateCreatesNewVersionWithFreshSourceSet() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, nil, "a.txt", "Agreement executed March 3, 2024.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-03-03 | Executed [S1] | [S1] |"), .event(request, 1, .generationCompleted)])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let first = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        let firstResult = try XCTUnwrap(first)
        let regen = await chronology.regenerate(outputID: firstResult.outputID, modelID: ModelID())
        let regenResult = try XCTUnwrap(regen)

        // Same output, new version, with its own attached source set.
        XCTAssertEqual(regenResult.outputID, firstResult.outputID)
        XCTAssertNotEqual(regenResult.versionID, firstResult.versionID)
        XCTAssertEqual(try store.structuredOutputs.fetchVersions(structuredOutputID: firstResult.outputID).count, 2)
        XCTAssertFalse(try store.documentSources.fetchSources(structuredOutputVersionID: regenResult.versionID).isEmpty)
    }

    func testChronologyUsesStructuredOutputRouteOptionsAndPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, nil, "timeline.txt", "The amendment was signed on July 9, 2024.")
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertEqual(request.options.preset, .legalResearch)
            XCTAssertTrue(request.systemPrompt?.contains("legal document analysis assistant") ?? false)
            return .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-07-09 | Amendment signed [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generated = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())

        XCTAssertNotNil(generated)
    }

    func testUnsupportedChronologyCannotBecomeComplete() async throws {
        // ACR-DOCSUP-INT-04 expected RED: a resolved S1 currently marks the chronology
        // complete even when its proposition is absent from the cited source.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(store, matter.id, nil, "timeline.txt", "A status conference occurred January 5, 2025.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2025-09-09 | Judgment entered [S1] | [S1] |"),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generated = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertNotNil(version.verificationJSON)
    }

    func testDateExtractionDetectsCommonForms() {
        XCTAssertTrue(DateExtraction.containsDate("Signed on March 3, 2024."))
        XCTAssertTrue(DateExtraction.containsDate("2024-03-03 filing"))
        XCTAssertTrue(DateExtraction.containsDate("Due 3/3/2024"))
        XCTAssertTrue(DateExtraction.containsDate("Closed in 2023"))
        XCTAssertFalse(DateExtraction.containsDate("No dates here at all."))
    }

    // MARK: - Helpers

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ folderID: String?, _ name: String, _ text: String) async throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name)")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: folderID, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: doc.id)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
