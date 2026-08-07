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

/// Freezes all execution inputs before the queue job can become runnable.
/// The Store repository commits the run, partitions, and exact slices in one
/// transaction; the returned payload contains only reconstructible v2 work.
public struct CorpusAnalysisQueuePreparer: Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func prepareExhaustiveList(
        request: ExhaustiveListQueuedRequest,
        pinnedModel: CorpusAnalysisPinnedModel
    ) throws -> CorpusAnalysisJobPayload {
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
        let run: CorpusAnalysisRunRecord
        do {
            run = try store.corpusAnalysis.createOrFetchPreparedRun(
                run: proposed,
                partitions: plan.partitions,
                slices: plan.slices
            )
        } catch CorpusAnalysisRepositoryError.runKeyCollision {
            throw CorpusAnalysisEngineError.runKeyCollision(frozenRequest.runKey)
        }
        guard run.matterID == frozenRequest.matterID else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("matter identity")
        }
        guard run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("task kind")
        }
        guard run.requestSchemaVersion == 2, run.requestDigest == requestDigest else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("request digest")
        }
        guard run.modelLineageJSON == engineRequest.modelLineageJSON else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("pinned model")
        }

        return CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: run.id,
            requestDigest: requestDigest,
            task: .exhaustiveList(frozenRequest),
            pinnedModel: pinnedModel
        )
    }
}
