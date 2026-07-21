import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

/// Phase 2 groundwork (retrieve-before-route): a pure signal for "does the matter's own corpus
/// actually cover this question?" — the primary discriminator that will let routing decide
/// document-vs-legal from EVIDENCE instead of keyword lists. No routing change here; measured
/// via the existing fast-tier retrieval, model-free.
@MainActor
final class MatterCorpusCoverageTests: XCTestCase {

    func testCoveredQuestionHasCoverage() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The indemnification clause covers all third-party claims arising under this agreement.")

        let signal = await MatterCorpusCoverage.assess(
            matterID: matter.id, question: "What do the documents say about indemnification?", store: store
        )
        XCTAssertTrue(signal.hasCoverage, "a question the corpus covers must report coverage")
        XCTAssertGreaterThanOrEqual(signal.matchedSourceCount, 1)
        XCTAssertNotEqual(signal.strength, .none)
    }

    func testOffTopicQuestionHasNoCoverage() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The indemnification clause covers all third-party claims.")

        let signal = await MatterCorpusCoverage.assess(
            matterID: matter.id, question: "quantum entanglement between distant black holes", store: store
        )
        XCTAssertFalse(signal.hasCoverage, "an off-topic question must report no coverage")
        XCTAssertEqual(signal.strength, .none)
        XCTAssertEqual(signal.matchedSourceCount, 0)
    }

    func testEmptyMatterHasNoCoverage() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Empty Matter")
        let signal = await MatterCorpusCoverage.assess(
            matterID: matter.id, question: "What is the fee?", store: store
        )
        XCTAssertEqual(signal.strength, .none)
        XCTAssertEqual(signal.matchedSourceCount, 0)
    }

    func testMultipleMatchingSourcesAreStrongCoverage() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "a.txt", "The indemnification obligation survives termination.")
        try await indexDoc(store, matter.id, "b.txt", "Indemnification is capped at the fees paid.")

        let signal = await MatterCorpusCoverage.assess(
            matterID: matter.id, question: "indemnification", store: store
        )
        XCTAssertEqual(signal.strength, .strong, "two matching sources is strong coverage")
        XCTAssertGreaterThanOrEqual(signal.matchedSourceCount, 2)
    }

    // MARK: - Helpers

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ name: String, _ text: String) async throws {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(UUID().uuidString).txt")
        ).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: nil, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        let revision = DocumentPartRevisionRecord(
            documentID: document.id, partIndex: 0, derivationKey: "coverage-\(document.id)",
            origin: "parser", method: "synthetic", text: text, charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            documentID: document.id, partIndex: 0, selectedRevisionID: revision.id,
            selectionKey: "coverage-sel-\(document.id)", selectedBy: "system", policyVersion: 1,
            decisionJSON: #"{"rule":"synthetic_fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [DocumentPagePartRecord(documentID: document.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)],
            revisions: [revision], selections: [selection]
        )
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: document.id)
    }
}
