import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class CorpusAnalysisSubmissionTests: XCTestCase {
    func testCorpusStore01PreparedLedgerAndQueueJobCommitAtomicallyAndRetryExactlyOnce() throws {
        // T-CORPUS-STORE-01 standing guard: Store owns the single transaction
        // that commits a v2 frozen corpus ledger and its runnable queue job.
        // The current Sessions producer must prepare first and enqueue second,
        // leaving a crash window with an orphan planning run.
        let fixture = try makeFixture(marker: "atomic-4107")
        let foreignMatter = try fixture.store.matters.createMatter(
            name: "Foreign collision matter 4107"
        )
        let collidingJob = DocumentProcessingJobRecord(
            id: fixture.job.id,
            matterID: foreignMatter.id,
            kind: DocumentProcessingJobKind.process.rawValue,
            payloadJSON: #"{"foreign":"QUEUE-COLLISION-4107"}"#,
            queuePosition: 0
        )
        try fixture.store.database.writer.write { db in
            try collidingJob.insert(db)
        }

        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: fixture.job
            ),
            "a job insertion failure after ledger insertion must roll back the entire submission"
        )
        XCTAssertNil(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matterID,
                id: fixture.run.id
            ),
            "the failed atomic submission must leave no planning run"
        )
        try assertCounts(
            fixture.store,
            matterID: fixture.matterID,
            runID: fixture.run.id,
            runs: 0,
            partitions: 0,
            slices: 0,
            corpusJobs: 0
        )

        var retryJob = fixture.job
        retryJob.id = "corpus-analysis-job-retry-4107"
        try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
            run: fixture.run,
            partitions: [fixture.partition],
            slices: [fixture.slice],
            job: retryJob
        )
        try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
            run: fixture.run,
            partitions: [fixture.partition],
            slices: [fixture.slice],
            job: retryJob
        )

        try assertCounts(
            fixture.store,
            matterID: fixture.matterID,
            runID: fixture.run.id,
            runs: 1,
            partitions: 1,
            slices: 1,
            corpusJobs: 1
        )
        let persistedJob = try XCTUnwrap(
            fixture.store.documentJobs.fetchJob(id: retryJob.id)
        )
        XCTAssertEqual(persistedJob.matterID, fixture.matterID)
        XCTAssertEqual(persistedJob.kind, DocumentProcessingJobKind.corpusAnalysis.rawValue)
        XCTAssertEqual(persistedJob.status, DocumentProcessingJobStatus.queued.rawValue)
        XCTAssertEqual(
            persistedJob.queuePosition,
            1,
            "the atomic submission must preserve the existing app-wide FIFO denominator"
        )
        XCTAssertEqual(persistedJob.payloadJSON, fixture.payloadJSON)
        XCTAssertFalse(
            persistedJob.payloadJSON?.contains("DEFAULT-RUN-0000") ?? false,
            "the exact queue payload must not fall back to a default run identity"
        )

        var duplicateJob = retryJob
        duplicateJob.id = "corpus-analysis-duplicate-job-4107"
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: duplicateJob
            ),
            "one frozen run must never acquire a second runnable queue identity"
        )
        try assertCounts(
            fixture.store,
            matterID: fixture.matterID,
            runID: fixture.run.id,
            runs: 1,
            partitions: 1,
            slices: 1,
            corpusJobs: 1
        )
    }

    func testCorpusStore02SubmissionRejectsMatterAndPayloadIdentityMismatchWithoutPartialRows() throws {
        // T-CORPUS-STORE-02 standing guard: the Store-owned submission boundary
        // validates the layer-owned queue identity: pristine corpus job state,
        // matching matter, and a v2 envelope naming the frozen run and digest.
        let fixture = try makeFixture(marker: "scope-4199")
        let foreignMatter = try fixture.store.matters.createMatter(
            name: "Foreign submission matter 4199"
        )

        var wrongMatterJob = fixture.job
        wrongMatterJob.id = "corpus-analysis-wrong-matter-job-4199"
        wrongMatterJob.matterID = foreignMatter.id
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: wrongMatterJob
            )
        )

        var wrongRunJob = fixture.job
        wrongRunJob.id = "corpus-analysis-wrong-run-job-4199"
        wrongRunJob.payloadJSON = payloadJSON(
            matterID: fixture.matterID,
            runID: "FOREIGN-RUN-4199",
            requestDigest: fixture.run.requestDigest ?? "",
            runKey: fixture.run.runKey,
            documentID: fixture.documentID
        )
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: wrongRunJob
            )
        )

        var wrongDigestJob = fixture.job
        wrongDigestJob.id = "corpus-analysis-wrong-digest-job-4199"
        wrongDigestJob.payloadJSON = payloadJSON(
            matterID: fixture.matterID,
            runID: fixture.run.id,
            requestDigest: String(repeating: "f", count: 64),
            runKey: fixture.run.runKey,
            documentID: fixture.documentID
        )
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: wrongDigestJob
            )
        )

        var wrongKindJob = fixture.job
        wrongKindJob.id = "corpus-analysis-wrong-kind-job-4199"
        wrongKindJob.kind = DocumentProcessingJobKind.process.rawValue
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: wrongKindJob
            ),
            "atomic corpus submission must reject a non-corpus queue kind"
        )

        var dirtyLifecycleJob = fixture.job
        dirtyLifecycleJob.id = "corpus-analysis-dirty-lifecycle-job-4199"
        dirtyLifecycleJob.status = DocumentProcessingJobStatus.active.rawValue
        dirtyLifecycleJob.phase = DocumentProcessingPhase.analyzingCorpus.rawValue
        dirtyLifecycleJob.queuePosition = 99
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: dirtyLifecycleJob
            ),
            "atomic submission must begin with a pristine unpositioned queued job"
        )

        var malformedJob = fixture.job
        malformedJob.id = "corpus-analysis-malformed-job-4199"
        malformedJob.payloadJSON = #"{"schema_version":2,"run_id":"MALFORMED-4199"}"#
        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: malformedJob
            )
        )

        try assertCounts(
            fixture.store,
            matterID: fixture.matterID,
            runID: fixture.run.id,
            runs: 0,
            partitions: 0,
            slices: 0,
            corpusJobs: 0
        )
        XCTAssertTrue(
            try fixture.store.documentJobs.fetchJobs(matterID: foreignMatter.id).isEmpty,
            "a cross-matter submission must not create a foreign queue row"
        )
    }

    func testCorpusStore03LegacySameRunEnvelopeCannotAcquireSecondQueueIdentity() throws {
        // T-CORPUS-STORE-03 standing guard: duplicate detection must also see a
        // durable legacy corpus job whose minimal envelope exposes the same run_id.
        let fixture = try makeFixture(marker: "legacy-duplicate-4273")
        _ = try fixture.store.corpusAnalysis.createOrFetchPreparedRun(
            run: fixture.run,
            partitions: [fixture.partition],
            slices: [fixture.slice]
        )
        let legacyJob = try fixture.store.documentJobs.enqueueJob(
            matterID: fixture.matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: "{\"run_id\":\"\(fixture.run.id)\"}"
        )
        XCTAssertNotEqual(legacyJob.id, fixture.job.id)

        do {
            _ = try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: fixture.job
            )
            XCTFail(
                "a frozen run named by any existing corpus job must reject a second queue identity"
            )
            return
        } catch {
            let corpusJobs = try fixture.store.documentJobs.fetchJobs(
                matterID: fixture.matterID
            ).filter {
                $0.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue
            }
            XCTAssertEqual(corpusJobs.map(\.id), [legacyJob.id])
        }
    }

    func testCorpusStore04ApprovedWholeMatterReceiptIsRecheckedAgainstLiveScopeAtomically() throws {
        // T-CORPUS-STORE-04 standing guard: atomic prepared submission must bind
        // the user-approved receipt and reconstruct live scope inside its writer
        // transaction, rejecting a changed whole-matter denominator.
        let fixture = try makeFixture(
            marker: "approved-receipt-drift-4314",
            wholeMatter: true
        )
        let lateDocumentID = "corpus-analysis-late-document-4314"
        let lateRevisionID = "corpus-analysis-late-revision-4314"
        let lateDocument = try insertEligibleDocument(
            store: fixture.store,
            matterID: fixture.matterID,
            documentID: lateDocumentID,
            revisionID: lateRevisionID,
            marker: "LATE-LIVE-SCOPE-CANARY-4314"
        )
        XCTAssertFalse(
            fixture.approvedScopeReceipt.members.contains { $0.documentID == lateDocument.id },
            "the approved receipt must remain the pre-mutation one-member denominator"
        )

        XCTAssertThrowsError(
            try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                run: fixture.run,
                partitions: [fixture.partition],
                slices: [fixture.slice],
                job: fixture.job,
                approvedScopeReceipt: fixture.approvedScopeReceipt
            )
        ) { error in
            XCTAssertEqual(
                error as? CorpusAnalysisRepositoryError,
                .scopeReceiptChanged
            )
        }
        try assertCounts(
            fixture.store,
            matterID: fixture.matterID,
            runID: fixture.run.id,
            runs: 0,
            partitions: 0,
            slices: 0,
            corpusJobs: 0
        )
        XCTAssertEqual(
            try fixture.store.documentLibrary.fetchDocument(id: lateDocumentID)?.displayName,
            "Corpus analysis late source LATE-LIVE-SCOPE-CANARY-4314.txt",
            "receipt rejection must not erase the independently committed late document"
        )
        XCTAssertEqual(
            try fixture.store.documentIndex.fetchParts(documentID: lateDocumentID)
                .map(\.currentRevisionID),
            [lateRevisionID]
        )
        XCTAssertEqual(
            try fixture.store.documentRevisions.fetchRevision(id: lateRevisionID)?.text,
            "LATE-LIVE-SCOPE-CANARY-4314-NONDEFAULT-TEXT"
        )
        XCTAssertEqual(
            try fixture.store.documentLibrary.fetchDocuments(matterID: fixture.matterID)
                .map(\.id).sorted(),
            [fixture.documentID, lateDocumentID].sorted()
        )
    }

    private func makeFixture(
        marker: String,
        wholeMatter: Bool = false
    ) throws -> SubmissionFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusAnalysisSubmission-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Corpus analysis matter \(marker)")
        let text = "GUIDED-REVIEW-EXACT-TEXT-\(marker)-NONDEFAULT"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "corpus-analysis-blob-\(marker)",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/corpus-analysis-\(marker).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Corpus analysis source \(marker).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "corpus-analysis-part-\(marker)",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "corpus-analysis-revision-\(marker)",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "corpus-analysis-derivation-\(marker)",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "corpus-analysis-selection-\(marker)",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "corpus-analysis-selection-key-\(marker)",
            selectedBy: "test",
            decisionJSON: #"{"rule":"corpus-analysis-atomic-submission"}"#
        )
        let persistedParts = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        XCTAssertTrue(
            persistedParts.isEmpty,
            "a newly inserted synthetic part has no pre-existing user edit to preserve"
        )

        let runID = "corpus-analysis-run-\(marker)"
        let partitionID = "corpus-analysis-partition-\(marker)"
        let memberKey = "document:\(document.id)"
        let requestDigest = SHA256.hash(data: Data("digest-\(marker)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let snapshot = CorpusAnalysisSnapshot(
            schemaVersion: 2,
            members: [CorpusAnalysisSnapshotMember(
                memberKey: memberKey,
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: [revision.id],
                indexState: document.indexStatus,
                disposition: .eligible
            )]
        )
        let run = CorpusAnalysisRunRecord(
            id: runID,
            runKey: "corpus-analysis-key-\(marker)",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: wholeMatter
                ? #"{"schema_version":1}"#
                : "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":2}",
            corpusSnapshotJSON: try canonicalJSON(snapshot),
            partitionStrategy: "exact_revision_slice:characters=8192",
            partitionStrategyVersion: 2,
            modelLineageJSON: #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/corpus-analysis","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#,
            status: CorpusAnalysisRunStatus.planning.rawValue,
            requestSchemaVersion: 2,
            requestDigest: requestDigest
        )
        let partition = CorpusAnalysisPartitionRecord(
            id: partitionID,
            runID: runID,
            partitionKey: "000000|\(memberKey)#revision:\(revision.id)#chars:0-\(text.count)",
            inputRevisionIDsJSON: try canonicalJSON([revision.id])
        )
        let slice = CorpusAnalysisPartitionSliceRecord(
            id: "corpus-analysis-slice-\(marker)",
            runID: runID,
            partitionID: partitionID,
            ordinal: 0,
            memberKey: memberKey,
            documentID: document.id,
            partIndex: 0,
            revisionID: revision.id,
            charStart: 0,
            charEnd: text.count,
            revisionCharCount: text.count,
            textSHA256: SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            locatorJSON: "{\"source_kind\":\"text\",\"char_start\":0,\"char_end\":\(text.count)}"
        )
        let payload = payloadJSON(
            matterID: matter.id,
            runID: runID,
            requestDigest: requestDigest,
            runKey: run.runKey,
            documentID: document.id,
            wholeMatter: wholeMatter
        )
        let job = DocumentProcessingJobRecord(
            id: "corpus-analysis-job-\(marker)",
            matterID: matter.id,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payload
        )
        return SubmissionFixture(
            store: store,
            matterID: matter.id,
            documentID: document.id,
            run: run,
            partition: partition,
            slice: slice,
            approvedScopeReceipt: snapshot,
            payloadJSON: payload,
            job: job
        )
    }

    private func insertEligibleDocument(
        store: SupraStore,
        matterID: String,
        documentID: String,
        revisionID: String,
        marker: String
    ) throws -> MatterDocumentRecord {
        let text = "\(marker)-NONDEFAULT-TEXT"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "corpus-analysis-late-blob-\(marker)",
            sha256: "corpus-analysis-late-sha-\(marker)",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/corpus-analysis-late-\(marker).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: documentID,
            matterID: matterID,
            blobID: blob.id,
            displayName: "Corpus analysis late source \(marker).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "corpus-analysis-late-part-\(marker)",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: revisionID,
            documentID: document.id,
            partIndex: 0,
            derivationKey: "corpus-analysis-late-derivation-\(marker)",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "corpus-analysis-late-selection-\(marker)",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "corpus-analysis-late-selection-key-\(marker)",
            selectedBy: "test",
            decisionJSON: #"{"rule":"corpus-analysis-live-scope-counterexample"}"#
        )
        let persistedParts = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        XCTAssertTrue(
            persistedParts.isEmpty,
            "a newly inserted late source has no earlier user edit to preserve"
        )
        return document
    }

    private func payloadJSON(
        matterID: String,
        runID: String,
        requestDigest: String,
        runKey: String,
        documentID: String,
        wholeMatter: Bool = false
    ) -> String {
        let scopeJSON = wholeMatter
            ? #"{"schema_version":1}"#
            : "{\"document_ids\":[\"\(documentID)\"],\"schema_version\":2}"
        return """
        {"pinned_model":{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/corpus-analysis","model_revision":"0123456789abcdef0123456789abcdef01234567"},"request_digest":"\(requestDigest)","run_id":"\(runID)","schema_version":2,"task":{"kind":"exhaustive_list","request":{"character_budget":8192,"matter_id":"\(matterID)","maximum_retry_count":2,"prompt_builder_version":"exhaustive-list-v1","query":"Extract NONDEFAULT-RENEWAL-4199","run_key":"\(runKey)","scope":\(scopeJSON),"task_schema_version":1,"title":"Corpus Analysis 4199"}}}
        """
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func assertCounts(
        _ store: SupraStore,
        matterID: String,
        runID: String,
        runs: Int,
        partitions: Int,
        slices: Int,
        corpusJobs: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_runs WHERE id = ?", arguments: [runID]),
                runs,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = ?", arguments: [runID]),
                partitions,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices WHERE run_id = ?", arguments: [runID]),
                slices,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM document_processing_jobs WHERE matter_id = ? AND kind = ?",
                    arguments: [matterID, DocumentProcessingJobKind.corpusAnalysis.rawValue]
                ),
                corpusJobs,
                file: file,
                line: line
            )
        }
    }
}

private struct SubmissionFixture {
    var store: SupraStore
    var matterID: String
    var documentID: String
    var run: CorpusAnalysisRunRecord
    var partition: CorpusAnalysisPartitionRecord
    var slice: CorpusAnalysisPartitionSliceRecord
    var approvedScopeReceipt: CorpusAnalysisSnapshot
    var payloadJSON: String
    var job: DocumentProcessingJobRecord
}
