import CryptoKit
import Foundation
import GRDB
import SupraCore

public enum CorpusAnalysisRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case runKeyCollision(String)
    case runScopeMismatch(String)
    case partitionScopeMismatch(String)
    case partitionIdentityCollision(String)
    case terminalDispositionConflict(String)
    case invalidAttemptHistory(String)
    case attemptNotRunning(String)
    case invalidSnapshot
    case invalidStatusTransition(String)
    case corpusCompleteRequiresAllSucceeded
    case corpusCompleteRequiresDisclosedExclusions
    case v2RequiresAtomicPreparation
    case invalidPreparedRun(String)
    case corpusCompleteRequiresV2Request
    case corpusCompleteRequiresExactSliceCoverage
    case invalidStructuredOutputAttachment(String)
    case staleRunRequiresNewRun(String)
    case scopeReceiptChanged

    public var errorDescription: String? {
        switch self {
        case .runKeyCollision(let key): "Corpus run key \(key) was reused for different immutable inputs."
        case .runScopeMismatch(let id): "Corpus run \(id) does not belong to the selected matter."
        case .partitionScopeMismatch(let id): "Corpus partition \(id) does not belong to the selected run."
        case .partitionIdentityCollision(let key): "Corpus partition key \(key) was reused for different revisions."
        case .terminalDispositionConflict(let id): "Corpus partition \(id) already has a different terminal disposition."
        case .invalidAttemptHistory(let id): "Corpus partition \(id) has invalid attempt history."
        case .attemptNotRunning(let id): "Corpus partition \(id) has no running attempt to finish."
        case .invalidSnapshot: "The corpus snapshot could not be decoded."
        case .invalidStatusTransition(let transition): "Invalid corpus run transition: \(transition)."
        case .corpusCompleteRequiresAllSucceeded: "Corpus-complete requires a balanced ledger with every partition succeeded."
        case .corpusCompleteRequiresDisclosedExclusions: "Corpus-complete requires every excluded snapshot member to be disclosed."
        case .v2RequiresAtomicPreparation:
            "Version 2 corpus runs must persist the run, partitions, and exact slices atomically."
        case .invalidPreparedRun(let reason):
            "The prepared corpus run is not a complete, exact frozen request: \(reason)."
        case .corpusCompleteRequiresV2Request:
            "Corpus-complete exhaustive-list output requires version 2 frozen request lineage."
        case .corpusCompleteRequiresExactSliceCoverage:
            "Corpus-complete requires exact, once-only Character-range coverage."
        case .invalidStructuredOutputAttachment(let id):
            "Structured output version \(id) is not a compatible one-time attachment for this corpus run."
        case .staleRunRequiresNewRun(let id):
            "Corpus run \(id) was invalidated by a source change and cannot regain assurance; start a new run."
        case .scopeReceiptChanged:
            "The approved corpus scope changed before the frozen run could be submitted."
        }
    }
}

