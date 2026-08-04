import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DraftingSourceSnapshotTests: XCTestCase {
    private let assistantKey = "assistant.profile"
    private let styleKey = "firm.styleProfile"
    private let authorityExcerpt = "A complaint must allege each essential element of a recognized claim."

    // Expected RED: motion sources are currently fetched through independent repository
    // reads, and no immutable transaction snapshot binds facts, review evidence, or settings.
    func testTMDSS01CaptureBindsSelectedOrderRevisionBytesReviewEvidenceAndSettings() throws {
        let fixture = try makeFixture()
        let request = request(for: fixture, factChunkIDs: fixture.chunks.reversed().map(\.id))

        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request)

        XCTAssertEqual(snapshot.matter.id, fixture.matter.id)
        XCTAssertEqual(snapshot.facts.map(\.chunkID), fixture.chunks.reversed().map(\.id))
        XCTAssertEqual(snapshot.facts.map(\.text), fixture.chunks.reversed().map(\.normalizedText))
        XCTAssertEqual(snapshot.facts.map(\.revisionID), [fixture.revision.id, fixture.revision.id])
        XCTAssertTrue(snapshot.facts.allSatisfy { $0.revisionSHA256 == sha256(fixture.revision.text) })
        XCTAssertEqual(snapshot.facts.map(\.excerptSHA256), fixture.chunks.reversed().map { sha256($0.normalizedText) })
        XCTAssertTrue(snapshot.facts.allSatisfy { $0.ocrConfidence == 0.97 })
        XCTAssertTrue(snapshot.facts.allSatisfy {
            $0.boundingBoxesSHA256 == sha256(#"[{"x":0.1,"y":0.2,"width":0.3,"height":0.4}]"#)
        })
        XCTAssertEqual(snapshot.authorities.map(\.authorityID), [fixture.authority.id])
        XCTAssertEqual(snapshot.authorities.first?.groundKey, .failureToStateClaim)
        XCTAssertEqual(snapshot.authorities.first?.excerpt, authorityExcerpt)
        XCTAssertEqual(snapshot.authorities.first?.bindingSHA256, fixture.review.bindingSHA256)
        XCTAssertEqual(snapshot.assistantProfile.valueJSON, #"{"firm":"Synthetic Firm"}"#)
        XCTAssertEqual(snapshot.firmStyleProfile.valueJSON, #"{"style":"nondefault"}"#)
        XCTAssertTrue(isSHA256(snapshot.fingerprintSHA256))
        XCTAssertFalse(snapshot.fingerprintSHA256.contains(fixture.revision.text))
        XCTAssertFalse(snapshot.fingerprintSHA256.contains(authorityExcerpt))
    }

    // Expected RED: no request boundary rejects ambiguous duplicate selections.
    func testTMDSS02CaptureRejectsDuplicateAndCrossMatterSelections() throws {
        let fixture = try makeFixture()
        let duplicate = request(
            for: fixture,
            factChunkIDs: [fixture.chunks[0].id, fixture.chunks[0].id]
        )
        XCTAssertThrowsError(try fixture.store.draftingSources.captureMotionSnapshot(duplicate)) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .duplicateFactChunkID(fixture.chunks[0].id)
            )
        }

        let other = try makeDocumentFixture(store: fixture.store, matterName: "Other synthetic matter")
        let crossMatter = request(for: fixture, factChunkIDs: [other.chunk.id])
        XCTAssertThrowsError(try fixture.store.draftingSources.captureMotionSnapshot(crossMatter)) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .factOutsideMatter(other.chunk.id)
            )
        }
    }

    func testTMDSS02BRejectsStaleDisplayedFactRevisionOrExcerptBinding() throws {
        let fixture = try makeFixture()
        let chunk = fixture.chunks[0]
        let base = request(for: fixture)
        let staleSelections = [
            MotionDraftFactSelection(
                chunkID: chunk.id,
                expectedRevisionID: "different-revision",
                expectedExcerptSHA256: sha256(chunk.normalizedText)
            ),
            MotionDraftFactSelection(
                chunkID: chunk.id,
                expectedRevisionID: fixture.revision.id,
                expectedExcerptSHA256: String(repeating: "0", count: 64)
            ),
        ]

        for staleSelection in staleSelections {
            let stale = MotionDraftSnapshotRequest(
                matterID: base.matterID,
                factSelections: [staleSelection],
                authoritySelections: base.authoritySelections,
                assistantProfileSettingKey: base.assistantProfileSettingKey,
                firmStyleProfileSettingKey: base.firmStyleProfileSettingKey
            )
            XCTAssertThrowsError(try fixture.store.draftingSources.captureMotionSnapshot(stale)) { error in
                XCTAssertEqual(error as? MotionDraftSnapshotError, .factSelectionStale(chunk.id))
            }
        }
    }

    // Expected RED: the controller trusts denormalized chunk text without proving that
    // it is the exact selected immutable revision range.
    func testTMDSS03CaptureRejectsForgedOrStaleChunkBinding() throws {
        let fixture = try makeFixture()
        let chunkID = fixture.chunks[0].id
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_chunks SET normalized_text = ? WHERE id = ?",
                arguments: ["Forged denormalized allegation.", chunkID]
            )
        }

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [chunkID])
            )
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(chunkID))
        }
    }

    // Expected RED: snapshot capture trusts denormalized chunk locator/provenance
    // columns even when they disagree with the selected page-part row.
    func testTMDSS03BRejectsChunkLocatorOrProvenanceThatDiffersFromSelectedPart() throws {
        try assertChunkMutationRejected(column: "page_index", value: 99)
        try assertChunkMutationRejected(column: "page_label", value: "forged-page")
        try assertChunkMutationRejected(column: "sheet_name", value: "forged-sheet")
        try assertChunkMutationRejected(column: "cell_range", value: "Z99:Z100")
        try assertChunkMutationRejected(column: "email_part_path", value: "forged/part")
        try assertChunkMutationRejected(column: "ocr_confidence", value: 0.01)
        try assertChunkMutationRejected(column: "bounding_boxes_json", value: #"[{"forged":true}]"#)
    }

    // Expected RED: matching denormalized part and chunk metadata can both drift
    // from the selected immutable revision while the current binding still passes.
    func testTMDSS03CRejectsPartAndChunkProvenanceDriftFromCurrentRevision() throws {
        let fixture = try makeFixture()
        let chunk = fixture.chunks[0]
        let forgedBoxes = #"[{"x":0.9,"y":0.8,"width":0.7,"height":0.6}]"#
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_pages_parts SET ocr_confidence = ?, bounding_boxes_json = ? WHERE id = ?",
                arguments: [0.12, forgedBoxes, chunk.pagePartID]
            )
            try db.execute(
                sql: "UPDATE document_chunks SET ocr_confidence = ?, bounding_boxes_json = ? WHERE id = ?",
                arguments: [0.12, forgedBoxes, chunk.id]
            )
        }

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [chunk.id])
            )
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(chunk.id))
        }
    }

    // Expected RED: v2 validation currently accepts a deterministic chunk whose text is
    // composed from the primary node plus any unrelated node in the revision. Only the
    // exact responds_to/references/header_for graph projection may bind motion evidence.
    func testTMDSS03ARejectsV2ChunkComposedWithUnrelatedStructureNode() throws {
        let fixture = try makeFixture()
        let text = fixture.revision.text
        let primaryText = fixture.chunks[0].normalizedText
        let responseText = fixture.chunks[1].normalizedText
        let unrelatedText = "complaint"
        let primaryRange = try XCTUnwrap(text.range(of: primaryText))
        let responseRange = try XCTUnwrap(text.range(of: responseText))
        let unrelatedRange = try XCTUnwrap(text.range(of: unrelatedText))
        let start = text.distance(from: text.startIndex, to: primaryRange.lowerBound)
        let end = text.distance(from: text.startIndex, to: primaryRange.upperBound)
        let nodes = [
            DocumentStructureNodeRecord(
                id: "v2-root",
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "document",
                ordinal: 0,
                kind: "document"
            ),
            DocumentStructureNodeRecord(
                id: "v2-primary",
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "request",
                parentNodeID: "v2-root",
                ordinal: 0,
                kind: "discovery_request",
                charStart: start,
                charEnd: end
            ),
            DocumentStructureNodeRecord(
                id: "v2-response",
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "response",
                parentNodeID: "v2-root",
                ordinal: 1,
                kind: "discovery_response",
                charStart: text.distance(from: text.startIndex, to: responseRange.lowerBound),
                charEnd: text.distance(from: text.startIndex, to: responseRange.upperBound)
            ),
            DocumentStructureNodeRecord(
                id: "v2-unrelated",
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "unrelated",
                parentNodeID: "v2-root",
                ordinal: 2,
                kind: "paragraph",
                charStart: text.distance(from: text.startIndex, to: unrelatedRange.lowerBound),
                charEnd: text.distance(from: text.startIndex, to: unrelatedRange.upperBound)
            ),
        ]
        try fixture.store.documentStructure.replaceStructure(
            documentID: fixture.chunks[0].documentID,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: [
                DocumentStructureEdgeRecord(
                    id: "v2-response-edge",
                    matterID: fixture.matter.id,
                    fromNodeID: "v2-response",
                    toNodeID: "v2-primary",
                    kind: "responds_to"
                ),
            ]
        )
        let forgedText = primaryText + "\n" + unrelatedText
        let forged = v2Chunk(
            base: fixture.chunks[0],
            nodeID: "v2-primary",
            unitKind: "discovery_request",
            text: forgedText,
            start: start,
            end: end
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [forged]
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [forged.id])
            )
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(forged.id))
        }

        // Expected RED: a node-less v2 row is the shipping producer's v1 fallback
        // projection, not any exact subrange with a recomputed deterministic id.
        let forgedFallback = v2Chunk(
            base: fixture.chunks[0],
            nodeID: nil,
            unitKind: nil,
            text: primaryText,
            start: start,
            end: end
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [forgedFallback]
        )
        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [forgedFallback.id])
            )
        ) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .factBindingInvalid(forgedFallback.id)
            )
        }

        // Positive control uses a separate document with no usable structure
        // candidates, which is the only point where the shipping v2 producer
        // delegates to its node-less v1 fallback.
        let fallbackFixture = try makeFixture()
        let fallbackText = fallbackFixture.revision.text
        let shippingFallback = v2Chunk(
            base: fallbackFixture.chunks[0],
            nodeID: nil,
            unitKind: nil,
            text: fallbackText,
            start: 0,
            end: fallbackText.count
        )
        try fallbackFixture.store.documentIndex.replaceChunks(
            documentID: fallbackFixture.chunks[0].documentID,
            chunks: [shippingFallback]
        )
        XCTAssertEqual(
            try fallbackFixture.store.draftingSources.captureMotionSnapshot(
                request(for: fallbackFixture, factChunkIDs: [shippingFallback.id])
            ).facts.first?.text,
            fallbackText
        )
    }

    // Expected RED: the snapshot validator accepts a primary-only v2 chunk whenever
    // a request/response pair exceeds the chunker's configurable 200-character floor,
    // even though the shipping 1,200-character producer emits this pair only as one chunk.
    func testTMDSS03BRejectsPrimaryOnlyV2ChunkForShippingSizeRequestResponsePair() throws {
        let fixture = try makeFixture()
        let pair = try installShippingSizeV2RequestResponse(in: fixture)
        let combined = v2Chunk(
            base: fixture.chunks[0],
            nodeID: pair.requestNodeID,
            unitKind: "discovery_request",
            text: pair.requestText + "\n" + pair.responseText,
            start: 0,
            end: pair.requestText.count
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [combined]
        )
        XCTAssertEqual(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [combined.id])
            ).facts.first?.text,
            pair.requestText + "\n" + pair.responseText
        )

        let forgedPrimary = v2Chunk(
            base: fixture.chunks[0],
            nodeID: pair.requestNodeID,
            unitKind: "discovery_request",
            text: pair.requestText,
            start: 0,
            end: pair.requestText.count
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [forgedPrimary]
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [forgedPrimary.id])
            )
        ) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .factBindingInvalid(forgedPrimary.id)
            )
        }
    }

    // Expected RED: validating one node in isolation permits a response that the
    // shipping producer consumed into its preceding request to masquerade as a chunk.
    func testTMDSS03DRejectsConsumedV2ResponseForgedAsStandaloneChunk() throws {
        let fixture = try makeFixture()
        let pair = try installShippingSizeV2RequestResponse(in: fixture)
        let forgedResponse = v2Chunk(
            base: fixture.chunks[0],
            nodeID: pair.responseNodeID,
            unitKind: "discovery_response",
            text: pair.responseText,
            start: 0,
            end: pair.responseText.count
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [forgedResponse]
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [forgedResponse.id])
            )
        ) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .factBindingInvalid(forgedResponse.id)
            )
        }
    }

    // Expected RED: a recomputed deterministic id currently blesses an arbitrary
    // persisted chunk index even when the shipping producer emits the exact graph
    // projection at a different global index.
    func testTMDSS03ERejectsV2ChunkWithForgedProducerIndex() throws {
        let fixture = try makeFixture()
        let pair = try installShippingSizeV2RequestResponse(in: fixture)
        let forged = v2Chunk(
            base: fixture.chunks[0],
            nodeID: pair.requestNodeID,
            unitKind: "discovery_request",
            text: pair.requestText + "\n" + pair.responseText,
            start: 0,
            end: pair.requestText.count,
            chunkIndex: 73
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [forged]
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [forged.id])
            )
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(forged.id))
        }
    }

    // Expected RED: the shipping v1 producer writes nil structural fields, but
    // whitespace optionals currently pass through as if they were absent.
    func testTMDSS03FRejectsNonNilV1StructuralCoordinates() throws {
        let fixture = try makeFixture()
        let chunk = fixture.chunks[0]
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_chunks SET unit_kind = ? WHERE id = ?",
                arguments: ["\t", chunk.id]
            )
        }

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [chunk.id])
            )
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(chunk.id))
        }
    }

    // Expected RED: raw authority flags and citation text can currently enter a motion
    // without proposition-specific reviewed evidence for the selected ground.
    func testTMDSS04CaptureRequiresLiveReviewedAuthorityProposition() throws {
        let fixture = try makeFixture(reviewAuthority: false)

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        ) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .authorityPropositionUnavailable(
                    authorityID: fixture.authority.id,
                    reason: "not_reviewed"
                )
            )
        }
    }

    // Expected RED: a legacy/direct-SQL authority can claim the selected matter
    // while its linked result and session actually belong to another matter.
    func testTMDSS04BCaptureRejectsLegacyCrossMatterAuthorityProvenance() throws {
        let fixture = try makeFixture()
        let foreignDocument = try makeDocumentFixture(
            store: fixture.store,
            matterName: "Foreign synthetic drafting matter"
        )
        let foreignAuthority = try makeAuthority(
            store: fixture.store,
            matter: foreignDocument.matter
        )
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE authorities
                SET research_session_id = ?, research_result_id = ?
                WHERE id = ?
                """,
                arguments: [
                    foreignAuthority.researchSessionID,
                    foreignAuthority.researchResultID,
                    fixture.authority.id,
                ]
            )
        }

        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        ) { error in
            XCTAssertEqual(
                error as? MotionDraftSnapshotError,
                .authorityProvenanceInvalid(fixture.authority.id)
            )
        }
    }

    // Expected RED: the source fingerprint omits the exact v2 relation projection.
    // Changing references to responds_to preserves the composed chunk text today, so
    // commit incorrectly accepts a graph different from the one that was verified.
    func testTMDSS04ACommitRejectsExactV2EdgeKindDriftWithSameComposedText() throws {
        let fixture = try makeFixture()
        let v2 = try installRelatedV2Fact(fixture: fixture, edgeKind: "references")
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            request(for: fixture, factChunkIDs: [v2.chunk.id])
        )
        let factJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.facts[0])) as? [String: Any]
        )
        let projection = try XCTUnwrap(factJSON["relatedStructureEdges"] as? [[String: Any]])
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection[0]["edgeID"] as? String, v2.edgeID)
        XCTAssertEqual(projection[0]["kind"] as? String, "references")
        XCTAssertEqual(projection[0]["projectionOrder"] as? Int, 0)

        let intent = try fixture.store.draftArtifacts.prepareMotionIntent(
            snapshot: snapshot,
            fileName: "Motion-to-Dismiss-edge-drift.docx",
            output: Data("synthetic motion".utf8),
            auditInput: motionAuditInput(snapshot: snapshot),
            id: "edge-drift-motion-intent"
        )

        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_structure_edges SET kind = ? WHERE id = ?",
                arguments: ["responds_to", v2.edgeID]
            )
        }
        XCTAssertThrowsError(
            try fixture.store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: Data("synthetic motion".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .sourceSnapshotStale)
        }
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .contains { $0.id == "draft-artifact-\(intent.id)" }
        )
    }

    // Expected RED: sources can change during async verification and the later audit
    // insert does not compare them with the values actually rendered.
    func testTMDSS05CommitRejectsDependencyDriftAndWritesNoAudit() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let intent = try fixture.store.draftArtifacts.prepareMotionIntent(
            snapshot: snapshot,
            fileName: "Motion-to-Dismiss-stale.docx",
            output: Data("synthetic motion".utf8),
            auditInput: motionAuditInput(snapshot: snapshot),
            id: "stale-motion-intent"
        )
        try fixture.store.appSettings.setSetting(
            assistantKey,
            value: ["firm": "Changed Firm"]
        )

        XCTAssertThrowsError(
            try fixture.store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: Data("synthetic motion".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .sourceSnapshotStale)
        }
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .contains { $0.id == "draft-artifact-\(intent.id)" }
        )
    }

    // Expected RED: there is no transaction that revalidates the snapshot and inserts
    // the content-free audit row as one indivisible write.
    func testTMDSS06CommitRevalidatesAndInsertsAuditAtomically() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let intent = try fixture.store.draftArtifacts.prepareMotionIntent(
            snapshot: snapshot,
            fileName: "Motion-to-Dismiss-current.docx",
            output: Data("synthetic motion".utf8),
            auditInput: motionAuditInput(snapshot: snapshot),
            id: "current-motion-intent"
        )

        try fixture.store.draftArtifacts.finalizeIntent(
            id: intent.id,
            installedOutput: Data("synthetic motion".utf8)
        )

        let stored = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .first { $0.id == "draft-artifact-\(intent.id)" }
        )
        XCTAssertEqual(stored.metadataJSON, intent.auditMetadataJSON)
        XCTAssertFalse(try XCTUnwrap(stored.metadataJSON).contains(fixture.revision.text))
        XCTAssertFalse(try XCTUnwrap(stored.metadataJSON).contains(authorityExcerpt))
        let lineage = try JSONDecoder().decode(
            MotionDraftAuditLineage.self,
            from: Data(try XCTUnwrap(stored.metadataJSON).utf8)
        )
        XCTAssertEqual(
            lineage.verificationReceiptScope,
            .motionSelectedSourceReproductionAndStructure
        )
        XCTAssertEqual(lineage.verificationScope.schemaVersion, 1)
        XCTAssertEqual(lineage.verificationScope.kindID, "motionToDismiss")
        XCTAssertEqual(
            lineage.verificationScope.factPropositionIDs,
            snapshot.facts.map { "motion.fact.\($0.chunkID)" }
        )
        XCTAssertEqual(
            lineage.verificationScope.authorityPropositionIDs,
            snapshot.authorities.map { "motion.authority.\($0.authorityID)" }
        )
        XCTAssertEqual(
            lineage.verificationScope.bodyContract,
            MotionDraftVerificationScope.exactSelectedBodyContract
        )
    }

    // Expected RED: commit validates only matter_id, so unrelated event shapes,
    // malformed lineage, a wrong/missing source hash, and an extra raw-content
    // field can all be inserted as if Store had blessed a current motion artifact.
    func testTMDSS07CommitRequiresStoreOwnedContentFreeAuditEnvelope() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let valid = try auditMetadata(snapshot: snapshot)
        let wrongHash = try auditMetadata(
            snapshot: snapshot,
            sourceSnapshotSHA256: String(repeating: "f", count: 64)
        )
        let missingHash = try auditMetadata(snapshot: snapshot, includeSourceSnapshotSHA256: false)
        let wrongSchema = try auditMetadata(snapshot: snapshot, schemaVersion: 1)
        let rawContent = try auditMetadata(
            snapshot: snapshot,
            additionalTopLevel: ["rawSourceText": fixture.revision.text]
        )
        // Expected RED: a passed DOCX audit cannot describe an empty artifact.
        let zeroByteOutput = try auditMetadata(
            snapshot: snapshot,
            additionalTopLevel: ["outputByteSize": 0]
        )
        let invalidEvents = [
            motionAuditEvent(id: "wrong-event-type", fixture: fixture, eventType: "draft_failed", metadataJSON: valid),
            motionAuditEvent(id: "wrong-related-table", fixture: fixture, relatedTable: "structured_outputs", metadataJSON: valid),
            motionAuditEvent(id: "wrong-related-id", fixture: fixture, relatedID: "another-matter", metadataJSON: valid),
            motionAuditEvent(id: "missing-metadata", fixture: fixture, metadataJSON: nil),
            motionAuditEvent(id: "malformed-metadata", fixture: fixture, metadataJSON: "not-json"),
            motionAuditEvent(id: "wrong-schema", fixture: fixture, metadataJSON: wrongSchema),
            motionAuditEvent(id: "wrong-source-hash", fixture: fixture, metadataJSON: wrongHash),
            motionAuditEvent(id: "missing-source-hash", fixture: fixture, metadataJSON: missingHash),
            motionAuditEvent(id: "raw-content-key", fixture: fixture, metadataJSON: rawContent),
            motionAuditEvent(id: "zero-byte-output", fixture: fixture, metadataJSON: zeroByteOutput),
        ]

        for event in invalidEvents {
            XCTAssertThrowsError(
                try fixture.store.draftingSources.recordMotionAudit(event, requiring: snapshot),
                "invalid audit envelope \(event.id) was accepted"
            )
        }
        let storedIDs = Set(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).map(\.id))
        XCTAssertTrue(storedIDs.isDisjoint(with: invalidEvents.map(\.id)))
    }

    // T-MTD-17 RED: shape validation is not ownership. A caller can currently
    // invent every non-source digest and producer coordinate, then ask Store to
    // bless that forged lineage. Store must construct and bind those values to
    // typed inputs and the actual artifact bytes instead.
    func testTMDSS08CommitRejectsCallerForgedArtifactAndProducerLineage() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let forged = motionAuditEvent(
            id: "forged-motion-audit",
            fixture: fixture,
            metadataJSON: try auditMetadata(snapshot: snapshot)
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.recordMotionAudit(forged, requiring: snapshot)
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .auditEnvelopeInvalid)
        }
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .contains { $0.id == forged.id }
        )
    }

    // T-MTD-18 RED: a prepared row is durable but not trusted. Tampering its
    // Store-built JSON after preparation must not survive typed finalization.
    func testTMDSS09FinalizeRejectsTamperedPreparedMotionLineage() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let output = Data("synthetic motion".utf8)
        let intent = try fixture.store.draftArtifacts.prepareMotionIntent(
            snapshot: snapshot,
            fileName: "Motion-to-Dismiss-tampered.docx",
            output: output,
            auditInput: motionAuditInput(snapshot: snapshot),
            id: "tampered-motion-intent"
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(intent.auditMetadataJSON.utf8)) as? [String: Any]
        )
        var verifier = try XCTUnwrap(root["verifierIdentity"] as? [String: Any])
        verifier["version"] = "forged"
        root["verifierIdentity"] = verifier
        let tampered = String(
            decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            as: UTF8.self
        )
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET audit_metadata_json = ? WHERE id = ?",
                arguments: [tampered, intent.id]
            )
        }

        XCTAssertThrowsError(
            try fixture.store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: output
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .contains { $0.id == "draft-artifact-\(intent.id)" }
        )
    }

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let revision: DocumentPartRevisionRecord
        let chunks: [DocumentChunkRecord]
        let authority: AuthorityRecord
        let review: AuthorityReviewedProposition
    }

    private struct V2RequestResponseFixture {
        let requestNodeID: String
        let responseNodeID: String
        let requestText: String
        let responseText: String
    }

    private func installShippingSizeV2RequestResponse(
        in fixture: Fixture
    ) throws -> V2RequestResponseFixture {
        let requestNodeID = "v2-shipping-request"
        let responseNodeID = "v2-shipping-response"
        let requestText = "Request No. 4: "
            + String(repeating: "Produce the synthetic invoice ledger. ", count: 4)
        let responseText = "Response No. 4: "
            + String(repeating: "The synthetic ledger will be produced. ", count: 3)
        let combinedText = requestText + "\n" + responseText
        XCTAssertGreaterThan(combinedText.count, 200)
        XCTAssertLessThanOrEqual(combinedText.count, 1_200)

        try fixture.store.documentStructure.replaceStructure(
            documentID: fixture.chunks[0].documentID,
            revisionID: fixture.revision.id,
            nodes: [
                DocumentStructureNodeRecord(
                    id: "v2-shipping-root",
                    documentID: fixture.chunks[0].documentID,
                    revisionID: fixture.revision.id,
                    nodeKey: "document",
                    ordinal: 0,
                    kind: "document"
                ),
                DocumentStructureNodeRecord(
                    id: requestNodeID,
                    documentID: fixture.chunks[0].documentID,
                    revisionID: fixture.revision.id,
                    nodeKey: "request",
                    parentNodeID: "v2-shipping-root",
                    ordinal: 0,
                    kind: "discovery_request",
                    textContent: requestText
                ),
                DocumentStructureNodeRecord(
                    id: responseNodeID,
                    documentID: fixture.chunks[0].documentID,
                    revisionID: fixture.revision.id,
                    nodeKey: "response",
                    parentNodeID: "v2-shipping-root",
                    ordinal: 1,
                    kind: "discovery_response",
                    textContent: responseText
                ),
            ],
            edges: [
                DocumentStructureEdgeRecord(
                    id: "v2-shipping-response-edge",
                    matterID: fixture.matter.id,
                    fromNodeID: responseNodeID,
                    toNodeID: requestNodeID,
                    kind: "responds_to"
                ),
            ]
        )
        return V2RequestResponseFixture(
            requestNodeID: requestNodeID,
            responseNodeID: responseNodeID,
            requestText: requestText,
            responseText: responseText
        )
    }

    private func makeFixture(reviewAuthority: Bool = true) throws -> Fixture {
        let store = try SupraStore.inMemory()
        let document = try makeDocumentFixture(store: store, matterName: "Harbor LLC v. Palmetto Inc.")
        try store.appSettings.setSetting(assistantKey, value: ["firm": "Synthetic Firm"])
        try store.appSettings.setSetting(styleKey, value: ["style": "nondefault"])
        let authority = try makeAuthority(store: store, matter: document.matter)
        let review: AuthorityReviewedProposition
        if reviewAuthority {
            review = try store.authorities.reviewProposition(
                authorityID: authority.id,
                groundKey: .failureToStateClaim,
                excerpt: authorityExcerpt,
                reviewedBy: "synthetic-reviewer",
                reviewedAt: Date(timeIntervalSince1970: 1_785_513_600)
            )
        } else {
            review = AuthorityReviewedProposition(
                authorityID: authority.id,
                groundKey: .failureToStateClaim,
                excerpt: "unused",
                excerptByteStart: 0,
                excerptByteLength: 6,
                opinionSHA256: String(repeating: "0", count: 64),
                excerptSHA256: String(repeating: "0", count: 64),
                effectiveCitationSHA256: String(repeating: "0", count: 64),
                courtSHA256: String(repeating: "0", count: 64),
                bindingSHA256: String(repeating: "0", count: 64),
                reviewedBy: "unused",
                reviewedAt: .distantPast
            )
        }
        return Fixture(
            store: store,
            matter: document.matter,
            revision: document.revision,
            chunks: document.chunks,
            authority: authority,
            review: review
        )
    }

    private func makeDocumentFixture(
        store: SupraStore,
        matterName: String
    ) throws -> (
        matter: MatterRecord,
        revision: DocumentPartRevisionRecord,
        chunks: [DocumentChunkRecord],
        chunk: DocumentChunkRecord
    ) {
        let matter = try store.matters.createMatter(
            name: matterName,
            jurisdiction: "Florida",
            partyPerspective: .defendant,
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT",
            judge: "Alex Morgan",
            docketNumber: "2026-CA-001847"
        )
        let text = "The complaint omits duty. The complaint omits damages."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: sha256("blob-\(matter.id)"),
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(matter.id).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Synthetic complaint.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue,
            sourceKind: DocumentSourceKind.text.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "part-\(matter.id)",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            pageIndex: 3,
            pageLabel: "iv",
            sheetName: "Pleadings",
            cellRange: "B2:D8",
            emailPartPath: "message/body/1",
            normalizedText: text,
            charCount: text.count,
            ocrConfidence: 0.97,
            boundingBoxesJSON: #"[{"x":0.1,"y":0.2,"width":0.3,"height":0.4}]"#
        )
        try store.documentIndex.replaceParts(documentID: document.id, parts: [part])
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-\(matter.id)",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "synthetic-\(matter.id)",
            origin: "parser",
            method: "plain-text",
            text: text,
            charCount: text.count,
            ocrConfidence: part.ocrConfidence,
            boundingBoxesJSON: part.boundingBoxesJSON,
            toolchainVersion: "synthetic-v1"
        ))
        let selection = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            id: "selection-\(matter.id)",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "synthetic-\(matter.id)",
            selectedBy: "test",
            decisionJSON: "{}"
        ))
        XCTAssertEqual(selection.selectedRevisionID, revision.id)
        let excerpts = ["The complaint omits duty.", "The complaint omits damages."]
        let chunks = try excerpts.enumerated().map { index, excerpt in
            let range = try XCTUnwrap(text.range(of: excerpt))
            return DocumentChunkRecord(
                id: "chunk-\(matter.id)-\(index)",
                documentID: document.id,
                pagePartID: part.id,
                revisionID: revision.id,
                chunkerVersion: 1,
                chunkIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                pageIndex: part.pageIndex,
                pageLabel: part.pageLabel,
                sheetName: part.sheetName,
                cellRange: part.cellRange,
                emailPartPath: part.emailPartPath,
                charStart: text.distance(from: text.startIndex, to: range.lowerBound),
                charEnd: text.distance(from: text.startIndex, to: range.upperBound),
                normalizedText: excerpt,
                boundingBoxesJSON: part.boundingBoxesJSON,
                ocrConfidence: part.ocrConfidence
            )
        }
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: chunks)
        return (matter, revision, chunks, chunks[0])
    }

    private func makeAuthority(store: SupraStore, matter: MatterRecord) throws -> AuthorityRecord {
        let citation = "321 So. 3d 456 (Fla. 4th DCA 2021)"
        let court = "Florida Fourth District Court of Appeal"
        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Synthetic authority review",
            issueText: "Whether a fictional complaint states a claim",
            jurisdiction: "Florida",
            status: .complete
        )
        let query = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "synthetic pleading standard",
            queryIndex: 0,
            status: .completed
        )
        let result = try store.research.insertResult(ResearchResultRecord(
            researchQueryID: query.id,
            caseName: "Harbor LLC v. Palmetto Inc.",
            citationJSON: #"["321 So. 3d 456 (Fla. 4th DCA 2021)"]"#,
            preferredCitation: citation,
            court: court,
            courtID: "fladistctapp4",
            reviewState: ResearchResultReviewState.notAdverse.rawValue
        ))
        return try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id,
            researchSessionID: session.id,
            researchResultID: result.id,
            caseName: result.caseName,
            citationJSON: result.citationJSON,
            preferredCitation: citation,
            court: court,
            courtID: "fladistctapp4",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            useStatus: AuthorityUseStatus.userMarkedVerified.rawValue,
            opinionText: "Before. \(authorityExcerpt) After.",
            rawMetadataJSON: "{}"
        ))
    }

    private func request(
        for fixture: Fixture,
        factChunkIDs: [String]? = nil
    ) -> MotionDraftSnapshotRequest {
        let factChunkIDs = factChunkIDs ?? [fixture.chunks[0].id]
        return MotionDraftSnapshotRequest(
            matterID: fixture.matter.id,
            factSelections: factChunkIDs.map { chunkID in
                let chunk = try? fixture.store.documentIndex.fetchChunk(id: chunkID)
                return MotionDraftFactSelection(
                    chunkID: chunkID,
                    expectedRevisionID: chunk?.revisionID ?? "",
                    expectedExcerptSHA256: chunk.map { sha256($0.normalizedText) }
                        ?? String(repeating: "0", count: 64)
                )
            },
            authoritySelections: [
                MotionDraftAuthoritySelection(
                    authorityID: fixture.authority.id,
                    groundKey: .failureToStateClaim,
                    expectedBindingSHA256: fixture.review.bindingSHA256
                ),
            ],
            assistantProfileSettingKey: assistantKey,
            firmStyleProfileSettingKey: styleKey
        )
    }

    private func v2Chunk(
        base: DocumentChunkRecord,
        nodeID: String?,
        unitKind: String?,
        text: String,
        start: Int,
        end: Int,
        chunkIndex: Int? = nil
    ) -> DocumentChunkRecord {
        let resolvedChunkIndex = chunkIndex ?? base.chunkIndex
        let identity = [
            "chunk-v2", base.documentID, base.revisionID ?? "", base.pagePartID ?? "",
            nodeID ?? "", String(resolvedChunkIndex), String(start), String(end), text,
        ].joined(separator: "\u{001f}")
        return DocumentChunkRecord(
            id: "chunk-v2-\(sha256(identity))",
            documentID: base.documentID,
            pagePartID: base.pagePartID,
            revisionID: base.revisionID,
            nodeID: nodeID,
            unitKind: unitKind,
            chunkerVersion: 2,
            chunkIndex: resolvedChunkIndex,
            sourceKind: base.sourceKind,
            pageIndex: base.pageIndex,
            pageLabel: base.pageLabel,
            sheetName: base.sheetName,
            cellRange: base.cellRange,
            emailPartPath: base.emailPartPath,
            charStart: start,
            charEnd: end,
            normalizedText: text,
            boundingBoxesJSON: base.boundingBoxesJSON,
            ocrConfidence: base.ocrConfidence
        )
    }

    private func assertChunkMutationRejected<Value: DatabaseValueConvertible>(
        column: String,
        value: Value
    ) throws {
        let fixture = try makeFixture()
        let chunkID = fixture.chunks[0].id
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_chunks SET \(column) = ? WHERE id = ?",
                arguments: [value, chunkID]
            )
        }
        XCTAssertThrowsError(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [chunkID])
            ),
            "forged chunk column \(column) was accepted"
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .factBindingInvalid(chunkID))
        }
    }

    private func installRelatedV2Fact(
        fixture: Fixture,
        edgeKind: String
    ) throws -> (
        chunk: DocumentChunkRecord,
        edgeID: String,
        primaryNodeID: String,
        relatedNodeID: String
    ) {
        let primaryText = fixture.chunks[0].normalizedText
        let relatedText = fixture.chunks[1].normalizedText
        let primaryRange = try XCTUnwrap(fixture.revision.text.range(of: primaryText))
        let relatedRange = try XCTUnwrap(fixture.revision.text.range(of: relatedText))
        let primaryNodeID = "v2-drift-primary"
        let relatedNodeID = "v2-drift-related"
        let rootNodeID = "v2-drift-root"
        let nodes = [
            DocumentStructureNodeRecord(
                id: rootNodeID,
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "document",
                ordinal: 0,
                kind: "document"
            ),
            DocumentStructureNodeRecord(
                id: primaryNodeID,
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "primary",
                parentNodeID: rootNodeID,
                ordinal: 0,
                kind: "discovery_request",
                charStart: fixture.revision.text.distance(from: fixture.revision.text.startIndex, to: primaryRange.lowerBound),
                charEnd: fixture.revision.text.distance(from: fixture.revision.text.startIndex, to: primaryRange.upperBound)
            ),
            DocumentStructureNodeRecord(
                id: relatedNodeID,
                documentID: fixture.chunks[0].documentID,
                revisionID: fixture.revision.id,
                nodeKey: "related",
                parentNodeID: rootNodeID,
                ordinal: 1,
                kind: "discovery_response",
                charStart: fixture.revision.text.distance(from: fixture.revision.text.startIndex, to: relatedRange.lowerBound),
                charEnd: fixture.revision.text.distance(from: fixture.revision.text.startIndex, to: relatedRange.upperBound)
            ),
        ]
        let edgeID = "v2-drift-edge"
        try fixture.store.documentStructure.replaceStructure(
            documentID: fixture.chunks[0].documentID,
            revisionID: fixture.revision.id,
            nodes: nodes,
            edges: [
                DocumentStructureEdgeRecord(
                    id: edgeID,
                    matterID: fixture.matter.id,
                    fromNodeID: relatedNodeID,
                    toNodeID: primaryNodeID,
                    kind: edgeKind
                ),
            ]
        )
        let start = fixture.revision.text.distance(
            from: fixture.revision.text.startIndex,
            to: primaryRange.lowerBound
        )
        let end = fixture.revision.text.distance(
            from: fixture.revision.text.startIndex,
            to: primaryRange.upperBound
        )
        let chunk = v2Chunk(
            base: fixture.chunks[0],
            nodeID: primaryNodeID,
            unitKind: "discovery_request",
            text: primaryText + "\n" + relatedText,
            start: start,
            end: end
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: chunk.documentID,
            chunks: [chunk]
        )
        return (chunk, edgeID, primaryNodeID, relatedNodeID)
    }

    private func motionAuditEvent(
        id: String,
        fixture: Fixture,
        eventType: String = "draft_generated",
        relatedTable: String = MatterRecord.databaseTableName,
        relatedID: String? = nil,
        metadataJSON: String?
    ) -> AuditEventRecord {
        AuditEventRecord(
            id: id,
            matterID: fixture.matter.id,
            eventType: eventType,
            actor: "user",
            summary: "Generated synthetic motion",
            relatedTable: relatedTable,
            relatedID: relatedID ?? fixture.matter.id,
            metadataJSON: metadataJSON
        )
    }

    private func auditMetadata(
        snapshot: MotionDraftStoreSnapshot,
        schemaVersion: Int = 2,
        sourceSnapshotSHA256: String? = nil,
        includeSourceSnapshotSHA256: Bool = true,
        relatedEdges: [[String: Any]] = [],
        additionalTopLevel: [String: Any] = [:]
    ) throws -> String {
        let digest = String(repeating: "a", count: 64)
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "kindID": "motionToDismiss",
            "facts": snapshot.facts.map { fact in
                var value: [String: Any] = [
                    "chunkID": fact.chunkID,
                    "documentID": fact.documentID,
                    "partID": fact.partID,
                    "revisionID": fact.revisionID,
                    "chunkerVersion": fact.chunkerVersion,
                    "charStart": fact.charStart,
                    "charEnd": fact.charEnd,
                    "revisionSHA256": fact.revisionSHA256,
                    "excerptSHA256": fact.excerptSHA256,
                    "relatedStructureEdges": relatedEdges,
                ]
                if let nodeID = fact.nodeID { value["nodeID"] = nodeID }
                if let unitKind = fact.unitKind { value["unitKind"] = unitKind }
                if let ocrConfidence = fact.ocrConfidence { value["ocrConfidence"] = ocrConfidence }
                if let boundingBoxesSHA256 = fact.boundingBoxesSHA256 {
                    value["boundingBoxesSHA256"] = boundingBoxesSHA256
                }
                return value
            },
            "authorities": snapshot.authorities.map { authority in
                [
                    "authorityID": authority.authorityID,
                    "groundKey": authority.groundKey.rawValue,
                    "evidenceSchemaVersion": authority.evidenceSchemaVersion,
                    "excerptByteStart": authority.excerptByteStart,
                    "excerptByteLength": authority.excerptByteLength,
                    "opinionSHA256": authority.opinionSHA256,
                    "excerptSHA256": authority.excerptSHA256,
                    "effectiveCitationSHA256": authority.effectiveCitationSHA256,
                    "courtSHA256": authority.courtSHA256,
                    "bindingSHA256": authority.bindingSHA256,
                ] as [String: Any]
            },
            "groundKeys": [AuthorityReviewedPropositionGround.failureToStateClaim.rawValue],
            "requestSHA256": digest,
            "captionSHA256": digest,
            "assistantProfileSHA256": snapshot.assistantProfile.valueSHA256,
            "effectiveStyleSHA256": digest,
            "groundContractIdentity": ["id": "motion-ground", "version": "1"],
            "assemblerIdentity": ["id": "motion-assembler", "version": "1"],
            "verifierIdentity": ["id": "motion-verifier", "version": "1"],
            "gateIdentity": ["id": "motion-gate", "version": "1"],
            "rendererIdentity": ["id": "motion-renderer", "version": "1"],
            "verificationReceiptSHA256": digest,
            "verificationStatus": "passed",
            "outputFileName": "Motion-to-Dismiss-synthetic.docx",
            "outputSHA256": digest,
            "outputByteSize": 123,
        ]
        if includeSourceSnapshotSHA256 {
            object["sourceSnapshotSHA256"] = sourceSnapshotSHA256 ?? snapshot.fingerprintSHA256
        }
        object.merge(additionalTopLevel) { _, new in new }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func motionAuditInput(snapshot: MotionDraftStoreSnapshot) -> MotionDraftAuditInput {
        MotionDraftAuditInput(
            canonicalRequest: Data("synthetic canonical request".utf8),
            canonicalCaption: Data("synthetic canonical caption".utf8),
            canonicalEffectiveStyle: Data("synthetic canonical style".utf8),
            groundContractIdentity: DraftArtifactIntentRepository.motionGroundContractIdentity,
            assemblerIdentity: DraftArtifactIntentRepository.motionAssemblerIdentity,
            verificationReceipt: MotionDraftVerificationReceiptInput(
                status: .passed,
                scope: .motionSelectedSourceReproductionAndStructure,
                supportedPropositionIDs:
                    snapshot.facts.map { "motion.fact.\($0.chunkID)" }
                    + snapshot.authorities.map { "motion.authority.\($0.authorityID)" },
                verifierIdentity: DraftArtifactIntentRepository.motionVerifierIdentity,
                gateIdentity: DraftArtifactIntentRepository.motionGateIdentity,
                rendererIdentity: DraftArtifactIntentRepository.motionRendererIdentity
            )
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
