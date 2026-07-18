import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentRelationRepositoryTests: XCTestCase {
    func testTVER01CanonicalKeysDirectionalityIsolationAndCascadeIntegrity() throws {
        // Expected RED: DocumentRelationRepository, its record/enums, and the
        // v065 table do not exist.
        let store = try SupraStore.inMemory()
        let matterA = try store.matters.createMatter(name: "Synthetic relation matter A")
        let matterB = try store.matters.createMatter(name: "Synthetic relation matter B")
        let first = try seedDocument(store, matterID: matterA.id, id: "doc-a", blobID: "blob-a", sha: "sha-a")
        let second = try seedDocument(store, matterID: matterA.id, id: "doc-b", blobID: "blob-b", sha: "sha-b")
        let third = try seedDocument(store, matterID: matterA.id, id: "doc-c", blobID: "blob-c", sha: "sha-c")
        let foreign = try seedDocument(store, matterID: matterB.id, id: "doc-z", blobID: "blob-z", sha: "sha-z")

        let evidence = #"{"schema_version":1,"fixture":"reverse-canonicalization"}"#
        let symmetric = try store.documentRelations.propose(
            matterID: matterA.id,
            fromDocumentID: second.id,
            toDocumentID: first.id,
            kind: .exactDuplicate,
            evidenceJSON: evidence,
            confidence: 0.875,
            proposedBy: .system
        )
        let reversedReplay = try store.documentRelations.propose(
            matterID: matterA.id,
            fromDocumentID: first.id,
            toDocumentID: second.id,
            kind: .exactDuplicate,
            evidenceJSON: evidence,
            confidence: 0.875,
            proposedBy: .system
        )
        XCTAssertEqual(reversedReplay.id, symmetric.id)
        XCTAssertEqual(symmetric.fromDocumentID, first.id)
        XCTAssertEqual(symmetric.toDocumentID, second.id)
        XCTAssertEqual(symmetric.relationKey, "doc-a|doc-b")

        let forward = try store.documentRelations.propose(
            matterID: matterA.id,
            fromDocumentID: first.id,
            toDocumentID: third.id,
            kind: .draftOf,
            evidenceJSON: #"{"schema_version":1,"fixture":"forward"}"#,
            confidence: 0.625,
            proposedBy: .user
        )
        let reverse = try store.documentRelations.propose(
            matterID: matterA.id,
            fromDocumentID: third.id,
            toDocumentID: first.id,
            kind: .draftOf,
            evidenceJSON: #"{"schema_version":1,"fixture":"reverse"}"#,
            confidence: 0.625,
            proposedBy: .user
        )
        XCTAssertNotEqual(forward.id, reverse.id)
        XCTAssertEqual(forward.relationKey, "doc-a->doc-c")
        XCTAssertEqual(reverse.relationKey, "doc-c->doc-a")

        XCTAssertThrowsError(try store.documentRelations.propose(
            matterID: matterA.id,
            fromDocumentID: first.id,
            toDocumentID: foreign.id,
            kind: .normalizedDuplicate,
            evidenceJSON: #"{"schema_version":1,"fixture":"cross-matter"}"#,
            confidence: 0.5,
            proposedBy: .system
        )) { error in
            XCTAssertEqual(
                error as? DocumentRelationRepositoryError,
                .documentMatterMismatch(foreign.id)
            )
        }
        XCTAssertEqual(try store.documentRelations.fetchAll(matterID: matterA.id).count, 3)
        XCTAssertTrue(try store.documentRelations.fetchAll(matterID: matterB.id).isEmpty)

        try store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM matter_documents WHERE id = ?", arguments: [second.id])
        }
        let afterCascade = try store.documentRelations.fetchAll(matterID: matterA.id)
        XCTAssertEqual(afterCascade.count, 2)
        XCTAssertFalse(afterCascade.contains { $0.id == symmetric.id })
    }

    func testTVER03HighConfidenceSystemProposalsNeverAutoConfirm() throws {
        // Expected RED: no relation review-state model or confirmed-only query exists.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic proposal-only matter")
        let first = try seedDocument(store, matterID: matter.id, id: "doc-one", blobID: "blob-one", sha: "sha-one")
        let second = try seedDocument(store, matterID: matter.id, id: "doc-two", blobID: "blob-two", sha: "sha-two")
        let third = try seedDocument(store, matterID: matter.id, id: "doc-three", blobID: "blob-three", sha: "sha-three")

        let exact = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: first.id,
            toDocumentID: second.id,
            kind: .exactDuplicate,
            evidenceJSON: #"{"schema_version":1,"confidence_basis":"byte_exact"}"#,
            confidence: 1,
            proposedBy: .system
        )
        let near = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: first.id,
            toDocumentID: third.id,
            kind: .nearDuplicate,
            evidenceJSON: #"{"schema_version":1,"confidence_basis":"synthetic_high"}"#,
            confidence: 0.999,
            proposedBy: .system
        )

        for relation in [exact, near] {
            XCTAssertEqual(relation.reviewState, DocumentRelationReviewState.proposed.rawValue)
            XCTAssertNil(relation.reviewedBy)
            XCTAssertNil(relation.reviewedAt)
        }
        XCTAssertTrue(try store.documentRelations.fetchConfirmed(matterID: matter.id).isEmpty)
    }

    @discardableResult
    private func seedDocument(
        _ store: SupraStore,
        matterID: String,
        id: String,
        blobID: String,
        sha: String
    ) throws -> MatterDocumentRecord {
        _ = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: blobID,
            sha256: sha,
            byteSize: 32,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(sha).txt"
        ))
        return try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blobID,
            displayName: "\(id).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
    }
}
