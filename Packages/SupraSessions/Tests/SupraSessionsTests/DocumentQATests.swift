import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentQATests: XCTestCase {

    func testRerankOrderPrefersModelLabelsThenBackfillsInRetrievalOrder() {
        let retrieval = (1...5).map { "S\($0)" } // S1…S5
        // Model prefers S3 then S1; the unknown S9 is ignored; the remaining slot is
        // backfilled in retrieval order (S2).
        XCTAssertEqual(
            DocumentQAController.rerankOrder(retrievalLabels: retrieval, preferred: ["S3", "S9", "S1"], limit: 3),
            ["S3", "S1", "S2"]
        )
    }

    func testRerankOrderFallsBackToRetrievalOrderWhenNoValidPreferred() {
        XCTAssertEqual(
            DocumentQAController.rerankOrder(retrievalLabels: ["S1", "S2", "S3"], preferred: [], limit: 2),
            ["S1", "S2"]
        )
    }

    func testParsePacketLabelsExtractsSLabels() {
        XCTAssertEqual(DocumentQAController.parsePacketLabels("Most relevant: S3, s1, S12."), ["S3", "S1", "S12"])
        XCTAssertTrue(DocumentQAController.parsePacketLabels("no labels here").isEmpty)
        // Digit-bearing words echoed from the question/excerpts must not yield labels.
        XCTAssertTrue(DocumentQAController.parsePacketLabels("Windows10 and class3 and FAS123").isEmpty)
    }

    func testAutoSourceQAGeneratesCitedAnswerSavedWithSourceSet() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024 by both parties.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "The agreement was signed on March 3, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was the agreement signed?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(result.citationLabels, ["S1"])
        XCTAssertFalse(result.unsupported)
        XCTAssertTrue(result.markdown.contains("## Sources"))

        // Saved as a documentQA structured output with an attached source set.
        let outputs = try store.structuredOutputs.fetchOutputs(matterID: matter.id)
        let output = try XCTUnwrap(outputs.first { $0.id == result.outputID })
        XCTAssertEqual(output.outputType, StructuredOutputType.documentQA.rawValue)
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.versionID)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.citationLabel, "S1")
        XCTAssertNotNil(sources.first?.chunkID)
    }

    func testUnsupportedQuestionDoesNotInventAnswer() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, "note.txt", "The deposition discussed the wire transfer schedule.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "The provided sources do not support an answer to this question."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)
        let generated = await qa.generate(question: "What is the indemnification cap?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertTrue(result.unsupported)
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
    }

    func testDocumentQAUsesStructuredOutputRouteOptionsAndPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, "agreement.txt", "The agreement required notice by May 1, 2024.")

        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertEqual(request.options.preset, .legalResearch)
            XCTAssertFalse(request.systemPrompt?.contains("legal authorities") ?? true)
            XCTAssertTrue(request.systemPrompt?.contains("legal document analysis assistant") ?? false)
            return .events([
                .event(request, 0, .token, token: "Notice was required by May 1, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was notice required?", modelID: ModelID())

        XCTAssertNotNil(generated)
    }

    func testMissingCitationsMarkNeedsReview() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, "a.txt", "Damages were assessed at fifty thousand dollars.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "Damages were fifty thousand dollars."), // no citation
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)
        let generated = await qa.generate(question: "What were the damages?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(result.warnings.contains { $0.contains("no inline citations") })
    }

    func testGeneratingBlockedWhenScopeNotIndexed() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // Insert a doc but do NOT index it.
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "z", byteSize: 1, originalExtension: "txt", managedRelativePath: "b/z.txt")).blob
        _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "x.txt", status: MatterDocumentStatus.extracting.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue))

        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: StubRuntimeClient(), embedder: nil)
        let result = await qa.generate(question: "anything?", modelID: ModelID())
        XCTAssertNil(result)
        XCTAssertNotNil(qa.message)
    }

    // MARK: - Helpers

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ name: String, _ text: String) async throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name)")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])
        // Index text-only (no embedder) so the scope is ready for FTS retrieval.
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: doc.id)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QAStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
