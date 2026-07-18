import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentRelationReviewTests: XCTestCase {
    @MainActor
    func testTVER08RejectedProposalCanBeReplacedByAuditedConfirmedUserOverride() throws {
        // T-VER-08 expected RED: no view-facing review controller can reject a
        // system proposal and create/confirm a distinct user override.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic relation override")
        let draft = try seedDocument(store, matterID: matter.id, id: "draft", text: "DRAFT-BETA")
        let executed = try seedDocument(store, matterID: matter.id, id: "executed", text: "EXECUTED-GAMMA")
        let system = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: draft.id,
            toDocumentID: executed.id,
            kind: .draftOf,
            evidenceJSON: #"{"schema_version":1,"basis":"synthetic_system"}"#,
            confidence: 0.77,
            proposedBy: .system
        )
        let controller = DocumentRelationReviewController(matterID: matter.id, store: store)

        XCTAssertEqual(controller.pendingReviewCount, 1)
        try controller.reject(relationID: system.id, actor: "Synthetic Owner")
        let override = try controller.createAndConfirmOverride(
            replacingRelationID: system.id,
            fromDocumentID: executed.id,
            toDocumentID: draft.id,
            kind: .supersedes,
            evidenceJSON: #"{"schema_version":1,"basis":"synthetic_user_override"}"#,
            actor: "Synthetic Owner"
        )

        XCTAssertEqual(try store.documentRelations.fetch(matterID: matter.id, id: system.id)?.reviewState, "rejected")
        XCTAssertEqual(override.reviewState, DocumentRelationReviewState.confirmed.rawValue)
        XCTAssertEqual(override.proposedBy, DocumentRelationProposer.user.rawValue)
        XCTAssertEqual(override.fromDocumentID, executed.id)
        XCTAssertEqual(override.toDocumentID, draft.id)
        XCTAssertEqual(override.kind, DocumentRelationKind.supersedes.rawValue)
        XCTAssertEqual(try store.documentRelations.fetchConfirmed(matterID: matter.id), [override])
        XCTAssertEqual(controller.pendingReviewCount, 0)
        XCTAssertTrue(controller.auditConfirmation?.contains("Synthetic Owner") == true)
        let overrideEvents = try store.auditEvents.fetchEvents(
            relatedTable: DocumentRelationRecord.databaseTableName,
            relatedID: override.id
        )
        XCTAssertEqual(Set(overrideEvents.map(\.eventType)), ["document_relation_reviewed", "document_relation_override_created"])
        XCTAssertTrue(overrideEvents.allSatisfy { $0.actor == "Synthetic Owner" })
    }

    func testTVER07UnreviewedInScopeRelationWarnsRetrievalAndBlocksCleanVersionAssurance() async throws {
        // T-VER-07 expected RED: retrieval has only an advisory classifier/date
        // hint, and corpus analysis can still return clean assurance while an
        // in-scope operative-state proposal is unreviewed.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic version assurance")
        let draft = try seedIndexedDocument(
            store,
            matterID: matter.id,
            id: "scope-draft",
            name: "Atlas Draft Agreement.txt",
            text: "VERSIONALPHA draft payment is due in thirty days."
        )
        let executed = try seedIndexedDocument(
            store,
            matterID: matter.id,
            id: "scope-executed",
            name: "Atlas Executed Agreement.txt",
            text: "VERSIONALPHA executed payment is due in forty five days."
        )
        let proposal = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: draft.id,
            toDocumentID: executed.id,
            kind: .draftOf,
            evidenceJSON: #"{"schema_version":1,"basis":"synthetic_unreviewed"}"#,
            confidence: 0.88,
            proposedBy: .system
        )

        let retrieval = DocumentRetrievalService(store: store)
        let preliminary = try await retrieval.retrieve(
            matterID: matter.id,
            query: "VERSIONALPHA payment",
            scope: .wholeMatter
        )
        XCTAssertTrue(preliminary.incompleteScopeWarning?.contains("unreviewed relation") == true)
        XCTAssertTrue(preliminary.incompleteScopeWarning?.contains("Atlas Draft Agreement.txt") == true)
        XCTAssertTrue(preliminary.incompleteScopeWarning?.contains("Atlas Executed Agreement.txt") == true)
        XCTAssertFalse(preliminary.sources.compactMap(\.metadata).contains { metadata in
            metadata.localizedCaseInsensitiveContains("operative")
                || metadata.localizedCaseInsensitiveContains("draft (confirmed)")
        })

        let engine = CorpusAnalysisEngine(store: store)
        let comparison = try await engine.run(
            request: CorpusAnalysisRequest(
                runKey: "t-ver-07-comparison",
                matterID: matter.id,
                taskKind: .comparison,
                characterBudget: 1
            )
        ) { Self.findings($0) }
        XCTAssertEqual(comparison.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(comparison.assuranceReasons.contains { reason in
            reason.contains("unreviewed relation")
                && reason.contains("Atlas Draft Agreement.txt")
                && reason.contains("Atlas Executed Agreement.txt")
        })

        let negative = try await engine.run(
            request: CorpusAnalysisRequest(
                runKey: "t-ver-07-negative",
                matterID: matter.id,
                taskKind: .negativeCheck,
                characterBudget: 1
            )
        ) { Self.findings($0) }
        XCTAssertEqual(negative.run.assuranceState, OutputAssuranceState.negativeBlocked.rawValue)
        XCTAssertTrue(negative.assuranceReasons.contains { $0.contains("unreviewed relation") })

        _ = try store.documentRelations.review(
            matterID: matter.id,
            id: proposal.id,
            decision: .confirmed,
            reviewedBy: "Synthetic Reviewer"
        )
        let reviewed = try await retrieval.retrieve(
            matterID: matter.id,
            query: "VERSIONALPHA payment",
            scope: .wholeMatter
        )
        XCTAssertFalse(reviewed.incompleteScopeWarning?.contains("unreviewed relation") == true)
        XCTAssertTrue(reviewed.sources.first { $0.documentID == draft.id }?.metadata?.contains("Version state: draft (confirmed)") == true)
        XCTAssertTrue(reviewed.sources.first { $0.documentID == executed.id }?.metadata?.contains("Version state: operative (confirmed)") == true)

        let cleared = try await engine.run(
            request: CorpusAnalysisRequest(
                runKey: "t-ver-07-reviewed-comparison",
                matterID: matter.id,
                taskKind: .comparison,
                characterBudget: 1
            )
        ) { Self.findings($0) }
        XCTAssertEqual(cleared.run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
    }

    private func seedDocument(
        _ store: SupraStore,
        matterID: String,
        id: String,
        name: String? = nil,
        text: String
    ) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "blob-\(id)",
            sha256: "sha-\(id)",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(id).txt"
        )).blob
        return try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: name ?? "\(id).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue
        ))
    }

    private func seedIndexedDocument(
        _ store: SupraStore,
        matterID: String,
        id: String,
        name: String,
        text: String
    ) throws -> MatterDocumentRecord {
        _ = try seedDocument(
            store, matterID: matterID, id: id, name: name, text: text
        )
        let part = DocumentPagePartRecord(
            id: "part-\(id)", documentID: id, partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text, charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "revision-\(id)", documentID: id, partIndex: 0,
            derivationKey: "fixture-\(id)", origin: "synthetic_test",
            method: "plain-text", text: text, charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "selection-\(id)", documentID: id, partIndex: 0,
            selectedRevisionID: revision.id, selectionKey: "fixture-\(id)",
            selectedBy: "test", decisionJSON: #"{"rule":"synthetic"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        try store.documentIndex.replaceChunks(documentID: id, chunks: [
            DocumentChunkRecord(
                id: "chunk-\(id)", documentID: id, pagePartID: part.id,
                revisionID: revision.id, chunkIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text
            ),
        ])
        return try XCTUnwrap(store.documentLibrary.fetchDocument(id: id))
    }

    private static func findings(_ input: CorpusAnalysisPartitionInput) -> CorpusAnalysisMapOutput {
        CorpusAnalysisMapOutput(findings: input.sources.map { source in
            CorpusAnalysisFinding(
                id: "finding-\(source.revisionID)",
                value: source.text,
                evidence: [.init(
                    documentID: source.documentID,
                    revisionID: source.revisionID,
                    locatorJSON: source.locatorJSON
                )]
            )
        })
    }
}
