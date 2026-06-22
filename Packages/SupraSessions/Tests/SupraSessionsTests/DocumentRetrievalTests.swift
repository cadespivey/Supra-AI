import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentRetrievalTests: XCTestCase {

    func testIndexingThenHybridRetrievalWithFiltersAndDuplicateCollapse() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme v. Roe")
        let contracts = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let duplicates = try store.documentLibrary.createFolder(matterID: matter.id, name: "Duplicates")
        let notes = try store.documentLibrary.createFolder(matterID: matter.id, name: "Notes")

        // Two identical "agreement" instances (duplicate content) + a distinct note.
        let agreementText = "The indemnification clause survives termination of the service agreement."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "agree", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/agree.txt")).blob
        let docA = try makeDocument(store, matter.id, blob.id, contracts.id, "agreement.txt", agreementText)
        let docB = try makeDocument(store, matter.id, blob.id, duplicates.id, "agreement-copy.txt", agreementText)
        let noteBlob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "note", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/note.txt")).blob
        let docNote = try makeDocument(store, matter.id, noteBlob.id, notes.id, "intake.txt", "Client met with witness about the wire transfer on March 3.")

        let embedder = BagOfWordsEmbedder()
        let indexer = DocumentIndexingService(store: store, embedder: embedder)

        // Before indexing, scope is not ready (gating).
        let beforeReadiness = try DocumentRetrievalService(store: store, embedder: embedder).scopeReadiness(matterID: matter.id, scope: .wholeMatter)
        XCTAssertFalse(beforeReadiness.isFullyReady)

        let indexed = try await indexer.indexMatter(matterID: matter.id)
        XCTAssertEqual(indexed, 3)

        let retrieval = DocumentRetrievalService(store: store, embedder: embedder)

        // After indexing, scope is fully ready.
        XCTAssertTrue(try retrieval.scopeReadiness(matterID: matter.id, scope: .wholeMatter).isFullyReady)

        // Whole-matter query for "indemnification" → one collapsed source noting the duplicate.
        let result = try await retrieval.retrieve(matterID: matter.id, query: "indemnification clause", scope: .wholeMatter)
        XCTAssertTrue(result.usedSemantic)
        let indemnificationSources = result.sources.filter { $0.text.contains("indemnification") }
        XCTAssertEqual(indemnificationSources.count, 1, "duplicate content should collapse to one source")
        XCTAssertFalse(indemnificationSources.first?.duplicateLocations.isEmpty ?? true, "duplicate location should be noted")
        XCTAssertNil(result.incompleteScopeWarning)

        // Folder filter restricts the scope.
        let notesOnly = try await retrieval.retrieve(matterID: matter.id, query: "wire transfer", scope: RetrievalScope(folderIDs: [notes.id]))
        XCTAssertTrue(notesOnly.sources.allSatisfy { $0.documentID == docNote.id })
        XCTAssertTrue(notesOnly.sources.contains { $0.text.contains("wire transfer") })

        // A query only present in the notes returns nothing from the contracts scope.
        let contractsOnly = try await retrieval.retrieve(matterID: matter.id, query: "wire transfer", scope: RetrievalScope(folderIDs: [contracts.id]))
        XCTAssertTrue(contractsOnly.sources.isEmpty)

        _ = docA; _ = docB
    }

    func testTextOnlyReadinessWhenNoEmbedder() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "x", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/x.txt")).blob
        _ = try makeDocument(store, matter.id, blob.id, nil, "a.txt", "Some indexable content about damages.")

        let indexer = DocumentIndexingService(store: store, embedder: nil)
        _ = try await indexer.indexMatter(matterID: matter.id)

        // No embedder → text-indexed counts as ready, and FTS retrieval works.
        let retrieval = DocumentRetrievalService(store: store, embedder: nil)
        XCTAssertTrue(try retrieval.scopeReadiness(matterID: matter.id, scope: .wholeMatter).isFullyReady)
        let result = try await retrieval.retrieve(matterID: matter.id, query: "damages", scope: .wholeMatter)
        XCTAssertFalse(result.usedSemantic)
        XCTAssertTrue(result.sources.contains { $0.text.contains("damages") })
    }

    func testRRFContributionRewardsTopRanksAndDualMatches() {
        XCTAssertGreaterThan(
            DocumentRetrievalService.rrfContribution(rank: 1),
            DocumentRetrievalService.rrfContribution(rank: 2)
        )
        // A chunk ranked #3 in BOTH lists should beat one ranked #1 in a single list.
        let dual = DocumentRetrievalService.rrfContribution(rank: 3) + DocumentRetrievalService.rrfContribution(rank: 3)
        XCTAssertGreaterThan(dual, DocumentRetrievalService.rrfContribution(rank: 1))
    }

    func testExpandedChunkTextIncludesSamePartNeighbors() {
        let chunks = (0..<3).map { i in
            DocumentChunkRecord(id: "c\(i)", documentID: "d", pagePartID: "p1", chunkIndex: i, sourceKind: "text", normalizedText: "chunk\(i)")
        }
        // Middle chunk pulls in both neighbors, in reading order.
        XCTAssertEqual(
            DocumentRetrievalService.expandedChunkText(current: chunks[1], inDocumentChunks: chunks),
            "chunk0\n\nchunk1\n\nchunk2"
        )
        // First chunk has only a forward neighbor.
        XCTAssertEqual(
            DocumentRetrievalService.expandedChunkText(current: chunks[0], inDocumentChunks: chunks),
            "chunk0\n\nchunk1"
        )
        // A neighbor already selected as its own source is skipped (no duplication).
        XCTAssertEqual(
            DocumentRetrievalService.expandedChunkText(current: chunks[1], inDocumentChunks: chunks, excluding: ["c0"]),
            "chunk1\n\nchunk2"
        )
        // A chunk in a different part is never pulled in.
        let otherPart = DocumentChunkRecord(id: "x", documentID: "d", pagePartID: "p2", chunkIndex: 0, sourceKind: "text", normalizedText: "other")
        XCTAssertEqual(
            DocumentRetrievalService.expandedChunkText(current: chunks[1], inDocumentChunks: chunks + [otherPart]),
            "chunk0\n\nchunk1\n\nchunk2"
        )
    }

    func testContextMetadataComposesTypeAndDate() {
        var doc = MatterDocumentRecord(
            matterID: "m", blobID: "b", folderID: nil, displayName: "lease.pdf",
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        )
        doc.metadataModifiedAt = Date(timeIntervalSince1970: 1_682_899_200) // 2023-05-01 UTC
        XCTAssertEqual(DocumentRetrievalService.contextMetadata(for: doc), "2023-05-01")
        // No classification and no date → no descriptor.
        let bare = MatterDocumentRecord(
            matterID: "m", blobID: "b", folderID: nil, displayName: "x.txt",
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        )
        XCTAssertNil(DocumentRetrievalService.contextMetadata(for: bare))
    }

    func testQAPromptHeaderSurfacesSourceMetadata() {
        let source = GroundingSource(
            label: "S1", documentName: "lease.pdf", locatorDisplay: "p.1",
            text: "Tenant shall pay rent monthly.", excerpt: "rent monthly",
            metadata: "Real Estate & Property · 2023-05-01"
        )
        let prompt = DocumentQAPromptBuilder.buildQAPrompt(question: "When is rent due?", sources: [source], mode: .short)
        XCTAssertTrue(prompt.contains("[S1] lease.pdf (p.1) — Real Estate & Property · 2023-05-01:"))
    }

    func testExpandedChunkReportsCharSpanAcrossFoldedNeighbors() {
        let chunks = (0..<3).map { i in
            DocumentChunkRecord(id: "c\(i)", documentID: "d", pagePartID: "p1", chunkIndex: i, sourceKind: "text", charStart: i * 100, charEnd: i * 100 + 90, normalizedText: "chunk\(i)")
        }
        // Middle chunk folds both neighbors → the span covers all three.
        let mid = DocumentRetrievalService.expandedChunk(current: chunks[1], inDocumentChunks: chunks)
        XCTAssertEqual(mid.text, "chunk0\n\nchunk1\n\nchunk2")
        XCTAssertEqual(mid.charStart, 0)
        XCTAssertEqual(mid.charEnd, 290)
        // With both neighbors excluded, the span stays the chunk's own.
        let isolated = DocumentRetrievalService.expandedChunk(current: chunks[1], inDocumentChunks: chunks, excluding: ["c0", "c2"])
        XCTAssertEqual(isolated.charStart, 100)
        XCTAssertEqual(isolated.charEnd, 190)
    }

    func testQAPromptCapsOverlongSourceText() {
        let long = String(repeating: "x", count: DocumentQAPromptBuilder.maxSourceTextChars + 500)
        let source = GroundingSource(label: "S1", documentName: "d", locatorDisplay: "p.1", text: long, excerpt: "x")
        let prompt = DocumentQAPromptBuilder.buildQAPrompt(question: "Q", sources: [source], mode: .short)
        XCTAssertTrue(prompt.contains("[source text truncated to fit the context window]"))
        XCTAssertLessThan(prompt.count, long.count, "an overlong source must be trimmed in the prompt")
    }

    // MARK: - Helpers

    @discardableResult
    private func makeDocument(_ store: SupraStore, _ matterID: String, _ blobID: String, _ folderID: String?, _ name: String, _ text: String) throws -> MatterDocumentRecord {
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blobID, folderID: folderID, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])
        return doc
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetrievalStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

/// Deterministic hashing bag-of-words embedder: texts sharing vocabulary get
/// similar vectors, so cosine ranking is exercised without a real model.
private struct BagOfWordsEmbedder: TextEmbedder {
    let modelID = "bow-test"
    let modelRepoID = "bow-test"
    let modelDisplayName = "Bag of Words (test)"
    let modelRevision: String? = nil
    let dimension = 64

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            for token in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where token.count >= 2 {
                vector[Self.bucket(token)] += 1
            }
            return vector
        }
    }

    // Deterministic FNV-1a hash so bucketing does not vary per process run.
    private static func bucket(_ token: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in token.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Int(hash % 64)
    }
}
