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
