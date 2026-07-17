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

    // MARK: - W3.0 harvest fix (batched-chronology work order, Phase 1)

    func testMetadataDatesDoNotStarveTextChunks() async throws {
        // Every document carries BOTH a metadata date AND one dated text chunk.
        // Today `harvestSources` appends each document's metadata-date source
        // UNCONDITIONALLY — ahead of the `maxSources` cap that only text chunks are
        // checked against — so with enough metadata-dated documents the uncapped
        // metadata sources consume the budget and dated text chunks are dropped.
        //
        // Expected RED: with the default 30-source cap and 35 documents, the metadata
        // and text sources interleave per document, so only 15 documents' dated text
        // chunks survive before the cap fills (the other 20 are dropped) — the
        // text-chunk source count (15) is NOT equal to the document count (35).
        //
        // NOTE ON THE ASSERTION (deviation, see report): the work order phrased this
        // as "assert at least one text-chunk source survives", expecting zero
        // survivors. Because metadata and chunks interleave per document, the first
        // ~15 chunks always slip in before the cap fills, so a bare "≥ 1" assertion is
        // already GREEN and cannot observe the bug. The genuine behavioral RED for
        // this exact fixture is "no dated chunk is starved" → text-chunk count equals
        // document count. The W3.0 fix routes metadata sources through the same cap
        // and raises the default cap to 1,000, letting every dated chunk survive
        // (35 == 35, GREEN).
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        for i in 1...35 {
            let name = String(format: "mckernon-record-%02d.txt", i)
            try await indexDoc(
                store, matter.id, nil, name,
                "McKernon Motors record \(i): brake inspection dated 2024-03-03.",
                metadataCreatedAt: Date(timeIntervalSince1970: 1_500_000_000 + Double(i) * 86_400)
            )
        }

        // Any valid table answer; the assertion is on the persisted source packet.
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-03-03 | Brake inspection [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        // Default maxSources (30) — the cap under test.
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        let docCount = try store.documentLibrary.fetchDocuments(matterID: matter.id).count
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.versionID)
        // Metadata-date rows carry no chunkID; text-chunk rows do.
        let metadataSources = sources.filter { $0.chunkID == nil }
        let textChunkSources = sources.filter { $0.chunkID != nil }

        // Precondition: metadata-date seeding wired one metadata source per document.
        // A failure here means the harness could not seed `metadataCreatedAt`, not
        // that the feature is (in)correct.
        XCTAssertEqual(metadataSources.count, docCount, "each seeded document should contribute one metadata-date source")
        // Invariant under test: metadata dates must not starve dated text chunks.
        XCTAssertEqual(textChunkSources.count, docCount, "every document's dated text chunk should survive the harvest; got \(textChunkSources.count) of \(docCount)")
    }

    func testOmittedDocumentNamesAppearInMessage() async throws {
        // Six distinctively named documents, each with one dated text chunk, over a
        // small explicit cap of 3. The first three (alphabetically) survive; the last
        // three are omitted.
        //
        // Expected RED: the omission message is the aggregate "Chronology covers 3 of
        // 6 dated sources; the rest were omitted…" string, which names no documents,
        // so it does not contain any omitted document's display name. The W3.0 fix
        // makes produce() name up to five omitted documents in the message.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        // Alphabetical order determines survival: a/b/c survive (cap 3); d/e/w omitted.
        try await indexDoc(store, matter.id, nil, "amended-complaint.txt", "McKernon Motors amended complaint filed 2023-11-02.")
        try await indexDoc(store, matter.id, nil, "brake-failure-analysis.txt", "Brake failure analysis dated 2023-11-05.")
        try await indexDoc(store, matter.id, nil, "correspondence-liberty-rail.txt", "Correspondence with Liberty Rail on 2023-11-09.")
        try await indexDoc(store, matter.id, nil, "deposition-calloway.txt", "Deposition of Calloway taken 2023-11-14.")
        try await indexDoc(store, matter.id, nil, "expert-report-metallurgy.txt", "Metallurgy expert report dated 2023-11-20.")
        try await indexDoc(store, matter.id, nil, "warranty-terms-mckernon.txt", "Warranty terms executed 2023-11-27.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2023-11-02 | Complaint filed [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        // Explicit small cap so only three of six dated chunks survive.
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime, maxSources: 3)

        // Unwrapping the result proves generation actually ran (and set `message` via
        // the real omission path) instead of bailing early into an unrelated message.
        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        let message = try XCTUnwrap(chronology.message)
        // "deposition-calloway.txt" is the first omitted document (4th alphabetically).
        XCTAssertTrue(
            message.contains("deposition-calloway.txt"),
            "omission message should name an omitted document; got: \(message)"
        )
    }

    // MARK: - Helpers

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ folderID: String?, _ name: String, _ text: String, metadataCreatedAt: Date? = nil) async throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name)")).blob
        // `metadataCreatedAt` is persisted verbatim on insert; indexing only touches
        // index/status columns, so a seeded metadata date survives to the harvest.
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: folderID, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            metadataCreatedAt: metadataCreatedAt
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
