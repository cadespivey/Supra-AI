import Combine
import Foundation
import SupraCore
import SupraStore

public enum CaseFileReviewCreationError: Error, LocalizedError, Equatable, Sendable {
    case projectNameRequired
    case instructionRequired
    case selectedDocumentsUnavailable([String])
    case scopeChanged
    case noEligibleSources
    case modelUnavailable
    case reviewAlreadyInProgress
    case submissionFailed
    case jobUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .projectNameRequired:
            "Enter a name for the Review Project."
        case .instructionRequired:
            "Enter what this Review should find."
        case .selectedDocumentsUnavailable(let documentIDs):
            "The selected Review sources are unavailable: \(documentIDs.joined(separator: ", "))."
        case .scopeChanged:
            "The Review source scope changed. Review the refreshed source list before starting."
        case .noEligibleSources:
            "The selected scope contains no eligible source text for Review."
        case .modelUnavailable:
            "Select an available, verified managed model before starting Review."
        case .reviewAlreadyInProgress:
            "This matter already has a queued, running, or paused Review."
        case .submissionFailed:
            "The Review could not be added to the processing queue."
        case .jobUnavailable:
            "The selected Review job is no longer available for this action."
        }
    }
}

/// Matter-scoped creation and durable lifecycle projection for exhaustive Review
/// work. Project Matrix interactions remain owned by `CaseFileReviewController`;
/// this controller stops at an exact, Review-eligible completed run.
@MainActor
public final class CaseFileReviewCreationController: ObservableObject {
    public struct ScopePreview: Sendable, Equatable {
        public let scope: CorpusAnalysisScope
        public let members: [CorpusAnalysisSnapshotMember]

        public var eligibleCount: Int {
            members.count { $0.disposition == .eligible }
        }

        public var excludedCount: Int {
            members.count { $0.disposition == .excluded }
        }

        public init(
            scope: CorpusAnalysisScope,
            members: [CorpusAnalysisSnapshotMember]
        ) {
            self.scope = scope
            self.members = members
        }
    }

    public struct Submission: Sendable, Equatable {
        public let runID: String
        public let jobID: String

        public init(runID: String, jobID: String) {
            self.runID = runID
            self.jobID = jobID
        }
    }

    public enum LifecycleState: String, Sendable, Equatable {
        case queued
        case reviewing
        case pausing
        case paused
        case finalizing
        case finished
        case failed
        case cancelled
    }

    public enum Action: String, Sendable, Hashable {
        case pause
        case resume
        case cancel
        case openResults
    }

    public struct Run: Identifiable, Sendable, Equatable {
        public var id: String { jobID }
        public let jobID: String
        public let runID: String
        public let title: String
        public let instruction: String
        public let state: LifecycleState
        public let terminalPartitionCount: Int
        public let partitionCount: Int
        public let queuePosition: Int?
        public let detail: String?
        public let availableActions: Set<Action>
        public let structuredOutputVersionID: String?

