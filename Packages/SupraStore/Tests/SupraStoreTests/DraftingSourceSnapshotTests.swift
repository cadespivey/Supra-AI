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

        // Standing fallback guard: a node-less v2 chunk is still exact revision text,
        // never arbitrary deterministic text with a recomputed id.
        let fallback = v2Chunk(
            base: fixture.chunks[0],
            nodeID: nil,
            unitKind: nil,
            text: primaryText,
            start: start,
            end: end
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.chunks[0].documentID,
            chunks: [fallback]
        )
        XCTAssertEqual(
            try fixture.store.draftingSources.captureMotionSnapshot(
                request(for: fixture, factChunkIDs: [fallback.id])
            ).facts.first?.text,
            primaryText
        )
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

    // Expected RED: sources can change during async verification and the later audit
    // insert does not compare them with the values actually rendered.
    func testTMDSS05CommitRejectsDependencyDriftAndWritesNoAudit() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        try fixture.store.appSettings.setSetting(
            assistantKey,
            value: ["firm": "Changed Firm"]
        )
        let event = AuditEventRecord(
            id: "stale-motion-audit",
            matterID: fixture.matter.id,
            eventType: "draft_generated",
            actor: "user",
            summary: "Generated synthetic motion",
            relatedTable: MatterRecord.databaseTableName,
            relatedID: fixture.matter.id,
            metadataJSON: #"{"source_snapshot_sha256":"content-free"}"#
        )

        XCTAssertThrowsError(
            try fixture.store.draftingSources.recordMotionAudit(event, requiring: snapshot)
        ) { error in
            XCTAssertEqual(error as? MotionDraftSnapshotError, .sourceSnapshotStale)
        }
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .contains { $0.id == event.id }
        )
    }

    // Expected RED: there is no transaction that revalidates the snapshot and inserts
    // the content-free audit row as one indivisible write.
    func testTMDSS06CommitRevalidatesAndInsertsAuditAtomically() throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(request(for: fixture))
        let event = AuditEventRecord(
            id: "current-motion-audit",
            matterID: fixture.matter.id,
            eventType: "draft_generated",
            actor: "user",
            summary: "Generated synthetic motion",
            relatedTable: MatterRecord.databaseTableName,
            relatedID: fixture.matter.id,
            metadataJSON: #"{"source_snapshot_sha256":"content-free"}"#
        )

        try fixture.store.draftingSources.recordMotionAudit(event, requiring: snapshot)

        let stored = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .first { $0.id == event.id }
        )
        XCTAssertEqual(stored.metadataJSON, event.metadataJSON)
        XCTAssertFalse(try XCTUnwrap(stored.metadataJSON).contains(fixture.revision.text))
        XCTAssertFalse(try XCTUnwrap(stored.metadataJSON).contains(authorityExcerpt))
    }

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let revision: DocumentPartRevisionRecord
        let chunks: [DocumentChunkRecord]
        let authority: AuthorityRecord
        let review: AuthorityReviewedProposition
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
            normalizedText: text,
            charCount: text.count
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
                charStart: text.distance(from: text.startIndex, to: range.lowerBound),
                charEnd: text.distance(from: text.startIndex, to: range.upperBound),
                normalizedText: excerpt
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
        MotionDraftSnapshotRequest(
            matterID: fixture.matter.id,
            factChunkIDs: factChunkIDs ?? [fixture.chunks[0].id],
            authoritySelections: [
                MotionDraftAuthoritySelection(
                    authorityID: fixture.authority.id,
                    groundKey: .failureToStateClaim
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
        end: Int
    ) -> DocumentChunkRecord {
        let identity = [
            "chunk-v2", base.documentID, base.revisionID ?? "", base.pagePartID ?? "",
            nodeID ?? "", String(base.chunkIndex), String(start), String(end), text,
        ].joined(separator: "\u{001f}")
        return DocumentChunkRecord(
            id: "chunk-v2-\(sha256(identity))",
            documentID: base.documentID,
            pagePartID: base.pagePartID,
            revisionID: base.revisionID,
            nodeID: nodeID,
            unitKind: unitKind,
            chunkerVersion: 2,
            chunkIndex: base.chunkIndex,
            sourceKind: base.sourceKind,
            charStart: start,
            charEnd: end,
            normalizedText: text
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
