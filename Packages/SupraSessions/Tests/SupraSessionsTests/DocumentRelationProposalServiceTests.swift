import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentRelationProposalServiceTests: XCTestCase {
    func testTVER02ExactAndNormalizedProposalsAreDeterministicAndIdempotent() throws {
        // Expected RED: DocumentRelationProposalService and v065 repository are missing.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic contract family")
        let foreignMatter = try store.matters.createMatter(name: "Synthetic foreign family")
        let exactA = try seedDocument(
            store, matterID: matter.id, id: "exact-a", blobID: "shared-blob", sha: "shared-sha",
            text: "Executed agreement text."
        )
        let exactB = try seedDocument(
            store, matterID: matter.id, id: "exact-b", blobID: "shared-blob", sha: "shared-sha",
            text: "Executed agreement text."
        )
        let normalizedA = try seedDocument(
            store, matterID: matter.id, id: "render-a", blobID: "render-blob-a", sha: "render-sha-a",
            text: "Normalized covenant text with section 12."
        )
        let normalizedB = try seedDocument(
            store, matterID: matter.id, id: "render-b", blobID: "render-blob-b", sha: "render-sha-b",
            text: "Normalized covenant text with section 12."
        )
        let unrelated = try seedDocument(
            store, matterID: matter.id, id: "unrelated", blobID: "unrelated-blob", sha: "unrelated-sha",
            text: "Completely unrelated witness interview."
        )
        _ = try seedDocument(
            store, matterID: foreignMatter.id, id: "foreign-render", blobID: "foreign-blob", sha: "foreign-sha",
            text: "Normalized covenant text with section 12."
        )

        let service = DocumentRelationProposalService(store: store)
        let firstPass = try service.proposeExactAndNormalizedDuplicates(matterID: matter.id)
        let replayPass = try service.proposeExactAndNormalizedDuplicates(matterID: matter.id)
        XCTAssertEqual(firstPass.count, 2)
        XCTAssertEqual(replayPass.map(\.id), firstPass.map(\.id))

        let relations = try store.documentRelations.fetchAll(matterID: matter.id)
        XCTAssertEqual(relations.count, 2, "rerunning the service must not duplicate proposals")
        let exact = try XCTUnwrap(relations.first { $0.kind == DocumentRelationKind.exactDuplicate.rawValue })
        XCTAssertEqual(Set([exact.fromDocumentID, exact.toDocumentID]), Set([exactA.id, exactB.id]))
        XCTAssertTrue(exact.evidenceJSON.contains(#""basis":"shared_blob""#))
        XCTAssertTrue(exact.evidenceJSON.contains(#""blob_id":"shared-blob""#))

        let normalized = try XCTUnwrap(relations.first {
            $0.kind == DocumentRelationKind.normalizedDuplicate.rawValue
        })
        XCTAssertEqual(
            Set([normalized.fromDocumentID, normalized.toDocumentID]),
            Set([normalizedA.id, normalizedB.id])
        )
        XCTAssertTrue(normalized.evidenceJSON.contains(#""basis":"normalized_text_digest""#))
        XCTAssertTrue(normalized.evidenceJSON.contains(DocumentStorageDigest.key(
            "Normalized covenant text with section 12."
        )))
        XCTAssertFalse(relations.contains {
            $0.fromDocumentID == unrelated.id || $0.toDocumentID == unrelated.id
        })
        XCTAssertTrue(relations.allSatisfy {
            $0.reviewState == DocumentRelationReviewState.proposed.rawValue
                && $0.proposedBy == DocumentRelationProposer.system.rawValue
                && $0.reviewedBy == nil
                && $0.reviewedAt == nil
        })
    }

    @discardableResult
    private func seedDocument(
        _ store: SupraStore,
        matterID: String,
        id: String,
        blobID: String,
        sha: String,
        text: String
    ) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: blobID,
            sha256: sha,
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(sha).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: "\(id).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
        try store.documentIndex.replaceChunks(documentID: id, chunks: [
            DocumentChunkRecord(
                id: "chunk-\(id)",
                documentID: id,
                chunkIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text
            ),
        ])
        return document
    }
}