        public var statusLabel: String {
            switch state {
            case .queued: "Queued"
            case .reviewing: "Reviewing"
            case .pausing: "Pausing"
            case .paused: "Paused"
            case .finalizing: "Finalizing"
            case .finished: "Finished"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        public var progressLabel: String {
            "\(terminalPartitionCount) of \(partitionCount) partitions"
        }

        public init(
            jobID: String,
            runID: String,
            title: String,
            instruction: String,
            state: LifecycleState,
            terminalPartitionCount: Int,
            partitionCount: Int,
            queuePosition: Int?,
            detail: String?,
            availableActions: Set<Action>,
            structuredOutputVersionID: String?
        ) {
            self.jobID = jobID
            self.runID = runID
            self.title = title
            self.instruction = instruction
            self.state = state
            self.terminalPartitionCount = terminalPartitionCount
            self.partitionCount = partitionCount
            self.queuePosition = queuePosition
            self.detail = detail
            self.availableActions = availableActions
            self.structuredOutputVersionID = structuredOutputVersionID
        }
    }

    public typealias SubmitCorpusAnalysis = (
        ExhaustiveListQueuedRequest,
        CorpusAnalysisPinnedModel,
        CorpusAnalysisSnapshot
    ) throws -> (runID: String, jobID: String)?
    public typealias ManagedModelPinProvider = (
        ModelID
    ) async throws -> CorpusAnalysisPinnedModel
    public typealias CorpusJobAction = (String) -> Void
    public typealias CorpusJobCancellation = (String) -> Bool

    @Published public private(set) var runs: [Run] = []
    @Published public private(set) var message: String?

    public let matterID: String

    private let store: SupraStore
    private let makeCorpusAnalysisPinnedModel: ManagedModelPinProvider?
    private let submitCorpusAnalysis: SubmitCorpusAnalysis
    private let pauseCorpusAnalysis: CorpusJobAction
    private let resumeCorpusAnalysis: CorpusJobAction
    private let cancelCorpusAnalysis: CorpusJobCancellation
    private let pausingCorpusJobID: () -> String?

    public init(
        matterID: String,
        store: SupraStore,
        makeCorpusAnalysisPinnedModel: ManagedModelPinProvider? = nil,
        submitCorpusAnalysis: @escaping SubmitCorpusAnalysis,
        pauseCorpusAnalysis: @escaping CorpusJobAction,
        resumeCorpusAnalysis: @escaping CorpusJobAction,
        cancelCorpusAnalysis: @escaping CorpusJobAction,
        pausingCorpusJobID: @escaping () -> String? = { nil }
    ) {
        self.matterID = matterID
        self.store = store
        self.makeCorpusAnalysisPinnedModel = makeCorpusAnalysisPinnedModel
        self.submitCorpusAnalysis = submitCorpusAnalysis
        self.pauseCorpusAnalysis = pauseCorpusAnalysis
        self.resumeCorpusAnalysis = resumeCorpusAnalysis
        self.cancelCorpusAnalysis = { jobID in
            cancelCorpusAnalysis(jobID)
            return true
        }
        self.pausingCorpusJobID = pausingCorpusJobID
    }

    public init(
        matterID: String,
        store: SupraStore,
        makeCorpusAnalysisPinnedModel: ManagedModelPinProvider? = nil,
        submitCorpusAnalysis: @escaping SubmitCorpusAnalysis,
        pauseCorpusAnalysis: @escaping CorpusJobAction,
        resumeCorpusAnalysis: @escaping CorpusJobAction,
        cancelCorpusAnalysis: @escaping CorpusJobCancellation,
        pausingCorpusJobID: @escaping () -> String? = { nil }
    ) {
        self.matterID = matterID
        self.store = store
        self.makeCorpusAnalysisPinnedModel = makeCorpusAnalysisPinnedModel
        self.submitCorpusAnalysis = submitCorpusAnalysis
        self.pauseCorpusAnalysis = pauseCorpusAnalysis
        self.resumeCorpusAnalysis = resumeCorpusAnalysis
        self.cancelCorpusAnalysis = cancelCorpusAnalysis
        self.pausingCorpusJobID = pausingCorpusJobID
    }

    public func inspectScope(scope: CorpusAnalysisScope) throws -> ScopePreview {
        let snapshot = try currentSnapshot(scope: scope)
        return ScopePreview(scope: scope, members: snapshot.members)
    }

    @discardableResult
    public func startReview(
        projectName: String,
        instruction: String,
        scope: CorpusAnalysisScope,
        expectedScopePreview: ScopePreview? = nil,
        pinnedModel: CorpusAnalysisPinnedModel?
    ) throws -> Submission {
        let normalizedName = Self.normalize(projectName)
        guard !normalizedName.isEmpty else {
            throw CaseFileReviewCreationError.projectNameRequired
        }
        let normalizedInstruction = Self.normalize(instruction)
        guard !normalizedInstruction.isEmpty else {
            throw CaseFileReviewCreationError.instructionRequired
        }
        guard let pinnedModel else {
            throw CaseFileReviewCreationError.modelUnavailable
        }
        do {
            try pinnedModel.validate()
        } catch {
            throw CaseFileReviewCreationError.modelUnavailable
        }

        let snapshot = try currentSnapshot(scope: scope)
        let preview = ScopePreview(scope: scope, members: snapshot.members)
        if let expectedScopePreview, preview != expectedScopePreview {
            throw CaseFileReviewCreationError.scopeChanged
        }
        let unavailableSelectedIDs = scope.documentIDs == nil
            ? []
            : snapshot.members.compactMap { member -> String? in
                guard member.disposition == .excluded else { return nil }
                return member.documentID
            }.sorted()
        guard unavailableSelectedIDs.isEmpty else {
            throw CaseFileReviewCreationError.selectedDocumentsUnavailable(
                unavailableSelectedIDs
            )
        }
        guard snapshot.members.contains(where: { $0.disposition == .eligible }) else {
            throw CaseFileReviewCreationError.noEligibleSources
        }
        guard try !hasNonterminalReviewJob() else {
            throw CaseFileReviewCreationError.reviewAlreadyInProgress
        }

        let request = ExhaustiveListQueuedRequest(
            taskSchemaVersion: ExhaustiveListTask.schemaVersion,
            promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
            runKey: "guided-review:\(UUID().uuidString.lowercased())",
            matterID: matterID,
            title: normalizedName,
            query: normalizedInstruction,
            scope: scope,
            characterBudget: 24_000,
            maximumRetryCount: 2
        )
        let submitted: (runID: String, jobID: String)?
        do {
            submitted = try submitCorpusAnalysis(request, pinnedModel, snapshot)
        } catch CorpusAnalysisRepositoryError.scopeReceiptChanged {
            throw CaseFileReviewCreationError.scopeChanged
        } catch {
            throw CaseFileReviewCreationError.submissionFailed
        }
        guard let submitted,
              !submitted.runID.isEmpty,
              !submitted.jobID.isEmpty else {
            throw CaseFileReviewCreationError.submissionFailed
        }
        load()
        return Submission(runID: submitted.runID, jobID: submitted.jobID)
    }

    /// Resolves one explicitly selected registered model through the injected
    /// managed-artifact authority, then enters the same normalized and atomic
    /// submission path as callers that already hold a verified pin.
    @discardableResult
    public func startReview(
        projectName: String,
        instruction: String,
        scope: CorpusAnalysisScope,
        expectedScopePreview: ScopePreview? = nil,
        modelID: ModelID
    ) async throws -> Submission {
        guard let makeCorpusAnalysisPinnedModel else {
            throw CaseFileReviewCreationError.modelUnavailable
        }
        let pinnedModel = try await makeCorpusAnalysisPinnedModel(modelID)
        try Task.checkCancellation()
        return try startReview(
            projectName: projectName,
            instruction: instruction,
            scope: scope,
            expectedScopePreview: expectedScopePreview,
            pinnedModel: pinnedModel
        )
    }

    /// Rebuilds lifecycle state exclusively from the durable queue and exact run
    /// ledger, so relaunch and repeated polling produce the same projection.
    public func load() {
        do {
            let projected = try projectedRuns()
            if projected != runs { runs = projected }
            message = nil
        } catch {
            runs = []
            message = error.localizedDescription
        }
    }

    public func reload() {
        load()
    }

    public func pause(jobID: String) throws {
        _ = try require(jobID: jobID, action: .pause)
        pauseCorpusAnalysis(jobID)
        load()
    }

    public func resume(jobID: String) throws {
        _ = try require(jobID: jobID, action: .resume)
        resumeCorpusAnalysis(jobID)
        load()
    }

    public func cancel(jobID: String) throws {
        _ = try require(jobID: jobID, action: .cancel)
        let cancelled = cancelCorpusAnalysis(jobID)
        load()
        guard cancelled else {
            throw CaseFileReviewCreationError.jobUnavailable(jobID)
        }
    }

    private func require(jobID: String, action: Action) throws -> Run {
        guard let run = try projectedRuns().first(where: { $0.jobID == jobID }),
              run.availableActions.contains(action) else {
            throw CaseFileReviewCreationError.jobUnavailable(jobID)
        }
        return run
    }

    private func currentSnapshot(
        scope: CorpusAnalysisScope
    ) throws -> CorpusAnalysisSnapshot {
        try CorpusAnalysisExactPlanner(store: store).currentSnapshot(request: CorpusAnalysisRequest(
            runKey: "guided-review-scope-preview",
            matterID: matterID,
            taskKind: .exhaustiveList,
            scope: scope,
            characterBudget: 24_000,
            maximumRetryCount: 2
        ))
    }

    private func hasNonterminalReviewJob() throws -> Bool {
        try store.documentJobs.fetchJobs(matterID: matterID).contains { job in
            guard job.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue,
                  let status = DocumentProcessingJobStatus(rawValue: job.status) else {
                return false
            }
            return status == .queued || status == .active || status == .paused
        }
    }

    private func projectedRuns() throws -> [Run] {
        let jobs = try store.documentJobs.fetchJobs(matterID: matterID)
            .filter { $0.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }

        var seenJobIDs = Set<String>()
        var projected: [Run] = []
        for job in jobs where seenJobIDs.insert(job.id).inserted {
            guard let payloadJSON = job.payloadJSON,
                  let payload = try? JSONDecoder().decode(
                    CorpusAnalysisJobPayload.self,
                    from: Data(payloadJSON.utf8)
                  ),
                  payload.schemaVersion == 2,
                  case .exhaustiveList(let request) = payload.task,
                  request.matterID == matterID,
                  let persistedRun = try store.corpusAnalysis.fetchRun(
                    matterID: matterID,
                    id: payload.runID
                  ),
                  persistedRun.requestDigest == payload.requestDigest else {
                continue
            }
            let coverage = try store.corpusAnalysis.coverage(
                matterID: matterID,
                runID: payload.runID
            )
            projected.append(try project(
                job: job,
                payload: payload,
                request: request,
                run: persistedRun,
                coverage: coverage
            ))
        }
        return projected
    }

    private func project(
        job: DocumentProcessingJobRecord,
        payload: CorpusAnalysisJobPayload,
        request: ExhaustiveListQueuedRequest,
        run: CorpusAnalysisRunRecord,
        coverage: CorpusAnalysisCoverage
    ) throws -> Run {
        let status = DocumentProcessingJobStatus(rawValue: job.status)
        let state: LifecycleState
        let actions: Set<Action>
        var detail = job.errorSummary
        var structuredOutputVersionID: String?

        switch status {
        case .queued:
            state = .queued
            actions = [.cancel]
        case .active:
            if pausingCorpusJobID() == job.id {
                state = .pausing
                actions = [.cancel]
            } else if coverage.partitionCount > 0,
                      coverage.terminalPartitionCount == coverage.partitionCount {
                state = .finalizing
                actions = [.cancel]
            } else {
                state = .reviewing
                actions = [.pause, .cancel]
            }
        case .paused:
            state = .paused
            actions = [.resume, .cancel]
        case .failed:
            state = .failed
            actions = []
        case .cancelled:
            state = .cancelled
            actions = []
        case .complete:
            state = .finished
            if run.status == CorpusAnalysisRunStatus.persisted.rawValue,
               let versionID = run.structuredOutputVersionID,
               let admitted = try store.corpusAnalysis.fetchExactReviewRun(
                    matterID: matterID,
                    structuredOutputVersionID: versionID
               ),
               admitted.id == payload.runID {
                actions = [.openResults]
                structuredOutputVersionID = versionID
            } else {
                actions = []
                detail = "Finished, but this result is not eligible to open in Review."
            }
        case .none:
            state = .failed
            actions = []
            detail = job.errorSummary ?? "The Review job has an unsupported durable status."
        }

        return Run(
            jobID: job.id,
            runID: payload.runID,
            title: request.title,
            instruction: request.query,
            state: state,
            terminalPartitionCount: coverage.terminalPartitionCount,
            partitionCount: coverage.partitionCount,
            queuePosition: job.queuePosition,
            detail: detail,
            availableActions: actions,
            structuredOutputVersionID: structuredOutputVersionID
        )
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
