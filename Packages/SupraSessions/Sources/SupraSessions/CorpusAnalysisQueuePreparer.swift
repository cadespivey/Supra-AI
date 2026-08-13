import Foundation
import SupraCore
import SupraStore

public enum CorpusAnalysisPreparationError: Error, LocalizedError, Equatable, Sendable {
    case noEligibleSources
    case unsupportedTaskSchema(Int)
    case unsupportedPromptBuilder(String)
    case invalidPinnedModel(String)
    case preparedRunMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .noEligibleSources:
            "The selected scope contains no eligible source text for corpus analysis."
        case .unsupportedTaskSchema(let version):
            "Exhaustive-list task schema \(version) is not supported."
        case .unsupportedPromptBuilder(let version):
            "Exhaustive-list prompt builder \(version) is not supported."
        case .invalidPinnedModel(let field):
            "The pinned corpus-analysis model has an invalid \(field)."
        case .preparedRunMismatch(let field):
            "The prepared corpus-analysis run does not match its \(field)."
        }
    }
}

/// One fully planned, but not yet persisted, corpus-analysis submission. Keeping
/// the frozen ledger and its reconstructible queue payload together lets the
/// queue hand both to the Store's single atomic submission transaction.
public struct PreparedCorpusAnalysisSubmission: Sendable {
    public let run: CorpusAnalysisRunRecord
    public let partitions: [CorpusAnalysisPartitionRecord]
    public let slices: [CorpusAnalysisPartitionSliceRecord]
    public let payload: CorpusAnalysisJobPayload
    public let jobID: String

    public init(
        run: CorpusAnalysisRunRecord,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        payload: CorpusAnalysisJobPayload,
        jobID: String = UUID().uuidString
    ) {
        self.run = run
        self.partitions = partitions
        self.slices = slices
        self.payload = payload
        self.jobID = jobID
    }
}

/// Freezes all execution inputs before the queue job can become runnable.
public struct CorpusAnalysisQueuePreparer: Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func prepareExhaustiveList(
        request: ExhaustiveListQueuedRequest,
        pinnedModel: CorpusAnalysisPinnedModel
    ) throws -> CorpusAnalysisJobPayload {
        let submission = try prepareExhaustiveListSubmission(
            request: request,
            pinnedModel: pinnedModel
        )
        let run: CorpusAnalysisRunRecord
        do {
            run = try store.corpusAnalysis.createOrFetchPreparedRun(
                run: submission.run,
                partitions: submission.partitions,
                slices: submission.slices
            )
        } catch CorpusAnalysisRepositoryError.runKeyCollision {
            throw CorpusAnalysisEngineError.runKeyCollision(submission.run.runKey)
        }
        try validatePersistedRun(
            run,
            against: submission.run,
            pinnedModel: pinnedModel
        )
        return CorpusAnalysisJobPayload(
            schemaVersion: submission.payload.schemaVersion,
            runID: run.id,
            requestDigest: submission.payload.requestDigest,
            task: submission.payload.task,
            pinnedModel: submission.payload.pinnedModel
        )
    }

    /// Builds the immutable v2 run, exact partition/slice ledger, and queue
    /// envelope without writing any of them. Production creation passes this
    /// value to `DocumentProcessingQueue`, which submits the entire graph in one
    /// Store transaction. The older `prepareExhaustiveList` API remains for
    /// direct engine/test callers that intentionally persist only the ledger.
    public func prepareExhaustiveListSubmission(
        request: ExhaustiveListQueuedRequest,
        pinnedModel: CorpusAnalysisPinnedModel
    ) throws -> PreparedCorpusAnalysisSubmission {
        guard request.taskSchemaVersion == ExhaustiveListTask.schemaVersion else {
            throw CorpusAnalysisPreparationError.unsupportedTaskSchema(request.taskSchemaVersion)
        }
        guard request.promptBuilderVersion == ExhaustiveListTask.promptBuilderVersion else {
            throw CorpusAnalysisPreparationError.unsupportedPromptBuilder(
                request.promptBuilderVersion
            )
        }
        try pinnedModel.validate()
        let frozenRequest = ExhaustiveListQueuedRequest(
            taskSchemaVersion: request.taskSchemaVersion,
            promptBuilderVersion: request.promptBuilderVersion,
            runKey: request.runKey,
            matterID: request.matterID,
            title: request.title,
            query: CorpusAnalysisRequestDigest.normalizeQuery(request.query),
            scope: request.scope,
            characterBudget: request.characterBudget,
            maximumRetryCount: request.maximumRetryCount
        )

        let runID = UUID().uuidString
        let engineRequest = CorpusAnalysisRequest(
            runKey: frozenRequest.runKey,
            matterID: frozenRequest.matterID,
            taskKind: .exhaustiveList,
            scope: frozenRequest.scope,
            characterBudget: frozenRequest.characterBudget,
            maximumRetryCount: frozenRequest.maximumRetryCount,
            modelLineageJSON: try CorpusAnalysisRequestDigest.canonicalJSON(pinnedModel)
        )
        let plan = try CorpusAnalysisExactPlanner(store: store).plan(
            request: engineRequest,
            runID: runID
        )
        let requestDigest = try CorpusAnalysisRequestDigest.exhaustiveList(
            request: frozenRequest,
            snapshot: plan.snapshot,
            partitions: plan.partitions,
            slices: plan.slices,
            pinnedModel: pinnedModel
        )
        let proposed = CorpusAnalysisRunRecord(
            id: runID,
            runKey: frozenRequest.runKey,
            matterID: frozenRequest.matterID,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: try CorpusAnalysisRequestDigest.canonicalJSON(frozenRequest.scope),
            corpusSnapshotJSON: try CorpusAnalysisRequestDigest.canonicalJSON(plan.snapshot),
            partitionStrategy: "exact_revision_slice:characters=\(frozenRequest.characterBudget)",
            partitionStrategyVersion: 2,
            modelLineageJSON: engineRequest.modelLineageJSON,
            status: CorpusAnalysisRunStatus.planning.rawValue,
            requestSchemaVersion: 2,
            requestDigest: requestDigest
        )
        let payload = CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: proposed.id,
            requestDigest: requestDigest,
            task: .exhaustiveList(frozenRequest),
            pinnedModel: pinnedModel
        )
        return PreparedCorpusAnalysisSubmission(
            run: proposed,
            partitions: plan.partitions,
            slices: plan.slices,
            payload: payload
        )
    }

    private func validatePersistedRun(
        _ run: CorpusAnalysisRunRecord,
        against proposed: CorpusAnalysisRunRecord,
        pinnedModel: CorpusAnalysisPinnedModel
    ) throws {
        guard run.matterID == proposed.matterID else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("matter identity")
        }
        guard run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("task kind")
        }
        guard run.requestSchemaVersion == 2,
              run.requestDigest == proposed.requestDigest else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("request digest")
        }
        guard run.modelLineageJSON == proposed.modelLineageJSON,
              run.modelLineageJSON == (try CorpusAnalysisRequestDigest.canonicalJSON(pinnedModel)) else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("pinned model")
        }
    }
}
