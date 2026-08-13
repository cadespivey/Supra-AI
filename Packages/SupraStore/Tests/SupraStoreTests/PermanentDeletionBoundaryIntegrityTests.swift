import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class PermanentDeletionBoundaryIntegrityTests: XCTestCase {
    func testInsertDocumentRejectsParentFromAnotherMatter() throws {
        // Expected RED: insertDocument currently accepts a parent from another
        // matter, creating an attachment edge whose FK cascade crosses scope.
        let store = try SupraStore.inMemory()
        let firstMatter = try store.matters.createMatter(name: "Boundary owner 613")
        let secondMatter = try store.matters.createMatter(name: "Boundary outsider 911")
        let parent = try insertDocument(
            store: store,
            matterID: firstMatter.id,
            id: "boundary-parent-613"
        )
        let childBlob = try insertBlob(store: store, id: "boundary-child-blob-911")
        let child = MatterDocumentRecord(
            id: "boundary-child-911",
            matterID: secondMatter.id,
            blobID: childBlob.id,
            parentDocumentID: parent.id,
            displayName: "Cross-matter child 911.txt"
        )

        XCTAssertThrowsError(try store.documentLibrary.insertDocument(child))
        XCTAssertNil(try store.documentLibrary.fetchDocument(id: child.id))
        XCTAssertNotNil(try store.documentLibrary.fetchDocument(id: parent.id))
    }

    func testDocumentDeletionFailsClosedAtCrossMatterCascadeBoundary() throws {
        // Expected RED: same-matter traversal omits the foreign-matter child,
        // but SQLite still cascades through its parent FK and commits an
        // incomplete deletion/audit packet.
        let fixture = try makeCrossMatterBoundary(caseName: "document")

        XCTAssertThrowsError(
            try fixture.store.documentLibrary.permanentlyDeleteDocument(
                id: fixture.parent.id,
                actor: "boundary-test"
            )
        )

        try assertCrossMatterBoundaryPreserved(fixture)
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: MatterDocumentRecord.databaseTableName,
                relatedID: fixture.parent.id,
                eventType: "document_permanently_deleted"
            ).isEmpty
        )
    }

    func testMatterDeletionFailsClosedAtCrossMatterCascadeBoundary() throws {
        // Expected RED: deleting the owning matter cascades through a malformed
        // foreign-matter child without capturing its blob, FTS, source lineage,
        // or id in the surviving matter-deletion audit.
        let fixture = try makeCrossMatterBoundary(caseName: "matter")

        XCTAssertThrowsError(
            try fixture.store.matters.permanentlyDeleteMatter(
                id: fixture.parentMatter.id,
                actor: "boundary-test"
            )
        )

        try assertCrossMatterBoundaryPreserved(fixture)
        XCTAssertNotNil(try fixture.store.matters.fetchMatter(id: fixture.parentMatter.id))
        XCTAssertNotNil(try fixture.store.matters.fetchMatter(id: fixture.childMatter.id))
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: MatterRecord.databaseTableName,
                relatedID: fixture.parentMatter.id,
                eventType: "matter_permanently_deleted"
            ).isEmpty
        )
    }

    func testSemanticallyMalformedSnapshotFailsClosedWithoutInvalidatingValidExclusions() throws {
        // Expected RED: a decodable eligible member with no document or revision
        // identity is treated as valid proof of exclusion, leaving a same-matter
        // strong run publishable after source deletion.
        let fixture = try makeAnalysisFixture(caseName: "snapshot")
        let validUnrelatedMember = CorpusAnalysisSnapshotMember(
            memberKey: "valid-unrelated-613",
            documentID: fixture.unrelatedDocument.id,
            displayName: fixture.unrelatedDocument.displayName,
            revisionIDs: [fixture.unrelatedRevision.id],
            disposition: .eligible
        )
        let malformedSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: 1,
            members: [
                validUnrelatedMember,
                CorpusAnalysisSnapshotMember(
                    memberKey: "broken-eligible-911",
                    displayName: "Broken eligible member 911",
                    revisionIDs: [],
                    disposition: .eligible
                ),
            ]
        )
        let validSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: 1,
            members: [
                validUnrelatedMember,
                CorpusAnalysisSnapshotMember(
                    memberKey: "valid-excluded-import-977",
                    displayName: "Excluded import source 977",
                    revisionIDs: [],
                    disposition: .excluded,
                    reason: "unsupported_by_policy"
                ),
            ]
        )
        let malformedRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "malformed-snapshot-run-613",
            snapshot: malformedSnapshot,
            status: .persisted
        )
        let validRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "valid-exclusion-run-977",
            snapshot: validSnapshot,
            status: .persisted
        )

        _ = try fixture.store.documentLibrary.permanentlyDeleteDocument(
            id: fixture.targetDocument.id
        )

        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: malformedRun.id)
                .assuranceState,
            OutputAssuranceState.stale.rawValue
        )
        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: validRun.id)
                .assuranceState,
            OutputAssuranceState.propositionSupported.rawValue,
            "a valid excluded import member without a document id is not a dependency"
        )
    }

    func testPartitionInputLineageAndMalformedInputsFailClosed() throws {
        // Expected RED: deletion scans exact partition slices and snapshots but
        // ignores the durable v1/custom input_revision_ids_json ledger.
        let fixture = try makeAnalysisFixture(caseName: "partition")
        let unrelatedSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: 1,
            members: [
                CorpusAnalysisSnapshotMember(
                    memberKey: "partition-unrelated-member-613",
                    documentID: fixture.unrelatedDocument.id,
                    displayName: fixture.unrelatedDocument.displayName,
                    revisionIDs: [fixture.unrelatedRevision.id],
                    disposition: .eligible
                ),
            ]
        )
        let targetInputRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "partition-target-run-613",
            snapshot: unrelatedSnapshot,
            status: .persisted
        )
        let malformedInputRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "partition-malformed-run-911",
            snapshot: unrelatedSnapshot,
            status: .persisted
        )
        let unrelatedInputRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "partition-unrelated-run-977",
            snapshot: unrelatedSnapshot,
            status: .persisted
        )
        try fixture.store.database.writer.write { db in
            try CorpusAnalysisPartitionRecord(
                id: "partition-target-613",
                runID: targetInputRun.id,
                partitionKey: "target-input",
                inputRevisionIDsJSON: try encoded([fixture.targetRevision.id]),
                disposition: CorpusAnalysisPartitionDisposition.succeeded.rawValue
            ).insert(db)
            try CorpusAnalysisPartitionRecord(
                id: "partition-malformed-911",
                runID: malformedInputRun.id,
                partitionKey: "malformed-input",
                inputRevisionIDsJSON: "{not-valid-json",
                disposition: CorpusAnalysisPartitionDisposition.succeeded.rawValue
            ).insert(db)
            try CorpusAnalysisPartitionRecord(
                id: "partition-unrelated-977",
                runID: unrelatedInputRun.id,
                partitionKey: "unrelated-input",
                inputRevisionIDsJSON: try encoded([fixture.unrelatedRevision.id]),
                disposition: CorpusAnalysisPartitionDisposition.succeeded.rawValue
            ).insert(db)
        }

        _ = try fixture.store.documentLibrary.permanentlyDeleteDocument(
            id: fixture.targetDocument.id
        )

        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: targetInputRun.id)
                .assuranceState,
            OutputAssuranceState.stale.rawValue
        )
        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: malformedInputRun.id)
                .assuranceState,
            OutputAssuranceState.stale.rawValue
        )
        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: unrelatedInputRun.id)
                .assuranceState,
            OutputAssuranceState.propositionSupported.rawValue
        )
    }

    func testDeletionStaleRunCannotBeResumedFinalizedOrClearedByCancellation() throws {
        // Expected RED: finalizeRun and prepareForResume clear deletion-set stale
        // assurance, while cancelRun silently erases it.
        let fixture = try makeAnalysisFixture(caseName: "terminal-stale")
        let targetSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: 1,
            members: [
                CorpusAnalysisSnapshotMember(
                    memberKey: "terminal-target-member-613",
                    documentID: fixture.targetDocument.id,
                    displayName: fixture.targetDocument.displayName,
                    revisionIDs: [fixture.targetRevision.id],
                    disposition: .eligible
                ),
            ]
        )
        let finalizeRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "terminal-finalize-run-613",
            snapshot: targetSnapshot,
            status: .running
        )
        let resumeRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "terminal-resume-run-911",
            snapshot: targetSnapshot,
            status: .cancelled
        )
        let cancelRun = try insertRun(
            store: fixture.store,
            matterID: fixture.matter.id,
            id: "terminal-cancel-run-977",
            snapshot: targetSnapshot,
            status: .running
        )

        _ = try fixture.store.documentLibrary.permanentlyDeleteDocument(
            id: fixture.targetDocument.id
        )
        let staleReason = try XCTUnwrap(
            fetchedRun(
                fixture.store,
                matterID: fixture.matter.id,
                id: cancelRun.id
            ).assuranceReasonsJSON
        )

        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.finalizeRun(
                matterID: fixture.matter.id,
                runID: finalizeRun.id,
                assuranceState: .propositionSupported,
                assuranceReasons: ["synthetic-incorrect-reassurance-613"],
                exclusionsDisclosed: true
            )
        )
        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: finalizeRun.id)
                .assuranceState,
            OutputAssuranceState.stale.rawValue
        )

        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.prepareForResume(
                matterID: fixture.matter.id,
                runID: resumeRun.id,
                maximumRetryCount: 2
            )
        )
        XCTAssertEqual(
            try fetchedRun(fixture.store, matterID: fixture.matter.id, id: resumeRun.id)
                .assuranceState,
            OutputAssuranceState.stale.rawValue
        )

        let cancelled = try fixture.store.corpusAnalysis.cancelRun(
            matterID: fixture.matter.id,
            runID: cancelRun.id
        )
        XCTAssertEqual(cancelled.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertEqual(cancelled.assuranceReasonsJSON, staleReason)
    }

    private func makeCrossMatterBoundary(caseName: String) throws -> CrossMatterBoundaryFixture {
        let store = try SupraStore.inMemory()
        let parentMatter = try store.matters.createMatter(name: "Boundary parent \(caseName) 613")
        let childMatter = try store.matters.createMatter(name: "Boundary child \(caseName) 911")
        let parent = try insertDocument(
            store: store,
            matterID: parentMatter.id,
            id: "boundary-parent-\(caseName)-613"
        )
        let childBlob = try insertBlob(store: store, id: "boundary-child-blob-\(caseName)-911")
        let child = MatterDocumentRecord(
            id: "boundary-child-\(caseName)-911",
            matterID: childMatter.id,
            blobID: childBlob.id,
            parentDocumentID: parent.id,
            displayName: "Boundary child \(caseName) 911.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue,
            sourceKind: DocumentSourceKind.text.rawValue
        )
        try store.database.writer.write { db in try child.insert(db) }
        let text = "Cross-matter boundary source evidence 613 remains intact."
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "boundary-child-revision-\(caseName)-911",
                documentID: child.id,
                partIndex: 0,
                derivationKey: "boundary-child-derivation-\(caseName)-911",
                origin: "parser",
                method: "synthetic",
                text: text,
                charCount: text.count,
                reason: "Cross-matter cascade boundary probe"
            )
        )
        let chunk = DocumentChunkRecord(
            id: "boundary-child-chunk-\(caseName)-911",
            documentID: child.id,
            revisionID: revision.id,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text,
            displayExcerpt: text
        )
        try store.documentIndex.replaceChunks(documentID: child.id, chunks: [chunk])
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: childMatter.id,
            mode: .guided,
            retrievalQuery: "boundary evidence 613"
        )
        let source = DocumentOutputSourceRecord(
            id: "boundary-child-source-\(caseName)-911",
            sourceSetID: sourceSet.id,
            documentID: child.id,
            chunkID: chunk.id,
            revisionID: revision.id,
            citationLabel: "S613",
            locatorJSON:
                "{\"char_end\":\(text.count),\"char_start\":0,\"part_index\":0,\"source_kind\":\"text\"}",
            excerpt: text,
            rank: 0
        )
        try store.documentSources.addOutputSource(source)
        return CrossMatterBoundaryFixture(
            store: store,
            parentMatter: parentMatter,
            childMatter: childMatter,
            parent: parent,
            child: child,
            childBlob: childBlob,
            childRevision: revision,
            childChunk: chunk,
            childSource: source
        )
    }

    private func assertCrossMatterBoundaryPreserved(
        _ fixture: CrossMatterBoundaryFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNotNil(
            try fixture.store.documentLibrary.fetchDocument(id: fixture.parent.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentLibrary.fetchDocument(id: fixture.child.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentLibrary.fetchBlob(id: fixture.childBlob.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentRevisions.fetchRevision(id: fixture.childRevision.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentIndex.fetchChunk(id: fixture.childChunk.id),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try fixture.store.database.writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM document_chunk_fts WHERE document_id = ?",
                    arguments: [fixture.child.id]
                ) ?? -1
            },
            1,
            file: file,
            line: line
        )
        let source = try XCTUnwrap(
            try fixture.store.documentSources.fetchSource(id: fixture.childSource.id),
            file: file,
            line: line
        )
        XCTAssertEqual(source.documentID, fixture.child.id, file: file, line: line)
        XCTAssertEqual(source.chunkID, fixture.childChunk.id, file: file, line: line)
        XCTAssertEqual(source.revisionID, fixture.childRevision.id, file: file, line: line)
    }

    private func makeAnalysisFixture(caseName: String) throws -> AnalysisFixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Analysis deletion \(caseName) 613")
        let target = try insertDocumentWithRevision(
            store: store,
            matterID: matter.id,
            id: "analysis-target-\(caseName)-613"
        )
        let unrelated = try insertDocumentWithRevision(
            store: store,
            matterID: matter.id,
            id: "analysis-unrelated-\(caseName)-911"
        )
        return AnalysisFixture(
            store: store,
            matter: matter,
            targetDocument: target.document,
            targetRevision: target.revision,
            unrelatedDocument: unrelated.document,
            unrelatedRevision: unrelated.revision
        )
    }

    private func insertDocumentWithRevision(
        store: SupraStore,
        matterID: String,
        id: String
    ) throws -> (document: MatterDocumentRecord, revision: DocumentPartRevisionRecord) {
        let document = try insertDocument(store: store, matterID: matterID, id: id)
        let text = "Synthetic immutable revision for \(id)."
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "\(id)-revision",
                documentID: document.id,
                partIndex: 0,
                derivationKey: "\(id)-derivation",
                origin: "parser",
                method: "synthetic",
                text: text,
                charCount: text.count,
                reason: "Permanent deletion dependency probe"
            )
        )
        return (document, revision)
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        id: String
    ) throws -> MatterDocumentRecord {
        let blob = try insertBlob(store: store, id: "\(id)-blob")
        return try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: id,
                matterID: matterID,
                blobID: blob.id,
                displayName: "\(id).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue
            )
        )
    }

    private func insertBlob(store: SupraStore, id: String) throws -> DocumentBlobRecord {
        try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: id,
                sha256: String(id.utf8.map { String(format: "%02x", $0) }.joined().prefix(64))
                    .padding(toLength: 64, withPad: "0", startingAt: 0),
                byteSize: 613,
                originalExtension: "txt",
                managedRelativePath: "blobs/\(id).txt"
            )
        ).blob
    }

    private func insertRun(
        store: SupraStore,
        matterID: String,
        id: String,
        snapshot: CorpusAnalysisSnapshot,
        status: CorpusAnalysisRunStatus
    ) throws -> CorpusAnalysisRunRecord {
        let run = CorpusAnalysisRunRecord(
            id: id,
            runKey: "\(id)-key",
            matterID: matterID,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: "{\"schema_version\":1}",
            corpusSnapshotJSON: try encoded(snapshot),
            partitionStrategy: "synthetic_custom_v1",
            partitionStrategyVersion: 1,
            status: status.rawValue,
            assuranceState: OutputAssuranceState.propositionSupported.rawValue,
            assuranceReasonsJSON: "[]"
        )
        try store.database.writer.write { db in try run.insert(db) }
        return run
    }

    private func fetchedRun(
        _ store: SupraStore,
        matterID: String,
        id: String
    ) throws -> CorpusAnalysisRunRecord {
        try XCTUnwrap(try store.corpusAnalysis.fetchRun(matterID: matterID, id: id))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct CrossMatterBoundaryFixture {
    let store: SupraStore
    let parentMatter: MatterRecord
    let childMatter: MatterRecord
    let parent: MatterDocumentRecord
    let child: MatterDocumentRecord
    let childBlob: DocumentBlobRecord
    let childRevision: DocumentPartRevisionRecord
    let childChunk: DocumentChunkRecord
    let childSource: DocumentOutputSourceRecord
}

private struct AnalysisFixture {
    let store: SupraStore
    let matter: MatterRecord
    let targetDocument: MatterDocumentRecord
    let targetRevision: DocumentPartRevisionRecord
    let unrelatedDocument: MatterDocumentRecord
    let unrelatedRevision: DocumentPartRevisionRecord
}
