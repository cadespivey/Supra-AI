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

    func testTVER08ReviewTransitionIsSingleUseAuditedAndInvalidatesCitingOutput() throws {
        // T-VER-08 expected RED: relation review has no repository-owned transition,
        // audit event, or dependent-output invalidation boundary.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic audited relation review")
        let draft = try seedDocument(
            store, matterID: matter.id, id: "draft", blobID: "blob-draft", sha: "sha-draft"
        )
        let executed = try seedDocument(
            store, matterID: matter.id, id: "executed", blobID: "blob-executed", sha: "sha-executed"
        )
        let evidence = #"{"schema_version":1,"signal":"synthetic_nondefault_draft"}"#
        let proposal = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: draft.id,
            toDocumentID: executed.id,
            kind: .draftOf,
            evidenceJSON: evidence,
            confidence: 0.81,
            proposedBy: .system
        )

        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Synthetic operative-state output",
            outputType: .documentQA,
            status: .complete
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Synthetic version-sensitive answer.",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .legacyUnverified,
            outputStatus: .needsReview
        )
        try store.structuredOutputs.updateStatus(outputID: output.id, status: .complete)
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource
        )
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: draft.id,
            citationLabel: "S1",
            excerpt: "synthetic draft evidence"
        ), preserveUnknownRevision: true)
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let reviewedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let rejected = try store.documentRelations.review(
            matterID: matter.id,
            id: proposal.id,
            decision: .rejected,
            reviewedBy: "Synthetic Reviewer",
            reviewedAt: reviewedAt
        )

        XCTAssertEqual(rejected.reviewState, DocumentRelationReviewState.rejected.rawValue)
        XCTAssertEqual(rejected.reviewedBy, "Synthetic Reviewer")
        XCTAssertEqual(rejected.reviewedAt, reviewedAt)
        XCTAssertEqual(rejected.evidenceJSON, evidence, "review must not rewrite immutable evidence")
        XCTAssertEqual(rejected.proposedBy, DocumentRelationProposer.system.rawValue)
        let events = try store.auditEvents.fetchEvents(
            relatedTable: DocumentRelationRecord.databaseTableName,
            relatedID: proposal.id,
            eventType: "document_relation_reviewed"
        )
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.actor, "Synthetic Reviewer")
        XCTAssertEqual(event.timestamp, reviewedAt)
        let metadata = try XCTUnwrap(event.metadataJSON?.data(using: .utf8))
        let audit = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        )
        XCTAssertEqual(audit["old_review_state"] as? String, "proposed")
        XCTAssertEqual(audit["new_review_state"] as? String, "rejected")
        XCTAssertEqual(audit["evidence_json"] as? String, evidence)
        XCTAssertEqual(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).first?.status,
            StructuredOutputStatus.needsReview.rawValue
        )

        XCTAssertThrowsError(try store.documentRelations.review(
            matterID: matter.id,
            id: proposal.id,
            decision: .confirmed,
            reviewedBy: "Second Synthetic Reviewer"
        )) { error in
            XCTAssertEqual(
                error as? DocumentRelationRepositoryError,
                .invalidReviewTransition(from: .rejected, to: .confirmed)
            )
        }
        XCTAssertEqual(
            try store.auditEvents.fetchEvents(
                relatedTable: DocumentRelationRecord.databaseTableName,
                relatedID: proposal.id,
                eventType: "document_relation_reviewed"
            ).count,
            1,
            "a refused second transition must not append a misleading audit row"
        )
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