/// Owns the v064 frozen-run and partition ledger. Immutable planning inputs are
/// insert-only; lifecycle/result fields advance through scoped transactions.
public final class CorpusAnalysisRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Reconstructs the current exact denominator and its eligible selected
    /// revisions in one database snapshot. This is the shared authority for
    /// preview/planning and the atomic submission receipt check.
    public func inspectCurrentScope(
        matterID: String,
        documentIDs: [String]?
    ) throws -> CorpusAnalysisScopeInspection {
        try writer.read { db in
            try Self.inspectCurrentScope(
                matterID: matterID,
                documentIDs: documentIDs,
                db: db
            )
        }
    }

    @discardableResult
    public func createOrFetchRun(_ proposed: CorpusAnalysisRunRecord) throws -> CorpusAnalysisRunRecord {
        guard proposed.requestSchemaVersion != 2 else {
            throw CorpusAnalysisRepositoryError.v2RequiresAtomicPreparation
        }
        return try writer.write { db in
            if let existing = try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
                arguments: [proposed.matterID, proposed.runKey]
            ) {
                guard Self.sameImmutableRun(existing, proposed) else {
                    throw CorpusAnalysisRepositoryError.runKeyCollision(proposed.runKey)
                }
                return existing
            }
            try proposed.insert(db)
            return proposed
        }
    }

    /// Persists one runnable exact-slice request as a single transaction. No run can
    /// become visible without every planned partition and its exact frozen text
    /// slices. Exact retries return the already-prepared run after revalidating
    /// its durable ledger; semantic run-key reuse fails closed.
    @discardableResult
    public func createOrFetchPreparedRun(
        run proposed: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> CorpusAnalysisRunRecord {
        return try writer.write { db in
            try Self.createOrFetchPreparedRun(
                run: proposed,
                partitions: partitions,
                slices: slices,
                db: db
            )
        }
    }

    /// Atomically publishes a frozen v2 corpus ledger and the one app-wide FIFO
    /// job that can execute it. The queue payload remains owned by SupraSessions;
    /// Store validates only its versioned outer identity before persisting it.
    /// Exact retries return the existing job, while a second job identity for the
    /// same run fails closed.
    @discardableResult
    public func submitPreparedCorpusAnalysis(
        run: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        job: DocumentProcessingJobRecord
    ) throws -> DocumentProcessingJobRecord {
        guard let approvedScopeReceipt = Self.snapshot(from: run) else {
            throw CorpusAnalysisRepositoryError.invalidSnapshot
        }
        return try submitPreparedCorpusAnalysis(
            run: run,
            partitions: partitions,
            slices: slices,
            job: job,
            approvedScopeReceipt: approvedScopeReceipt
        )
    }

    /// Publishes only when the proposed frozen snapshot and a fresh reconstruction
    /// of the live scope both equal the exact receipt approved by the caller. The
    /// live comparison shares the writer transaction with every inserted ledger
    /// row and the FIFO job, closing the final compare-to-submit mutation window.
    @discardableResult
    public func submitPreparedCorpusAnalysis(
        run: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        job: DocumentProcessingJobRecord,
        approvedScopeReceipt: CorpusAnalysisSnapshot
    ) throws -> DocumentProcessingJobRecord {
        guard Self.isPristineCorpusAnalysisJob(job, for: run),
              let proposedPayload = Self.corpusSubmissionEnvelope(job.payloadJSON),
              proposedPayload.schemaVersion == 2,
              proposedPayload.runID == run.id,
              proposedPayload.requestDigest == run.requestDigest else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                "the queue job is not a pristine v2 submission for the frozen run"
            )
        }

        return try writer.write { db in
            guard let proposedScopeReceipt = Self.snapshot(from: run),
                  proposedScopeReceipt == approvedScopeReceipt else {
                throw CorpusAnalysisRepositoryError.scopeReceiptChanged
            }
            guard let scope = Self.scope(from: run) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "the frozen scope is not a reconstructible document scope"
                )
            }
            let liveScopeReceipt = try Self.inspectCurrentScope(
                matterID: run.matterID,
                documentIDs: scope.documentIDs,
                db: db
            ).snapshot
            guard liveScopeReceipt == approvedScopeReceipt else {
                throw CorpusAnalysisRepositoryError.scopeReceiptChanged
            }

            let runAlreadyExisted = try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
                arguments: [run.matterID, run.runKey]
            ) != nil
            let persistedRun = try Self.createOrFetchPreparedRun(
                run: run,
                partitions: partitions,
                slices: slices,
                db: db
            )
            guard persistedRun.id == run.id else {
                throw CorpusAnalysisRepositoryError.runKeyCollision(run.runKey)
            }

            let runJobs = try DocumentProcessingJobRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE kind = ?",
                arguments: [DocumentProcessingJobKind.corpusAnalysis.rawValue]
            ).filter {
                Self.corpusSubmissionRunID($0.payloadJSON) == persistedRun.id
            }
            guard runJobs.count <= 1 else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "the frozen run has multiple queue job identities"
                )
            }

            if let existingJob = try DocumentProcessingJobRecord.fetchOne(db, key: job.id) {
                guard runAlreadyExisted,
                      runJobs.first?.id == existingJob.id,
                      Self.sameCorpusSubmission(existingJob, job) else {
                    throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                        "the queue job identity is already owned by another submission"
                    )
                }
                return existingJob
            }

            guard runJobs.isEmpty else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "the frozen run already has a queue job identity"
                )
            }

            let maxPosition = try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(queue_position) FROM document_processing_jobs
                    WHERE status IN (?, ?)
                    """,
                arguments: [
                    DocumentProcessingJobStatus.queued.rawValue,
                    DocumentProcessingJobStatus.active.rawValue
                ]
            ) ?? -1
            var persistedJob = job
            persistedJob.queuePosition = maxPosition + 1
            try persistedJob.insert(db)
            return persistedJob
        }
    }

    /// Atomically cancels one queued or durably paused corpus-analysis job and
    /// its exact frozen run. The job payload is the authority that joins the two
    /// records; malformed, cross-matter, duplicate, and terminal identities fail
    /// closed without changing either ledger.
    @discardableResult
    public func cancelQueuedOrPausedCorpusAnalysis(jobID: String) throws -> Bool {
        try writer.write { db in
            guard var job = try DocumentProcessingJobRecord.fetchOne(db, key: jobID),
                  job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue,
                  job.importBatchID == nil,
                  job.status == DocumentProcessingJobStatus.queued.rawValue
                    || job.status == DocumentProcessingJobStatus.paused.rawValue,
                  let payload = Self.corpusSubmissionEnvelope(job.payloadJSON),
                  payload.schemaVersion == 2,
                  var run = try CorpusAnalysisRunRecord.fetchOne(db, key: payload.runID),
                  run.matterID == job.matterID,
                  run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                  run.requestSchemaVersion == 2,
                  run.requestDigest == payload.requestDigest,
                  run.status != CorpusAnalysisRunStatus.persisted.rawValue,
                  run.status != CorpusAnalysisRunStatus.failed.rawValue,
                  run.status != CorpusAnalysisRunStatus.cancelled.rawValue else {
                return false
            }

            let jobsForRun = try DocumentProcessingJobRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_processing_jobs WHERE kind = ?",
                arguments: [DocumentProcessingJobKind.corpusAnalysis.rawValue]
            ).filter {
                Self.corpusSubmissionRunID($0.payloadJSON) == run.id
            }
            guard jobsForRun.count == 1, jobsForRun[0].id == job.id else {
                return false
            }

            let now = Date()
            var partitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
                arguments: [run.id]
            )
            for index in partitions.indices
                where partitions[index].disposition == CorpusAnalysisPartitionDisposition.pending.rawValue {
                partitions[index].disposition = CorpusAnalysisPartitionDisposition.cancelled.rawValue
                partitions[index].dispositionReason = partitions[index].dispositionReason ?? "run_cancelled"
                partitions[index].errorSummary = partitions[index].errorSummary ?? "Corpus analysis cancelled."
                partitions[index].completedAt = now
                try partitions[index].update(db)
            }

            let preservesStaleAssurance =
                run.assuranceState == OutputAssuranceState.stale.rawValue
            run.status = CorpusAnalysisRunStatus.cancelled.rawValue
            run.coverageJSON = try canonicalJSON(try calculateCoverage(
                db,
                run: run,
                exclusionsDisclosed: true
            ))
            if !preservesStaleAssurance {
                run.assuranceState = nil
                run.assuranceReasonsJSON = nil
            }
            run.completedAt = now
            try run.update(db)

            job.status = DocumentProcessingJobStatus.cancelled.rawValue
            job.phase = DocumentProcessingPhase.cancelled.rawValue
            job.queuePosition = nil
            job.completedAt = now
            job.updatedAt = now
            try job.update(db)
            return true
        }
    }

    public func fetchRun(matterID: String, id: String) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE id = ? AND matter_id = ?",
                arguments: [id, matterID]
            )
        }
    }

    public func fetchRun(matterID: String, runKey: String) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
                arguments: [matterID, runKey]
            )
        }
    }

    /// Resolves the one persisted v2 exact proof root permitted to authorize an
    /// exhaustive structured-output version. Ambiguous or legacy links fail
    /// closed so export callers never infer proof from version metadata alone.
    public func fetchExactExportRun(
        matterID: String,
        structuredOutputVersionID: String
    ) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            let runs = try CorpusAnalysisRunRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_runs
                    WHERE matter_id = ?
                      AND structured_output_version_id = ?
                      AND task_kind = 'exhaustive_list'
                      AND request_schema_version = 2
                      AND partition_strategy_version = 2
                      AND partition_strategy GLOB 'exact_revision_slice*'
                      AND status = 'persisted'
                      AND assurance_state IN ('corpus_complete', 'proposition_supported')
                    ORDER BY id
                    """,
                arguments: [matterID, structuredOutputVersionID]
            )
            guard runs.count == 1 else { return nil }
            let run = runs[0]
            guard try CorpusAnalysisProofIdentity.attachedSourceSetMatchesFrozenCorpus(
                versionID: structuredOutputVersionID,
                run: run,
                db: db
            ) else {
                return nil
            }
            return run
        }
    }

    /// Resolves an exact exhaustive-list run that can seed a Review Project.
    /// Export eligibility remains unchanged: this accessor first accepts the
    /// existing export contract, then narrowly admits a fully covered
    /// `corpus_incomplete` result when retained contrary evidence is the only
    /// failed required verification dimension.
    public func fetchExactReviewRun(
        matterID: String,
        structuredOutputVersionID: String
    ) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            try Self.fetchExactReviewRun(
                in: db,
                matterID: matterID,
                structuredOutputVersionID: structuredOutputVersionID
            )
        }
    }

    /// Transaction-scoped form used while atomically freezing a Review Project.
    /// Keeping the complete admission decision on the caller's database handle
    /// prevents a mutable corpus-incomplete proof from changing between
    /// validation and the durable Review snapshot.
    static func fetchExactReviewRun(
        in db: Database,
        matterID: String,
        structuredOutputVersionID: String
    ) throws -> CorpusAnalysisRunRecord? {
        let exportRuns = try CorpusAnalysisRunRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM corpus_analysis_runs
                WHERE matter_id = ?
                  AND structured_output_version_id = ?
                  AND task_kind = 'exhaustive_list'
                  AND request_schema_version = 2
                  AND partition_strategy_version = 2
                  AND partition_strategy GLOB 'exact_revision_slice*'
                  AND status = 'persisted'
                  AND assurance_state IN ('corpus_complete', 'proposition_supported')
                ORDER BY id
                """,
            arguments: [matterID, structuredOutputVersionID]
        )
        if exportRuns.count == 1,
           let exportRun = exportRuns.first,
           try CorpusAnalysisProofIdentity.attachedSourceSetMatchesFrozenCorpus(
               versionID: structuredOutputVersionID,
               run: exportRun,
               db: db
           ) {
            return exportRun
        }

        let runs = try CorpusAnalysisRunRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_runs
                    WHERE matter_id = ?
                      AND structured_output_version_id = ?
                      AND task_kind = 'exhaustive_list'
                      AND request_schema_version = 2
                      AND partition_strategy_version = 2
                      AND partition_strategy GLOB 'exact_revision_slice*'
                      AND status = 'persisted'
                      AND assurance_state = 'corpus_incomplete'
                    ORDER BY id
                    """,
                arguments: [matterID, structuredOutputVersionID]
            )
            guard runs.count == 1 else { return nil }
            let run = runs[0]

            // The relaxed path must still have one proof owner across every
            // assurance state, not merely one corpus-incomplete candidate.
            guard try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM corpus_analysis_runs
                    WHERE matter_id = ?
                      AND structured_output_version_id = ?
                      AND task_kind = 'exhaustive_list'
                      AND request_schema_version = 2
                      AND partition_strategy_version = 2
                      AND partition_strategy GLOB 'exact_revision_slice*'
                    """,
                arguments: [matterID, structuredOutputVersionID]
            ) == 1,
            run.requestDigest.map(Self.isSHA256) == true,
            run.completedAt != nil,
            let version = try StructuredOutputVersionRecord.fetchOne(
                db,
                key: structuredOutputVersionID
            ),
            version.assuranceState == OutputAssuranceState.corpusIncomplete.rawValue,
            version.staleReason == nil,
            version.verificationStatus == OutputVerificationStatus.needsReview.rawValue,
            let output = try StructuredOutputRecord.fetchOne(db, key: version.structuredOutputID),
            output.matterID == matterID,
            output.outputType == StructuredOutputType.documentExhaustiveList.rawValue,
            output.activeVersionID == version.id,
            output.status == StructuredOutputStatus.needsReview.rawValue,
            output.deletedAt == nil else {
                return nil
            }

            guard let coverageJSON = run.coverageJSON,
                  let coverage = try? JSONDecoder().decode(
                      CorpusAnalysisCoverage.self,
                      from: Data(coverageJSON.utf8)
                  ),
                  coverage.schemaVersion == 1,
                  coverage.partitionCount > 0,
                  coverage.pendingPartitionCount == 0,
                  coverage.failedPartitionCount == 0,
                  coverage.cancelledPartitionCount == 0,
                  coverage.excludedPartitionCount == 0,
                  coverage.balanceErrorCount == 0,
                  coverage.succeededPartitionCount == coverage.partitionCount,
                  coverage.terminalPartitionCount == coverage.partitionCount,
                  coverage.excludedMemberCount == 0,
                  coverage.snapshotMemberCount == coverage.eligibleMemberCount,
                  coverage.excludedMembersDisclosed else {
                return nil
            }

            let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_partitions
                    WHERE run_id = ? ORDER BY partition_key, id
                    """,
                arguments: [run.id]
            )
            let slices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_partition_slices
                    WHERE run_id = ? ORDER BY partition_id, ordinal, id
                    """,
                arguments: [run.id]
            )
            guard partitions.count == coverage.partitionCount,
                  partitions.allSatisfy({
                      $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue
                  }) else {
                return nil
            }
            do {
                try Self.validatePreparedRun(
                    run,
                    partitions: partitions,
                    slices: slices,
                    db: db,
                    requireLiveCurrentRevision: true
                )
            } catch {
                return nil
            }

            guard let snapshot = try? JSONDecoder().decode(
                CorpusAnalysisSnapshot.self,
                from: Data(run.corpusSnapshotJSON.utf8)
            ),
            snapshot.members.count == coverage.snapshotMemberCount,
            snapshot.members.allSatisfy({ $0.disposition == .eligible }) else {
                return nil
            }

            let sourceSets = try DocumentSourceSetRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_source_sets
                    WHERE structured_output_version_id = ? ORDER BY id
                    """,
                arguments: [structuredOutputVersionID]
            )
            guard sourceSets.count == 1,
                  let sourceSet = sourceSets.first,
                  sourceSet.matterID == matterID,
                  sourceSet.status == DocumentSourceSetStatus.attached.rawValue,
                  sourceSet.mode == DocumentSourceSetMode.exhaustive.rawValue,
                  sourceSet.scopeJSON == run.scopeJSON,
                  try CorpusAnalysisProofIdentity.attachedSourceSetMatchesFrozenCorpus(
                      versionID: structuredOutputVersionID,
                      run: run,
                      db: db
                  ) else {
                return nil
            }

            let dimensions = version.verificationDimensions
            let requiredSatisfiedDimensions: Set<VerificationDimensionName> = [
                .propositionSupport,
                .citationResolution,
                .criticalValueFidelity,
                .listCompleteness,
                .lowConfidenceHandling,
                .corpusCoverage,
            ]
            let contraryDimension = dimensions.result(for: .contraryEvidence)
            guard dimensions.isComplete,
                  dimensions.satisfies(required: requiredSatisfiedDimensions),
                  contraryDimension.status == .failed,
                  !contraryDimension.evidence.isEmpty,
                  dimensions.results.allSatisfy({ result in
                      result.dimension == .contraryEvidence || result.status != .failed
                  }),
                  contraryDimension.evidence.allSatisfy({ evidence in
                      !evidence.sourceID.isEmpty
                          && !evidence.locator.isEmpty
                          && !evidence.excerpt.isEmpty
                  }) else {
                return nil
            }

            guard let reconciliationJSON = run.reconciliationJSON,
                  let reconciliation = try? JSONDecoder().decode(
                      ReviewAdmissionReconciliation.self,
                      from: Data(reconciliationJSON.utf8)
                  ),
                  reconciliation.isContraryOnlyReviewCandidate,
                  let validationJSON = run.validationResultsJSON,
                  let validation = try? JSONDecoder().decode(
                      ReviewAdmissionValidation.self,
                      from: Data(validationJSON.utf8)
                  ),
                  validation.schemaVersion == 1,
                  validation.schemaInvalidPartitionCount == 0,
                  validation.metrics == reconciliation.metrics,
                  validation.verificationDimensions == dimensions else {
                return nil
            }

            let sourceRows = try DocumentOutputSourceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_output_sources
                    WHERE source_set_id = ? AND structured_output_version_id = ?
                    ORDER BY rank, id
                    """,
                arguments: [sourceSet.id, structuredOutputVersionID]
            )
            guard !sourceRows.isEmpty else { return nil }

            var matchedSourceIDs = Set<String>()
            var contrarySignatures = Set<ReviewAdmissionEvidenceSignature>()
            for item in reconciliation.items {
                for reference in item.evidence {
                    guard let source = try Self.boundReviewSource(
                        reference,
                        runID: run.id,
                        sourceRows: sourceRows,
                        slices: slices,
                        db: db
                    ) else {
                        return nil
                    }
                    matchedSourceIDs.insert(source.id)
                }
                for reference in item.contraryEvidence {
                    guard let source = try Self.boundReviewSource(
                        reference,
                        runID: run.id,
                        sourceRows: sourceRows,
                        slices: slices,
                        db: db
                    ), let revisionID = source.revisionID else {
                        return nil
                    }
                    matchedSourceIDs.insert(source.id)
                    contrarySignatures.insert(ReviewAdmissionEvidenceSignature(
                        revisionID: revisionID,
                        locatorJSON: source.locatorJSON,
                        excerpt: source.excerpt
                    ))
                }
            }
            let dimensionSignatures = Set(contraryDimension.evidence.map {
                ReviewAdmissionEvidenceSignature(
                    revisionID: $0.sourceID,
                    locatorJSON: $0.locator,
                    excerpt: $0.excerpt
                )
            })
            guard matchedSourceIDs == Set(sourceRows.map(\.id)),
                  contrarySignatures == dimensionSignatures else {
                return nil
            }
        return run
    }

    public func createPartitions(
        matterID: String,
        runID: String,
        partitions: [CorpusAnalysisPartitionRecord]
    ) throws {
        try writer.write { db in
            let run = try scopedRun(db, matterID: matterID, runID: runID)
            guard run.requestSchemaVersion != 2 else {
                throw CorpusAnalysisRepositoryError.v2RequiresAtomicPreparation
            }
            guard run.status == CorpusAnalysisRunStatus.planning.rawValue else {
                throw CorpusAnalysisRepositoryError.invalidStatusTransition("\(run.status)->planning_write")
            }
            for partition in partitions {
                guard partition.runID == runID else {
                    throw CorpusAnalysisRepositoryError.partitionScopeMismatch(partition.id)
                }
                if let existing = try CorpusAnalysisPartitionRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? AND partition_key = ?",
                    arguments: [runID, partition.partitionKey]
                ) {
                    guard existing.inputRevisionIDsJSON == partition.inputRevisionIDsJSON else {
                        throw CorpusAnalysisRepositoryError.partitionIdentityCollision(partition.partitionKey)
                    }
                    continue
                }
                try partition.insert(db)
            }
        }
    }

    public func fetchPartitions(matterID: String, runID: String) throws -> [CorpusAnalysisPartitionRecord] {
        try writer.read { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            return try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? ORDER BY partition_key ASC",
                arguments: [runID]
            )
        }
    }

    public func fetchSlices(
        matterID: String,
        runID: String
    ) throws -> [CorpusAnalysisPartitionSliceRecord] {
        try writer.read { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            return try CorpusAnalysisPartitionSliceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_partition_slices
                    WHERE run_id = ?
                    ORDER BY partition_id ASC, ordinal ASC, id ASC
                    """,
                arguments: [runID]
            )
        }
    }

    /// Reopens an interrupted/cancelled lifecycle without changing its frozen
    /// snapshot or replaying successful partitions. A durable `running` attempt
    /// tail means the prior process died before checkpoint completion and is
    /// closed as a retryable failure before scheduling resumes.
    @discardableResult
    public func prepareForResume(
        matterID: String,
        runID: String,
        maximumRetryCount: Int
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            guard run.assuranceState != OutputAssuranceState.stale.rawValue else {
                throw CorpusAnalysisRepositoryError.staleRunRequiresNewRun(run.id)
            }
            guard run.status != CorpusAnalysisRunStatus.persisted.rawValue else {
                throw CorpusAnalysisRepositoryError.invalidStatusTransition("persisted->running")
            }
            let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? ORDER BY partition_key ASC",
                arguments: [runID]
            )
            for var partition in partitions {
                var history = try decodeAttemptHistory(partition)
                if history.last?.outcome == .running {
                    let index = history.index(before: history.endIndex)
                    history[index].outcome = .failed
                    history[index].retryable = true
                    history[index].errorSummary = "Interrupted before the attempt checkpoint completed."
                    history[index].completedAt = Date()
                    partition.attemptHistoryJSON = try canonicalJSON(history)
                    partition.errorSummary = history[index].errorSummary
                }

                let retryableFailureCount = history.count { $0.outcome == .failed && $0.retryable }
                let lastFailureWasRetryable = history.last?.outcome == .failed
                    && history.last?.retryable == true
                let disposition = CorpusAnalysisPartitionDisposition(rawValue: partition.disposition) ?? .pending
                if disposition == .cancelled
                    || (disposition == .failed
                        && lastFailureWasRetryable
                        && retryableFailureCount <= maximumRetryCount) {
                    partition.disposition = CorpusAnalysisPartitionDisposition.pending.rawValue
                    partition.dispositionReason = nil
                    partition.findingsJSON = nil
                    partition.errorSummary = nil
                    partition.completedAt = nil
                } else if disposition == .pending && retryableFailureCount > maximumRetryCount {
                    partition.disposition = CorpusAnalysisPartitionDisposition.failed.rawValue
                    partition.dispositionReason = "retry_exhausted"
                    partition.completedAt = Date()
                }
                try partition.update(db)
            }

            run.status = CorpusAnalysisRunStatus.running.rawValue
            run.coverageJSON = nil
            run.reconciliationJSON = nil
            run.validationResultsJSON = nil
            run.assuranceState = nil
            run.assuranceReasonsJSON = nil
            run.completedAt = nil
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func beginAttempt(
        matterID: String,
        runID: String,
        partitionID: String
    ) throws -> CorpusAnalysisPartitionRecord {
        try writer.write { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            var partition = try scopedPartition(db, runID: runID, partitionID: partitionID)
            guard partition.disposition == CorpusAnalysisPartitionDisposition.pending.rawValue else {
                throw CorpusAnalysisRepositoryError.terminalDispositionConflict(partitionID)
            }
            var history = try decodeAttemptHistory(partition)
            guard history.last?.outcome != .running else {
                throw CorpusAnalysisRepositoryError.attemptNotRunning(partitionID)
            }
            let now = Date()
            partition.attemptCount += 1
            history.append(CorpusAnalysisAttemptHistoryEntry(
                attemptNumber: partition.attemptCount,
                outcome: .running,
                startedAt: now
            ))
            partition.attemptHistoryJSON = try canonicalJSON(history)
            partition.startedAt = partition.startedAt ?? now
            partition.completedAt = nil
            try partition.update(db)
            return partition
        }
    }

    public func completeAttemptSucceeded(
        matterID: String,
        runID: String,
        partitionID: String,
        findingsJSON: String
    ) throws {
        try writer.write { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            var partition = try scopedPartition(db, runID: runID, partitionID: partitionID)
            var history = try decodeAttemptHistory(partition)
            try finishRunningAttempt(
                partitionID: partitionID,
                history: &history,
                outcome: .succeeded,
                retryable: false,
                errorSummary: nil
            )
            partition.attemptHistoryJSON = try canonicalJSON(history)
            partition.disposition = CorpusAnalysisPartitionDisposition.succeeded.rawValue
            partition.dispositionReason = nil
            partition.findingsJSON = findingsJSON
            partition.errorSummary = nil
            partition.completedAt = Date()
            try partition.update(db)
        }
    }

    /// Returns true when another attempt remains within the transient retry cap.
    @discardableResult
    public func completeAttemptFailed(
        matterID: String,
        runID: String,
        partitionID: String,
        retryable: Bool,
        errorSummary: String,
        maximumRetryCount: Int,
        dispositionReason: String? = nil
    ) throws -> Bool {
        try writer.write { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            var partition = try scopedPartition(db, runID: runID, partitionID: partitionID)
            var history = try decodeAttemptHistory(partition)
            try finishRunningAttempt(
                partitionID: partitionID,
                history: &history,
                outcome: .failed,
                retryable: retryable,
                errorSummary: errorSummary
            )
            let retryableFailureCount = history.count { $0.outcome == .failed && $0.retryable }
            let shouldRetry = retryable && retryableFailureCount <= maximumRetryCount
            partition.attemptHistoryJSON = try canonicalJSON(history)
            partition.disposition = shouldRetry
                ? CorpusAnalysisPartitionDisposition.pending.rawValue
                : CorpusAnalysisPartitionDisposition.failed.rawValue
            partition.dispositionReason = shouldRetry
                ? "retry_scheduled"
                : (dispositionReason ?? (retryable ? "retry_exhausted" : "map_failed"))
            partition.findingsJSON = nil
            partition.errorSummary = errorSummary
            partition.completedAt = shouldRetry ? nil : Date()
            try partition.update(db)
            return shouldRetry
        }
    }

    public func completeAttemptCancelled(
        matterID: String,
        runID: String,
        partitionID: String
    ) throws {
        try writer.write { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            var partition = try scopedPartition(db, runID: runID, partitionID: partitionID)
            var history = try decodeAttemptHistory(partition)
            try finishRunningAttempt(
                partitionID: partitionID,
                history: &history,
                outcome: .cancelled,
                retryable: true,
                errorSummary: "Corpus analysis cancelled during this attempt."
            )
            partition.attemptHistoryJSON = try canonicalJSON(history)
            partition.dispositionReason = "cancelled_during_attempt"
            partition.errorSummary = "Corpus analysis cancelled during this attempt."
            try partition.update(db)
        }
    }

    /// Atomically balances a cancelled ledger: successful/failed checkpoints
    /// remain intact and every unfinished row receives a terminal disposition.
    @discardableResult
    public func cancelRun(matterID: String, runID: String) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            let preservesStaleAssurance =
                run.assuranceState == OutputAssuranceState.stale.rawValue
            let now = Date()
            var partitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
                arguments: [runID]
            )
            for index in partitions.indices
                where partitions[index].disposition == CorpusAnalysisPartitionDisposition.pending.rawValue {
                partitions[index].disposition = CorpusAnalysisPartitionDisposition.cancelled.rawValue
                partitions[index].dispositionReason = partitions[index].dispositionReason ?? "run_cancelled"
                partitions[index].errorSummary = partitions[index].errorSummary ?? "Corpus analysis cancelled."
                partitions[index].completedAt = now
                try partitions[index].update(db)
            }
            run.status = CorpusAnalysisRunStatus.cancelled.rawValue
            run.coverageJSON = try canonicalJSON(try calculateCoverage(
                db,
                run: run,
                exclusionsDisclosed: true
            ))
            if !preservesStaleAssurance {
                run.assuranceState = nil
                run.assuranceReasonsJSON = nil
            }
            run.completedAt = now
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func updateStatus(
        matterID: String,
        runID: String,
        to status: CorpusAnalysisRunStatus
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            guard Self.canTransition(from: run.status, to: status.rawValue) else {
                throw CorpusAnalysisRepositoryError.invalidStatusTransition("\(run.status)->\(status.rawValue)")
            }
            run.status = status.rawValue
            if status == .failed || status == .cancelled { run.completedAt = Date() }
            try run.update(db)
            return run
        }
    }

    public func setDisposition(
        matterID: String,
        runID: String,
        partitionID: String,
        disposition: CorpusAnalysisPartitionDisposition,
        dispositionReason: String? = nil,
        findingsJSON: String? = nil,
        errorSummary: String? = nil
    ) throws {
        try writer.write { db in
            let run = try scopedRun(db, matterID: matterID, runID: runID)
            guard var partition = try CorpusAnalysisPartitionRecord.fetchOne(db, key: partitionID),
                  partition.runID == runID else {
                throw CorpusAnalysisRepositoryError.partitionScopeMismatch(partitionID)
            }
            let current = CorpusAnalysisPartitionDisposition(rawValue: partition.disposition) ?? .pending
            if current.isTerminal {
                guard current == disposition,
                      partition.dispositionReason == dispositionReason,
                      partition.findingsJSON == findingsJSON,
                      partition.errorSummary == errorSummary else {
                    throw CorpusAnalysisRepositoryError.terminalDispositionConflict(partitionID)
                }
                return
            }
            if Self.requiresExactExecutionProof(run), disposition == .succeeded {
                throw CorpusAnalysisRepositoryError.invalidAttemptHistory(partitionID)
            }
            partition.disposition = disposition.rawValue
            partition.dispositionReason = dispositionReason
            partition.findingsJSON = findingsJSON
            partition.errorSummary = errorSummary
            partition.startedAt = partition.startedAt ?? Date()
            partition.completedAt = disposition.isTerminal ? Date() : nil
            try partition.update(db)
        }
    }

    @discardableResult
    public func coverage(matterID: String, runID: String) throws -> CorpusAnalysisCoverage {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            let coverage = try calculateCoverage(db, run: run, exclusionsDisclosed: true)
            run.coverageJSON = try canonicalJSON(coverage)
            try run.update(db)
            return coverage
        }
    }

    @discardableResult
    public func saveReconciliation(
        matterID: String,
        runID: String,
        reconciliationJSON: String,
        validationResultsJSON: String? = nil
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            run.reconciliationJSON = reconciliationJSON
            run.validationResultsJSON = validationResultsJSON
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func finalizeRun(
        matterID: String,
        runID: String,
        assuranceState: OutputAssuranceState,
        assuranceReasons: [String],
        exclusionsDisclosed: Bool,
        structuredOutputVersionID: String? = nil
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            guard run.assuranceState != OutputAssuranceState.stale.rawValue else {
                throw CorpusAnalysisRepositoryError.staleRunRequiresNewRun(run.id)
            }
            let resolvedStructuredOutputVersionID = try Self.validatedStructuredOutputAttachment(
                requestedID: structuredOutputVersionID,
                run: run,
                assuranceState: assuranceState,
                db: db
            )
            let coverage = try calculateCoverage(
                db,
                run: run,
                exclusionsDisclosed: exclusionsDisclosed
            )
            let isExhaustiveExport = run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue
                && (assuranceState == .corpusComplete || assuranceState == .propositionSupported)
            if assuranceState == .corpusComplete || isExhaustiveExport {
                guard coverage.partitionCount > 0,
                      coverage.pendingPartitionCount == 0,
                      coverage.failedPartitionCount == 0,
                      coverage.cancelledPartitionCount == 0,
                      coverage.excludedPartitionCount == 0,
                      coverage.succeededPartitionCount == coverage.partitionCount,
                      coverage.balanceErrorCount == 0 else {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresAllSucceeded
                }
                guard exclusionsDisclosed else {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresDisclosedExclusions
                }
            }
            if isExhaustiveExport {
                guard run.requestSchemaVersion == 2,
                      run.requestDigest.map(Self.isSHA256) == true else {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresV2Request
                }
                let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? ORDER BY partition_key, id",
                    arguments: [run.id]
                )
                let slices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM corpus_analysis_partition_slices
                        WHERE run_id = ?
                        ORDER BY partition_id, ordinal, id
                        """,
                    arguments: [run.id]
                )
                do {
                    try Self.validatePreparedRun(
                        run,
                        partitions: partitions,
                        slices: slices,
                        db: db,
                        requireLiveCurrentRevision: true
                    )
                } catch {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresExactSliceCoverage
                }
            }
            run.status = CorpusAnalysisRunStatus.persisted.rawValue
            run.coverageJSON = try canonicalJSON(coverage)
            run.assuranceState = assuranceState.rawValue
            run.assuranceReasonsJSON = try canonicalJSON(assuranceReasons)
            run.structuredOutputVersionID = resolvedStructuredOutputVersionID
            run.completedAt = Date()
            try run.update(db)
            return run
        }
    }

    private func calculateCoverage(
        _ db: Database,
        run: CorpusAnalysisRunRecord,
        exclusionsDisclosed: Bool
    ) throws -> CorpusAnalysisCoverage {
        guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: snapshotData) else {
            throw CorpusAnalysisRepositoryError.invalidSnapshot
        }
        let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
            arguments: [run.id]
        )
        let dispositionCounts = Dictionary(grouping: partitions, by: \.disposition).mapValues(\.count)
        let pending = dispositionCounts[CorpusAnalysisPartitionDisposition.pending.rawValue, default: 0]
        let succeeded = dispositionCounts[CorpusAnalysisPartitionDisposition.succeeded.rawValue, default: 0]
        let failed = dispositionCounts[CorpusAnalysisPartitionDisposition.failed.rawValue, default: 0]
        let cancelled = dispositionCounts[CorpusAnalysisPartitionDisposition.cancelled.rawValue, default: 0]
        let excluded = dispositionCounts[CorpusAnalysisPartitionDisposition.excluded.rawValue, default: 0]
        let terminal = succeeded + failed + cancelled + excluded

        let revisionBalanceErrors: Int
        if run.partitionStrategyVersion == 2
            && run.partitionStrategy.hasPrefix("exact_revision_slice")
        {
            let slices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partition_slices WHERE run_id = ?",
                arguments: [run.id]
            )
            revisionBalanceErrors = try Self.exactSliceBalanceErrorCount(
                snapshot: snapshot,
                partitions: partitions,
                slices: slices
            )
        } else {
            let expectedRevisionIDs = snapshot.members
                .filter { $0.disposition == .eligible }
                .flatMap(\.revisionIDs)
            let actualRevisionIDs = try partitions.flatMap { partition -> [String] in
                guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
                      let ids = try? JSONDecoder().decode([String].self, from: data) else {
                    throw CorpusAnalysisRepositoryError.invalidSnapshot
                }
                return ids
            }
            let expectedCounts = Dictionary(grouping: expectedRevisionIDs, by: { $0 }).mapValues(\.count)
            let actualCounts = Dictionary(grouping: actualRevisionIDs, by: { $0 }).mapValues(\.count)
            let revisionKeys = Set(expectedCounts.keys).union(actualCounts.keys)
            revisionBalanceErrors = revisionKeys.reduce(0) {
                $0 + abs(expectedCounts[$1, default: 0] - actualCounts[$1, default: 0])
            }
        }
        let bucketBalanceErrors = abs(partitions.count - pending - terminal)

        return CorpusAnalysisCoverage(
            snapshotMemberCount: snapshot.members.count,
            eligibleMemberCount: snapshot.members.filter { $0.disposition == .eligible }.count,
            excludedMemberCount: snapshot.members.filter { $0.disposition == .excluded }.count,
            excludedMembersDisclosed: exclusionsDisclosed,
            partitionCount: partitions.count,
            pendingPartitionCount: pending,
            succeededPartitionCount: succeeded,
            failedPartitionCount: failed,
            cancelledPartitionCount: cancelled,
            excludedPartitionCount: excluded,
            terminalPartitionCount: terminal,
            balanceErrorCount: revisionBalanceErrors + bucketBalanceErrors
        )
    }

    private func scopedRun(_ db: Database, matterID: String, runID: String) throws -> CorpusAnalysisRunRecord {
        guard let run = try CorpusAnalysisRunRecord.fetchOne(db, key: runID),
              run.matterID == matterID else {
            throw CorpusAnalysisRepositoryError.runScopeMismatch(runID)
        }
        return run
    }

    private func scopedPartition(
        _ db: Database,
        runID: String,
        partitionID: String
    ) throws -> CorpusAnalysisPartitionRecord {
        guard let partition = try CorpusAnalysisPartitionRecord.fetchOne(db, key: partitionID),
              partition.runID == runID else {
            throw CorpusAnalysisRepositoryError.partitionScopeMismatch(partitionID)
        }
        return partition
    }

    private func decodeAttemptHistory(
        _ partition: CorpusAnalysisPartitionRecord
    ) throws -> [CorpusAnalysisAttemptHistoryEntry] {
        guard let data = partition.attemptHistoryJSON.data(using: .utf8),
              let history = try? JSONDecoder().decode([CorpusAnalysisAttemptHistoryEntry].self, from: data),
              history.count == partition.attemptCount,
              history.enumerated().allSatisfy({ $0.element.attemptNumber == $0.offset + 1 }) else {
            throw CorpusAnalysisRepositoryError.invalidAttemptHistory(partition.id)
        }
        return history
    }

    private func finishRunningAttempt(
        partitionID: String,
        history: inout [CorpusAnalysisAttemptHistoryEntry],
        outcome: CorpusAnalysisAttemptOutcome,
        retryable: Bool,
        errorSummary: String?
    ) throws {
        guard !history.isEmpty, history[history.index(before: history.endIndex)].outcome == .running else {
            throw CorpusAnalysisRepositoryError.attemptNotRunning(partitionID)
        }
        let index = history.index(before: history.endIndex)
        history[index].outcome = outcome
        history[index].retryable = retryable
        history[index].errorSummary = errorSummary
        history[index].completedAt = Date()
    }

    private static func requiresExactExecutionProof(_ run: CorpusAnalysisRunRecord) -> Bool {
        run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue
            && run.requestSchemaVersion == 2
            && run.partitionStrategyVersion == 2
            && run.partitionStrategy.hasPrefix("exact_revision_slice")
    }

    private static func validatedStructuredOutputAttachment(
        requestedID: String?,
        run: CorpusAnalysisRunRecord,
        assuranceState: OutputAssuranceState,
        db: Database
    ) throws -> String? {
        guard requiresExactExecutionProof(run) else { return requestedID }

        let isNewAttachment = run.structuredOutputVersionID == nil && requestedID != nil
        let resolvedID: String?
        if let existingID = run.structuredOutputVersionID {
            guard requestedID == nil || requestedID == existingID else {
                throw CorpusAnalysisRepositoryError.invalidStructuredOutputAttachment(requestedID ?? existingID)
            }
            resolvedID = existingID
        } else {
            resolvedID = requestedID
        }
        guard let resolvedID else { return nil }
        guard let version = try StructuredOutputVersionRecord.fetchOne(db, key: resolvedID),
              let output = try StructuredOutputRecord.fetchOne(db, key: version.structuredOutputID),
              output.deletedAt == nil,
              output.matterID == run.matterID,
              output.outputType == StructuredOutputType.documentExhaustiveList.rawValue,
              try CorpusAnalysisProofIdentity.attachedSourceSetMatchesFrozenCorpus(
                  versionID: resolvedID,
                  run: run,
                  db: db
              ) else {
            throw CorpusAnalysisRepositoryError.invalidStructuredOutputAttachment(resolvedID)
        }
        if isNewAttachment || OutputAssurancePresentation.isExportEligible(assuranceState) {
            guard version.assuranceState == assuranceState.rawValue else {
                throw CorpusAnalysisRepositoryError.invalidStructuredOutputAttachment(resolvedID)
            }
        }
        return resolvedID
    }

    private struct StoredCorpusAnalysisScope: Decodable {
        var schemaVersion: Int
        var documentIDs: [String]?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case documentIDs = "document_ids"
        }
    }

    private static func snapshot(
        from run: CorpusAnalysisRunRecord
    ) -> CorpusAnalysisSnapshot? {
        try? JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(run.corpusSnapshotJSON.utf8)
        )
    }

    private static func scope(
        from run: CorpusAnalysisRunRecord
    ) -> StoredCorpusAnalysisScope? {
        try? JSONDecoder().decode(
            StoredCorpusAnalysisScope.self,
            from: Data(run.scopeJSON.utf8)
        )
    }

    private static func inspectCurrentScope(
        matterID: String,
        documentIDs: [String]?,
        db: Database
    ) throws -> CorpusAnalysisScopeInspection {
        let requestedIDs = documentIDs.map(Set.init)
        let documents = try MatterDocumentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM matter_documents
                WHERE matter_id = ? AND deleted_at IS NULL
                ORDER BY display_name COLLATE NOCASE ASC
                """,
            arguments: [matterID]
        )
        .filter { requestedIDs?.contains($0.id) ?? true }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                || ($0.displayName == $1.displayName && $0.id < $1.id)
        }

        var members: [CorpusAnalysisSnapshotMember] = []
        var sources: [CorpusAnalysisScopeSource] = []
        for document in documents {
            let parts = try DocumentPagePartRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_pages_parts
                    WHERE document_id = ?
                    ORDER BY part_index ASC
                    """,
                arguments: [document.id]
            )
            let revisionIDs = parts.compactMap(\.currentRevisionID)
            let memberKey = "document:\(document.id)"

            if let reason = exclusionReason(for: document) {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: reason
                ))
                continue
            }

            guard !parts.isEmpty, revisionIDs.count == parts.count else {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "no_selected_revision"
                ))
                continue
            }

            var selected: [(DocumentPagePartRecord, DocumentPartRevisionRecord)] = []
            var selectedRevisionUnavailable = false
            for (part, revisionID) in zip(parts, revisionIDs) {
                guard let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                      revision.documentID == document.id,
                      revision.partIndex == part.partIndex else {
                    selectedRevisionUnavailable = true
                    break
                }
                selected.append((part, revision))
            }
            guard !selectedRevisionUnavailable else {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "selected_revision_unavailable"
                ))
                continue
            }
            guard selected.allSatisfy({ !$0.1.text.isEmpty }) else {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "empty_selected_revision"
                ))
                continue
            }

            members.append(CorpusAnalysisSnapshotMember(
                memberKey: memberKey,
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: revisionIDs,
                indexState: document.indexStatus,
                disposition: .eligible
            ))
            sources.append(contentsOf: selected.map { part, revision in
                CorpusAnalysisScopeSource(
                    memberKey: memberKey,
                    documentID: document.id,
                    part: part,
                    revision: revision,
                    orderDate: document.metadataModifiedAt ?? document.metadataCreatedAt
                )
            })
        }

        if let requestedIDs {
            let resolvedIDs = Set(documents.map(\.id))
            for documentID in requestedIDs.subtracting(resolvedIDs).sorted() {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: "document:\(documentID)",
                    documentID: documentID,
                    displayName: "Unavailable selected document \(documentID)",
                    revisionIDs: [],
                    indexState: "unavailable",
                    disposition: .excluded,
                    reason: "selected_document_unavailable"
                ))
            }
        } else {
            let importSources = try DocumentImportSourceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_import_sources
                    WHERE matter_id = ?
                    ORDER BY created_at, id
                    """,
                arguments: [matterID]
            )
            for source in importSources where source.documentID == nil {
                members.append(CorpusAnalysisSnapshotMember(
                    memberKey: "import-source:\(source.id)",
                    displayName: source.sourceDisplayPath,
                    revisionIDs: [],
                    indexState: source.state,
                    disposition: .excluded,
                    reason: source.reason ?? source.state
                ))
            }
        }

        members.sort { $0.memberKey < $1.memberKey }
        return CorpusAnalysisScopeInspection(
            snapshot: CorpusAnalysisSnapshot(schemaVersion: 2, members: members),
            sources: sources
        )
    }

    private static func exclusionReason(
        for document: MatterDocumentRecord
    ) -> String? {
        if document.status == MatterDocumentStatus.failed.rawValue
            || document.extractionStatus == DocumentExtractionStatus.failed.rawValue {
            return "extraction_failed"
        }
        if document.status == MatterDocumentStatus.needsReview.rawValue {
            return "review_required"
        }
        let extractionComplete =
            document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
        if !extractionComplete { return "extraction_not_ready" }
        let indexReady = document.indexStatus == DocumentIndexStatus.textIndexed.rawValue
            || document.indexStatus == DocumentIndexStatus.ready.rawValue
        return indexReady ? nil : "index_not_ready"
    }

    private static func createOrFetchPreparedRun(
        run proposed: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        db: Database
    ) throws -> CorpusAnalysisRunRecord {
        guard isCleanPreparedRun(proposed),
              partitions.allSatisfy(isCleanPreparedPartition) else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                "atomic preparation must begin from a clean planning run and pristine pending partitions"
            )
        }
        if let existing = try CorpusAnalysisRunRecord.fetchOne(
            db,
            sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
            arguments: [proposed.matterID, proposed.runKey]
        ) {
            guard sameImmutableRun(existing, proposed) else {
                throw CorpusAnalysisRepositoryError.runKeyCollision(proposed.runKey)
            }
            try validatePreparedRun(
                proposed,
                partitions: partitions,
                slices: slices,
                db: db,
                requireLiveCurrentRevision: true
            )
            let existingPartitions = try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? ORDER BY partition_key, id",
                arguments: [existing.id]
            )
            let existingSlices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_partition_slices
                    WHERE run_id = ?
                    ORDER BY partition_id, ordinal, id
                    """,
                arguments: [existing.id]
            )
            try validatePreparedRun(
                existing,
                partitions: existingPartitions,
                slices: existingSlices,
                db: db,
                requireLiveCurrentRevision: existing.status == CorpusAnalysisRunStatus.planning.rawValue
            )
            guard try samePreparedLedger(
                lhsPartitions: existingPartitions,
                lhsSlices: existingSlices,
                rhsPartitions: partitions,
                rhsSlices: slices
            ) else {
                throw CorpusAnalysisRepositoryError.runKeyCollision(proposed.runKey)
            }
            return existing
        }

        try validatePreparedRun(
            proposed,
            partitions: partitions,
            slices: slices,
            db: db,
            requireLiveCurrentRevision: true
        )
        try proposed.insert(db)
        for partition in partitions { try partition.insert(db) }
        for slice in slices { try slice.insert(db) }
        return proposed
    }

    private struct CorpusSubmissionEnvelope: Decodable {
        var schemaVersion: Int
        var runID: String
        var requestDigest: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case runID = "run_id"
            case requestDigest = "request_digest"
        }
    }

    private struct CorpusSubmissionRunIdentity: Decodable {
        var runID: String

        private enum CodingKeys: String, CodingKey {
            case runID = "run_id"
        }
    }

    private static func corpusSubmissionEnvelope(
        _ payloadJSON: String?
    ) -> CorpusSubmissionEnvelope? {
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CorpusSubmissionEnvelope.self, from: data)
    }

    private static func corpusSubmissionRunID(_ payloadJSON: String?) -> String? {
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CorpusSubmissionRunIdentity.self,
            from: data
        ).runID
    }

    private static func isPristineCorpusAnalysisJob(
        _ job: DocumentProcessingJobRecord,
        for run: CorpusAnalysisRunRecord
    ) -> Bool {
        !job.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && job.matterID == run.matterID
            && job.importBatchID == nil
            && job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue
            && job.status == DocumentProcessingJobStatus.queued.rawValue
            && job.phase == DocumentProcessingPhase.discovering.rawValue
            && job.queuePosition == nil
            && job.totalUnits == 0
            && job.completedUnits == 0
            && job.phaseProgressJSON == nil
            && job.resumeStateJSON == nil
            && job.errorSummary == nil
            && job.startedAt == nil
            && job.pausedAt == nil
            && job.completedAt == nil
    }

    private static func sameCorpusSubmission(
        _ lhs: DocumentProcessingJobRecord,
        _ rhs: DocumentProcessingJobRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.matterID == rhs.matterID
            && lhs.importBatchID == rhs.importBatchID
            && lhs.kind == rhs.kind
            && lhs.payloadJSON == rhs.payloadJSON
    }

    private static func sameImmutableRun(
        _ lhs: CorpusAnalysisRunRecord,
        _ rhs: CorpusAnalysisRunRecord
    ) -> Bool {
        lhs.taskKind == rhs.taskKind
            && lhs.scopeJSON == rhs.scopeJSON
            && lhs.corpusSnapshotJSON == rhs.corpusSnapshotJSON
            && lhs.partitionStrategy == rhs.partitionStrategy
            && lhs.partitionStrategyVersion == rhs.partitionStrategyVersion
            && lhs.modelLineageJSON == rhs.modelLineageJSON
            && lhs.requestSchemaVersion == rhs.requestSchemaVersion
            && lhs.requestDigest == rhs.requestDigest
    }

    private static func isCleanPreparedRun(_ run: CorpusAnalysisRunRecord) -> Bool {
        run.status == CorpusAnalysisRunStatus.planning.rawValue
            && run.coverageJSON == nil
            && run.reconciliationJSON == nil
            && run.validationResultsJSON == nil
            && run.assuranceState == nil
            && run.assuranceReasonsJSON == nil
            && run.structuredOutputVersionID == nil
            && run.completedAt == nil
    }

    private static func isCleanPreparedPartition(
        _ partition: CorpusAnalysisPartitionRecord
    ) -> Bool {
        partition.attemptCount == 0
            && partition.attemptHistoryJSON == "[]"
            && partition.disposition == CorpusAnalysisPartitionDisposition.pending.rawValue
            && partition.dispositionReason == nil
            && partition.findingsJSON == nil
            && partition.errorSummary == nil
            && partition.startedAt == nil
            && partition.completedAt == nil
    }

    private struct PreparedSliceSemantics: Equatable {
        var ordinal: Int
        var memberKey: String
        var documentID: String
        var partIndex: Int
        var revisionID: String
        var charStart: Int
        var charEnd: Int
        var revisionCharCount: Int
        var textSHA256: String
        var locatorJSON: String
    }

    private struct PreparedPartitionSemantics: Equatable {
        var partitionKey: String
        var inputRevisionIDs: [String]
        var slices: [PreparedSliceSemantics]
    }

    private static func samePreparedLedger(
        lhsPartitions: [CorpusAnalysisPartitionRecord],
        lhsSlices: [CorpusAnalysisPartitionSliceRecord],
        rhsPartitions: [CorpusAnalysisPartitionRecord],
        rhsSlices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> Bool {
        try preparedLedger(partitions: lhsPartitions, slices: lhsSlices)
            == preparedLedger(partitions: rhsPartitions, slices: rhsSlices)
    }

    private static func preparedLedger(
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> [PreparedPartitionSemantics] {
        let slicesByPartition = Dictionary(grouping: slices, by: \.partitionID)
        return try partitions.sorted {
            ($0.partitionKey, $0.id) < ($1.partitionKey, $1.id)
        }.map { partition in
            guard let revisionData = partition.inputRevisionIDsJSON.data(using: .utf8),
                  let revisionIDs = try? JSONDecoder().decode([String].self, from: revisionData) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "partition \(partition.partitionKey) has invalid revision identity JSON"
                )
            }
            let semanticSlices = try (slicesByPartition[partition.id] ?? []).sorted {
                ($0.ordinal, $0.id) < ($1.ordinal, $1.id)
            }.map { slice in
                guard let locatorJSON = canonicalLocatorJSON(slice.locatorJSON) else {
                    throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                        "slice \(slice.id) has invalid locator JSON"
                    )
                }
                return PreparedSliceSemantics(
                    ordinal: slice.ordinal,
                    memberKey: slice.memberKey,
                    documentID: slice.documentID,
                    partIndex: slice.partIndex,
                    revisionID: slice.revisionID,
                    charStart: slice.charStart,
                    charEnd: slice.charEnd,
                    revisionCharCount: slice.revisionCharCount,
                    textSHA256: slice.textSHA256,
                    locatorJSON: locatorJSON
                )
            }
            return PreparedPartitionSemantics(
                partitionKey: partition.partitionKey,
                inputRevisionIDs: revisionIDs,
                slices: semanticSlices
            )
        }
    }

    private struct FrozenRevisionIdentity: Hashable {
        var memberKey: String
        var documentID: String
        var revisionID: String
    }

    private static func exactSliceBalanceErrorCount(
        snapshot: CorpusAnalysisSnapshot,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> Int {
        var errors = 0
        var expected = Set<FrozenRevisionIdentity>()
        for member in snapshot.members where member.disposition == .eligible {
            guard let documentID = member.documentID, !member.revisionIDs.isEmpty else {
                errors += 1
                continue
            }
            for revisionID in member.revisionIDs {
                expected.insert(FrozenRevisionIdentity(
                    memberKey: member.memberKey,
                    documentID: documentID,
                    revisionID: revisionID
                ))
            }
        }
        let actual = Set(slices.map {
            FrozenRevisionIdentity(
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                revisionID: $0.revisionID
            )
        })
        errors += expected.subtracting(actual).count + actual.subtracting(expected).count

        let slicesByPartition = Dictionary(grouping: slices, by: \.partitionID)
        let partitionIDs = Set(partitions.map(\.id))
        errors += partitionIDs.subtracting(slicesByPartition.keys).count
        errors += Set(slicesByPartition.keys).subtracting(partitionIDs).count
        for partition in partitions {
            let partitionSlices = slicesByPartition[partition.id] ?? []
            if partitionSlices.map(\.ordinal).sorted() != Array(0..<partitionSlices.count) {
                errors += 1
            }
            guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
                  let revisionIDs = try? JSONDecoder().decode([String].self, from: data) else {
                throw CorpusAnalysisRepositoryError.invalidSnapshot
            }
            if Set(revisionIDs) != Set(partitionSlices.map(\.revisionID)) { errors += 1 }
        }

        for revisionSlices in Dictionary(grouping: slices, by: {
            FrozenRevisionIdentity(
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                revisionID: $0.revisionID
            )
        }).values {
            guard let revisionCharCount = revisionSlices.first?.revisionCharCount else {
                errors += 1
                continue
            }
            if Set(revisionSlices.map(\.partIndex)).count != 1
                || revisionSlices.contains(where: { $0.revisionCharCount != revisionCharCount }) {
                errors += 1
            }
            let ordered = revisionSlices.sorted {
                ($0.charStart, $0.charEnd, $0.id) < ($1.charStart, $1.charEnd, $1.id)
            }
            if ordered.first?.charStart != 0 || ordered.last?.charEnd != revisionCharCount {
                errors += 1
            }
            for pair in zip(ordered, ordered.dropFirst()) where pair.0.charEnd != pair.1.charStart {
                errors += 1
            }
        }
        return errors
    }

    private static func validatePreparedRun(
        _ run: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        db: Database,
        requireLiveCurrentRevision: Bool
    ) throws {
        guard !run.runKey.isEmpty,
              !run.matterID.isEmpty,
              !run.taskKind.isEmpty,
              run.partitionStrategyVersion == 2,
              run.partitionStrategy.hasPrefix("exact_revision_slice") else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("invalid exact-slice strategy")
        }
        guard try MatterRecord.fetchOne(db, key: run.matterID) != nil else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("matter is unavailable")
        }
        if run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue {
            guard run.requestSchemaVersion == 2,
                  run.requestDigest.map(isSHA256) == true else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun("missing v2 request identity")
            }
            guard let modelLineageJSON = run.modelLineageJSON,
                  validPinnedModelJSON(modelLineageJSON) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun("exact model lineage is unavailable")
            }
        }
        guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: snapshotData)
        else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("snapshot is invalid")
        }

        guard !partitions.isEmpty, !slices.isEmpty else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("the exact ledger is empty")
        }
        let partitionIDs = partitions.map(\.id)
        guard Set(partitionIDs).count == partitionIDs.count,
              Set(partitions.map(\.partitionKey)).count == partitions.count,
              partitions.allSatisfy({
                  $0.runID == run.id && !$0.id.isEmpty && !$0.partitionKey.isEmpty
              }) else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("partition identity mismatch")
        }
        let sliceIDs = slices.map(\.id)
        guard Set(sliceIDs).count == sliceIDs.count,
              slices.allSatisfy({ $0.runID == run.id && !$0.id.isEmpty }) else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("slice identity mismatch")
        }

        let partitionByID = Dictionary(uniqueKeysWithValues: partitions.map { ($0.id, $0) })
        let slicesByPartition = Dictionary(grouping: slices, by: \.partitionID)
        guard Set(slicesByPartition.keys) == Set(partitionIDs) else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("a partition is missing exact slices")
        }
        for partition in partitions {
            guard let partitionSlices = slicesByPartition[partition.id],
                  !partitionSlices.isEmpty else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun("partition \(partition.id) is empty")
            }
            let ordinals = partitionSlices.map(\.ordinal).sorted()
            guard ordinals == Array(0..<partitionSlices.count) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "partition \(partition.id) has noncontiguous slice ordinals"
                )
            }
            guard let revisionData = partition.inputRevisionIDsJSON.data(using: .utf8),
                  let inputRevisionIDs = try? JSONDecoder().decode([String].self, from: revisionData),
                  !inputRevisionIDs.isEmpty,
                  inputRevisionIDs.allSatisfy({ !$0.isEmpty }),
                  Set(inputRevisionIDs).count == inputRevisionIDs.count,
                  Set(inputRevisionIDs) == Set(partitionSlices.map(\.revisionID)) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "partition \(partition.id) revision ledger mismatch"
                )
            }
        }

        var expectedIdentities = Set<FrozenRevisionIdentity>()
        var memberKeys = Set<String>()
        guard snapshot.schemaVersion > 0 else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("snapshot schema is invalid")
        }
        for member in snapshot.members {
            guard !member.memberKey.isEmpty,
                  !member.displayName.isEmpty,
                  member.documentID.map({ !$0.isEmpty }) ?? true,
                  member.revisionIDs.allSatisfy({ !$0.isEmpty }),
                  Set(member.revisionIDs).count == member.revisionIDs.count,
                  memberKeys.insert(member.memberKey).inserted else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun("snapshot member identity collision")
            }
            guard member.disposition == .eligible else { continue }
            guard let documentID = member.documentID,
                  !documentID.isEmpty,
                  !member.revisionIDs.isEmpty else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "eligible member \(member.memberKey) has no exact revisions"
                )
            }
            for revisionID in member.revisionIDs {
                expectedIdentities.insert(FrozenRevisionIdentity(
                    memberKey: member.memberKey,
                    documentID: documentID,
                    revisionID: revisionID
                ))
            }
        }
        guard !expectedIdentities.isEmpty else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("snapshot has no eligible revisions")
        }
        let actualIdentities = Set(slices.map {
            FrozenRevisionIdentity(
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                revisionID: $0.revisionID
            )
        })
        guard actualIdentities == expectedIdentities else {
            throw CorpusAnalysisRepositoryError.invalidPreparedRun("slice identities do not equal the snapshot")
        }

        let slicesByRevision = Dictionary(grouping: slices) {
            FrozenRevisionIdentity(
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                revisionID: $0.revisionID
            )
        }
        for (identity, revisionSlices) in slicesByRevision {
            guard Set(revisionSlices.map(\.partIndex)).count == 1,
                  let revisionCharCount = revisionSlices.first?.revisionCharCount,
                  revisionSlices.allSatisfy({ $0.revisionCharCount == revisionCharCount }) else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "revision \(identity.revisionID) has conflicting frozen part metadata"
                )
            }
            let ordered = revisionSlices.sorted {
                ($0.charStart, $0.charEnd, $0.id) < ($1.charStart, $1.charEnd, $1.id)
            }
            guard ordered.first?.charStart == 0,
                  ordered.last?.charEnd == revisionCharCount else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "revision \(identity.revisionID) is not fully covered"
                )
            }
            for (index, slice) in ordered.enumerated() {
                guard slice.charStart >= 0,
                      slice.charEnd > slice.charStart,
                      slice.charEnd <= revisionCharCount,
                      isSHA256(slice.textSHA256),
                      validLocatorJSON(slice.locatorJSON, for: slice),
                      partitionByID[slice.partitionID] != nil else {
                    throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                        "slice \(slice.id) has invalid range, hash, locator, or ownership"
                    )
                }
                if index > 0, ordered[index - 1].charEnd != slice.charStart {
                    throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                        "revision \(identity.revisionID) has a gap or overlap"
                    )
                }
            }
        }

        guard requireLiveCurrentRevision else { return }
        for slice in slices {
            guard let document = try MatterDocumentRecord.fetchOne(db, key: slice.documentID),
                  document.matterID == run.matterID,
                  document.deletedAt == nil else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "document \(slice.documentID) is unavailable or outside the matter"
                )
            }
            guard let part = try DocumentPagePartRecord.fetchOne(
                db,
                sql: "SELECT * FROM document_pages_parts WHERE document_id = ? AND part_index = ?",
                arguments: [slice.documentID, slice.partIndex]
            ), part.currentRevisionID == slice.revisionID,
               locatorSourceKind(slice.locatorJSON) == part.sourceKind else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "part \(slice.partIndex) does not select revision \(slice.revisionID)"
                )
            }
            guard let revision = try DocumentPartRevisionRecord.fetchOne(db, key: slice.revisionID),
                  revision.documentID == slice.documentID,
                  revision.partIndex == slice.partIndex,
                  revision.charCount == revision.text.count,
                  revision.text.count == slice.revisionCharCount,
                  slice.charEnd <= revision.text.count else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "revision \(slice.revisionID) does not match the frozen slice"
                )
            }
            let lower = revision.text.index(revision.text.startIndex, offsetBy: slice.charStart)
            let upper = revision.text.index(revision.text.startIndex, offsetBy: slice.charEnd)
            let exactText = String(revision.text[lower..<upper])
            guard sha256(Data(exactText.utf8)) == slice.textSHA256 else {
                throw CorpusAnalysisRepositoryError.invalidPreparedRun(
                    "slice \(slice.id) text hash does not match its exact Character range"
                )
            }
        }
    }

    private static func validLocatorJSON(
        _ json: String,
        for slice: CorpusAnalysisPartitionSliceRecord
    ) -> Bool {
        guard let locator = parsedLocator(json),
              locator.charStart == slice.charStart,
              locator.charEnd == slice.charEnd else {
            return false
        }
        if let partIndex = locator.partIndex, partIndex != slice.partIndex {
            return false
        }
        return true
    }

    /// Resolves one reconciliation reference to the one attached output-source
    /// row that represents the same exact Character range. The source-set hash
    /// proves the frozen corpus ledger; this check binds the Review-facing
    /// excerpt and locator back to that ledger rather than trusting matching IDs.
    private static func boundReviewSource(
        _ reference: ReviewAdmissionEvidenceReference,
        runID: String,
        sourceRows: [DocumentOutputSourceRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        db: Database
    ) throws -> DocumentOutputSourceRecord? {
        guard !reference.documentID.isEmpty,
              !reference.revisionID.isEmpty,
              let relativeStart = reference.charStart,
              let relativeEnd = reference.charEnd,
              relativeStart >= 0,
              relativeEnd > relativeStart,
              let quote = reference.quote,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let matchingSlices = slices.filter {
            $0.runID == runID
                && $0.documentID == reference.documentID
                && $0.revisionID == reference.revisionID
                && $0.locatorJSON == reference.locatorJSON
                && relativeEnd <= $0.charEnd - $0.charStart
        }
        guard matchingSlices.count == 1,
              let slice = matchingSlices.first,
              let referenceLocator = parsedLocator(reference.locatorJSON) else {
            return nil
        }
        let absoluteStart = slice.charStart + relativeStart
        let absoluteEnd = slice.charStart + relativeEnd
        let matchingSources = sourceRows.filter { source in
            guard source.documentID == reference.documentID,
                  source.revisionID == reference.revisionID,
                  source.excerpt == quote,
                  !source.citationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sourceLocator = parsedLocator(source.locatorJSON) else {
                return false
            }
            return sourceLocator.dimensionJSON == referenceLocator.dimensionJSON
                && sourceLocator.charStart == absoluteStart
                && sourceLocator.charEnd == absoluteEnd
        }
        guard matchingSources.count == 1,
              let source = matchingSources.first,
              let revision = try DocumentPartRevisionRecord.fetchOne(
                  db,
                  key: reference.revisionID
              ),
              revision.documentID == reference.documentID,
              revision.partIndex == slice.partIndex,
              revision.text.count == slice.revisionCharCount,
              absoluteEnd <= revision.text.count else {
            return nil
        }
        let lower = revision.text.index(revision.text.startIndex, offsetBy: absoluteStart)
        let upper = revision.text.index(revision.text.startIndex, offsetBy: absoluteEnd)
        guard String(revision.text[lower..<upper]) == quote else { return nil }
        return source
    }

    private static func locatorSourceKind(_ json: String) -> String? {
        parsedLocator(json)?.sourceKind
    }

    private static func canonicalLocatorJSON(_ json: String) -> String? {
        parsedLocator(json)?.canonicalJSON
    }

    private struct ParsedLocator {
        var sourceKind: String
        var partIndex: Int?
        var charStart: Int
        var charEnd: Int
        var canonicalJSON: String
        var dimensionJSON: String
    }

    private static func parsedLocator(_ json: String) -> ParsedLocator? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let locator = object as? [String: Any] else {
            return nil
        }
        let camelToSnake = [
            "sourceKind": "source_kind",
            "pageIndex": "page_index",
            "pageLabel": "page_label",
            "sheetName": "sheet_name",
            "cellRange": "cell_range",
            "emailPartPath": "email_part_path",
            "charStart": "char_start",
            "charEnd": "char_end",
            "boundingBoxesJSON": "bounding_boxes_json",
            "partIndex": "part_index",
        ]
        let snakeKeys = Set(camelToSnake.values)
        let camelKeys = Set(camelToSnake.keys)
        let hasSnakeKeys = !Set(locator.keys).isDisjoint(with: snakeKeys)
        let hasCamelKeys = !Set(locator.keys).isDisjoint(with: camelKeys)
        guard hasSnakeKeys != hasCamelKeys else { return nil }

        let sourceKey = hasSnakeKeys ? "source_kind" : "sourceKind"
        let partKey = hasSnakeKeys ? "part_index" : "partIndex"
        let startKey = hasSnakeKeys ? "char_start" : "charStart"
        let endKey = hasSnakeKeys ? "char_end" : "charEnd"
        guard let sourceKind = locator[sourceKey] as? String,
              !sourceKind.isEmpty,
              let charStart = locator[startKey] as? Int,
              let charEnd = locator[endKey] as? Int else {
            return nil
        }
        let partIndex: Int?
        if let rawPartIndex = locator[partKey] {
            guard let exactPartIndex = rawPartIndex as? Int else { return nil }
            partIndex = exactPartIndex
        } else {
            partIndex = nil
        }

        var normalized: [String: Any] = [:]
        for (key, value) in locator {
            let normalizedKey = hasCamelKeys ? (camelToSnake[key] ?? key) : key
            guard normalized[normalizedKey] == nil else { return nil }
            normalized[normalizedKey] = value
        }
        guard JSONSerialization.isValidJSONObject(normalized),
              let canonicalData = try? JSONSerialization.data(
                  withJSONObject: normalized,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        var dimensions = normalized
        dimensions.removeValue(forKey: "char_start")
        dimensions.removeValue(forKey: "char_end")
        guard JSONSerialization.isValidJSONObject(dimensions),
              let dimensionData = try? JSONSerialization.data(
                  withJSONObject: dimensions,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return ParsedLocator(
            sourceKind: sourceKind,
            partIndex: partIndex,
            charStart: charStart,
            charEnd: charEnd,
            canonicalJSON: String(decoding: canonicalData, as: UTF8.self),
            dimensionJSON: String(decoding: dimensionData, as: UTF8.self)
        )
    }

    private struct ReviewAdmissionReconciliation: Decodable {
        var schemaVersion: Int
        var items: [ReviewAdmissionItem]
        var omissions: [ReviewAdmissionOmission]
        var metrics: ReviewAdmissionMetrics
        var failedPartitions: [ReviewAdmissionFailedPartition]
        var excludedMembers: [ReviewAdmissionExcludedMember]

        var isContraryOnlyReviewCandidate: Bool {
            let keys = items.map { $0.itemKey.trimmingCharacters(in: .whitespacesAndNewlines) }
            let references = items.flatMap { $0.evidence + $0.contraryEvidence }
            return schemaVersion == 1
                && !items.isEmpty
                && omissions.isEmpty
                && failedPartitions.isEmpty
                && excludedMembers.isEmpty
                && keys.allSatisfy { !$0.isEmpty }
                && Set(keys).count == keys.count
                && items.allSatisfy { item in
                    item.values.count == 1
                        && item.values.allSatisfy {
                            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        && !item.evidence.isEmpty
                }
                && items.contains { !$0.contraryEvidence.isEmpty }
                && references.allSatisfy(\.hasExactIdentity)
                && metrics.isInternallyValid(itemCount: items.count)
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case items, omissions, metrics
            case failedPartitions = "failed_partitions"
            case excludedMembers = "excluded_members"
        }
    }

    private struct ReviewAdmissionItem: Decodable {
        var itemKey: String
        var values: [String]
        var evidence: [ReviewAdmissionEvidenceReference]
        var contraryEvidence: [ReviewAdmissionEvidenceReference]

        private enum CodingKeys: String, CodingKey {
            case itemKey = "item_key"
            case values, evidence
            case contraryEvidence = "contrary_evidence"
        }
    }

    private struct ReviewAdmissionEvidenceReference: Decodable {
        var documentID: String
        var revisionID: String
        var locatorJSON: String
        var quote: String?
        var charStart: Int?
        var charEnd: Int?

        var hasExactIdentity: Bool {
            !documentID.isEmpty
                && !revisionID.isEmpty
                && !locatorJSON.isEmpty
                && quote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && charStart.map { $0 >= 0 } == true
                && charEnd.map { end in
                    charStart.map { end > $0 } == true
                } == true
        }

        private enum CodingKeys: String, CodingKey {
            case documentID = "document_id"
            case revisionID = "revision_id"
            case locatorJSON = "locator_json"
            case quote
            case charStart = "char_start"
            case charEnd = "char_end"
        }
    }

    private struct ReviewAdmissionOmission: Decodable {
        var itemKey: String
        var reason: String

        private enum CodingKeys: String, CodingKey {
            case itemKey = "item_key"
            case reason
        }
    }

    private struct ReviewAdmissionFailedPartition: Decodable {
        var partitionKey: String
        var documentNames: [String]
        var reason: String
        var errorSummary: String

        private enum CodingKeys: String, CodingKey {
            case partitionKey = "partition_key"
            case documentNames = "document_names"
            case reason
            case errorSummary = "error_summary"
        }
    }

    private struct ReviewAdmissionExcludedMember: Decodable {
        var name: String
        var reason: String
    }

    private struct ReviewAdmissionMetrics: Codable, Equatable {
        var expectedCount: Int
        var emittedCount: Int
        var truePositiveCount: Int
        var recall: Double
        var precision: Double
        var duplicateCount: Int
        var conflictCount: Int
        var unexpectedItemKeys: [String]

        func isInternallyValid(itemCount: Int) -> Bool {
            expectedCount >= 0
                && emittedCount == itemCount
                && truePositiveCount >= 0
                && truePositiveCount <= expectedCount
                && truePositiveCount <= emittedCount
                && recall.isFinite && (0...1).contains(recall)
                && precision.isFinite && (0...1).contains(precision)
                && duplicateCount >= 0
                && conflictCount == 0
                && unexpectedItemKeys.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case expectedCount = "expected_count"
            case emittedCount = "emitted_count"
            case truePositiveCount = "true_positive_count"
            case recall, precision
            case duplicateCount = "duplicate_count"
            case conflictCount = "conflict_count"
            case unexpectedItemKeys = "unexpected_item_keys"
        }
    }

    private struct ReviewAdmissionValidation: Decodable {
        var schemaVersion: Int
        var schemaInvalidPartitionCount: Int
        var metrics: ReviewAdmissionMetrics
        var verificationDimensions: VerificationDimensions

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case schemaInvalidPartitionCount = "schema_invalid_partition_count"
            case metrics
            case verificationDimensions = "verification_dimensions"
        }
    }

    private struct ReviewAdmissionEvidenceSignature: Hashable {
        var revisionID: String
        var locatorJSON: String
        var excerpt: String
    }

    private static func validPinnedModelJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let model = object as? [String: Any],
              let repository = model["model_repository"] as? String,
              !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let revision = model["model_revision"] as? String,
              isLowercaseHex(revision, count: 40),
              let algorithm = model["content_binding_algorithm"] as? String,
              algorithm == "supra-release-model-sha256-v1",
              let bindingSchema = model["content_binding_schema_version"] as? Int,
              bindingSchema == 1,
              let fingerprint = model["artifact_fingerprint_sha256"] as? String,
              isSHA256(fingerprint) else {
            return false
        }
        return true
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        isLowercaseHex(value, count: 64)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func canTransition(from: String, to: String) -> Bool {
        if from == to { return true }
        return switch (CorpusAnalysisRunStatus(rawValue: from), CorpusAnalysisRunStatus(rawValue: to)) {
        case (.planning, .running), (.running, .reconciling), (.reconciling, .verifying),
             (.planning, .failed), (.running, .failed), (.reconciling, .failed), (.verifying, .failed),
             (.planning, .cancelled), (.running, .cancelled), (.reconciling, .cancelled), (.verifying, .cancelled):
            true
        default:
            false
        }
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
