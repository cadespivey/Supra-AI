import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentVersionRelationProposalTests: XCTestCase {
    func testTVER04DraftExecutedProposalHasStableEvidenceAndNeverCrossesMatter() throws {
        // Expected RED: the relation service has no structural/version-family proposal pass.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic version family")
        let foreignMatter = try store.matters.createMatter(name: "Synthetic foreign family")
        let draft = try seedDocument(
            store,
            matterID: matter.id,
            id: "contract-draft",
            displayName: "Atlas Services Agreement Draft.docx",
            text: "Control No. ATLAS-2026-001. Services begin January 1. Payment is due in 30 days. Liability is limited to $150,000.",
            metadataDate: date("2026-01-02"),
            units: [
                ("section/services", .paragraph, "Services begin January 1."),
                ("section/payment", .paragraph, "Payment is due in 30 days."),
                ("section/liability", .paragraph, "Liability is limited to $150,000."),
            ]
        )
        let executed = try seedDocument(
            store,
            matterID: matter.id,
            id: "contract-executed",
            displayName: "Atlas Services Agreement Executed.docx",
            text: "Control No. ATLAS-2026-001. Services begin January 1. Payment is due in 45 days. Liability is limited to $150,000. Any amendment must be signed.",
            metadataDate: date("2026-01-15"),
            units: [
                ("section/services", .paragraph, "Services begin January 1."),
                ("section/payment", .paragraph, "Payment is due in 45 days."),
                ("section/liability", .paragraph, "Liability is limited to $150,000."),
            ]
        )
        let executedCopy = try seedDocument(
            store,
            matterID: matter.id,
            id: "contract-executed-copy",
            displayName: "Atlas Services Agreement Executed Copy.docx",
            text: "Control No. ATLAS-2026-001. Services begin January 1. Payment is due in 45 days. Liability is limited to $150,000. Any amendment must be signed.",
            metadataDate: date("2026-01-16"),
            units: [
                ("section/services", .paragraph, "Services begin January 1."),
                ("section/payment", .paragraph, "Payment is due in 45 days."),
                ("section/liability", .paragraph, "Liability is limited to $150,000."),
            ],
            reuseBlobID: executed.blobID
        )
        let foreign = try seedDocument(
            store,
            matterID: foreignMatter.id,
            id: "foreign-executed",
            displayName: "Atlas Services Agreement Executed Copy.docx",
            text: "Control No. ATLAS-2026-001. Services begin January 1. Payment is due in 30 days. Liability is limited to $150,000.",
            metadataDate: date("2026-01-16"),
            units: [
                ("section/services", .paragraph, "Services begin January 1."),
                ("section/payment", .paragraph, "Payment is due in 30 days."),
                ("section/liability", .paragraph, "Liability is limited to $150,000."),
            ]
        )

        let service = DocumentRelationProposalService(store: store)
        let first = try service.proposeVersionRelations(matterID: matter.id)
        let replay = try service.proposeVersionRelations(matterID: matter.id)
        let proposal = try XCTUnwrap(first.first {
            $0.kind == DocumentRelationKind.draftOf.rawValue
                && $0.fromDocumentID == draft.id
                && $0.toDocumentID == executed.id
        })
        XCTAssertEqual(replay.first { $0.id == proposal.id }?.evidenceJSON, proposal.evidenceJSON)
        XCTAssertEqual(proposal.reviewState, DocumentRelationReviewState.proposed.rawValue)
        XCTAssertNil(proposal.reviewedBy)
        XCTAssertNil(proposal.reviewedAt)

        let evidence = try json(proposal.evidenceJSON)
        XCTAssertEqual(evidence["algorithm"] as? String, "structural_relation_v1")
        XCTAssertEqual(evidence["role_signal"] as? String, "draft_to_executed")
        XCTAssertEqual(evidence["text_shingle_size"] as? Int, 3)
        XCTAssertEqual(evidence["changed_units"] as? Int, 1)
        XCTAssertEqual(evidence["inserted_units"] as? Int, 0)
        XCTAssertEqual(evidence["deleted_units"] as? Int, 0)
        XCTAssertNotEqual(evidence["combined_similarity"] as? Double, 1.0)
        XCTAssertTrue(first.contains { $0.kind == DocumentRelationKind.nearDuplicate.rawValue })
        XCTAssertFalse(first.contains {
            $0.fromDocumentID == executedCopy.id || $0.toDocumentID == executedCopy.id
        }, "byte-identical copy instances must not multiply directional version targets")
        XCTAssertFalse(first.contains {
            $0.fromDocumentID == foreign.id || $0.toDocumentID == foreign.id
        }, "same-family text in another matter must never enter a proposal")
    }

    func testTVER05AmendmentAndSupersessionChainsAreDirectedAcyclicAndDateAware() throws {
        // Expected RED: date-ordered amendment/supersession analysis is missing.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic amendment chain")
        let superseded = try seedDocument(
            store,
            matterID: matter.id,
            id: "superseded",
            displayName: "Atlas Services Agreement Superseded.docx",
            text: sharedText("Superseded version limits liability to $100,000."),
            metadataDate: date("2026-01-01")
        )
        let executed = try seedDocument(
            store,
            matterID: matter.id,
            id: "executed",
            displayName: "Atlas Services Agreement Executed.docx",
            text: sharedText("Executed version limits liability to $150,000."),
            metadataDate: date("2026-01-10")
        )
        let amendment1 = try seedDocument(
            store,
            matterID: matter.id,
            id: "amendment-1",
            displayName: "Amendment 1 to Atlas Services Agreement.docx",
            text: sharedText("Amendment 1 changes payment to 45 days."),
            metadataDate: date("2026-02-01")
        )
        let amendment2 = try seedDocument(
            store,
            matterID: matter.id,
            id: "amendment-2",
            displayName: "Amendment 2 to Atlas Services Agreement.docx",
            text: sharedText("Amendment 2 changes liability to $275,000."),
            metadataDate: date("2026-03-01")
        )
        let amendment3 = try seedDocument(
            store,
            matterID: matter.id,
            id: "amendment-3-undated",
            displayName: "Amendment 3 to Atlas Services Agreement.docx",
            text: sharedText("Amendment 3 changes the audit period."),
            metadataDate: nil
        )

        let proposals = try DocumentRelationProposalService(store: store)
            .proposeVersionRelations(matterID: matter.id)
        let directed = proposals.filter {
            DocumentRelationKind(rawValue: $0.kind)?.isSymmetric == false
        }

        XCTAssertNotNil(relation(.supersedes, from: executed.id, to: superseded.id, in: directed))
        XCTAssertNotNil(relation(.amendmentOf, from: amendment1.id, to: executed.id, in: directed))
        XCTAssertNotNil(relation(.amendmentOf, from: amendment2.id, to: amendment1.id, in: directed))
        let ambiguous = try XCTUnwrap(relation(
            .amendmentOf,
            from: amendment3.id,
            to: amendment2.id,
            in: directed
        ))
        let ambiguousEvidence = try json(ambiguous.evidenceJSON)
        XCTAssertEqual(ambiguousEvidence["date_order"] as? String, "ambiguous_missing_date")
        XCTAssertEqual(ambiguous.reviewState, DocumentRelationReviewState.proposed.rawValue)
        XCTAssertLessThan(ambiguous.confidence ?? 1, 0.8)
        assertAcyclic(directed)
    }

    @discardableResult
    private func seedDocument(
        _ store: SupraStore,
        matterID: String,
        id: String,
        displayName: String,
        text: String,
        metadataDate: Date?,
        units: [(String, DocumentStructureNodeKind, String)]? = nil,
        reuseBlobID: String? = nil
    ) throws -> MatterDocumentRecord {
        let blob: DocumentBlobRecord
        if let reuseBlobID {
            blob = try XCTUnwrap(store.documentLibrary.fetchBlob(id: reuseBlobID))
        } else {
            blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                id: "blob-\(id)",
                sha256: "sha-\(id)",
                byteSize: text.utf8.count,
                originalExtension: "docx",
                managedRelativePath: "blobs/\(id).docx"
            )).blob
        }
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: displayName,
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue,
            metadataCreatedAt: metadataDate,
            createdAt: date("2025-12-01"),
            updatedAt: date("2025-12-01")
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
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-\(id)",
            documentID: id,
            partIndex: 0,
            derivationKey: "relation-structure-\(id)",
            origin: "parser",
            method: "synthetic",
            text: text,
            charCount: text.count,
            createdAt: date("2025-12-01")
        ))
        let structuralUnits = units ?? [
            ("section/common", .paragraph, "Control No. ATLAS-2026-001."),
            ("section/body", .paragraph, text),
        ]
        let rootID = "node-\(id)-root"
        var nodes = [DocumentStructureNodeRecord(
            id: rootID,
            documentID: id,
            revisionID: revision.id,
            nodeKey: "document",
            ordinal: 0,
            kind: DocumentStructureNodeKind.document.rawValue,
            createdAt: date("2025-12-01")
        )]
        nodes.append(contentsOf: structuralUnits.enumerated().map { index, unit in
            DocumentStructureNodeRecord(
                id: "node-\(id)-\(index)",
                documentID: id,
                revisionID: revision.id,
                nodeKey: unit.0,
                parentNodeID: rootID,
                ordinal: index + 1,
                kind: unit.1.rawValue,
                textContent: unit.2,
                createdAt: date("2025-12-01")
            )
        })
        try store.documentStructure.replaceStructure(documentID: id, nodes: nodes, edges: [])
        return document
    }

    private func sharedText(_ change: String) -> String {
        "Control No. ATLAS-2026-001. Services begin January 1. Payment terms and audit rights remain part of the agreement. \(change)"
    }

    private func relation(
        _ kind: DocumentRelationKind,
        from: String,
        to: String,
        in relations: [DocumentRelationRecord]
    ) -> DocumentRelationRecord? {
        relations.first {
            $0.kind == kind.rawValue && $0.fromDocumentID == from && $0.toDocumentID == to
        }
    }

    private func assertAcyclic(
        _ relations: [DocumentRelationRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let edges = Dictionary(grouping: relations, by: \.fromDocumentID)
        func reaches(_ target: String, from node: String, visited: inout Set<String>) -> Bool {
            guard visited.insert(node).inserted else { return false }
            for edge in edges[node, default: []] {
                if edge.toDocumentID == target { return true }
                if reaches(target, from: edge.toDocumentID, visited: &visited) { return true }
            }
            return false
        }
        for relation in relations {
            var visited = Set<String>()
            XCTAssertFalse(
                reaches(relation.fromDocumentID, from: relation.toDocumentID, visited: &visited),
                "directed relation graph contains a cycle through \(relation.relationKey)",
                file: file,
                line: line
            )
        }
    }

    private func json(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: "\(value)T12:00:00Z")!
    }
}
