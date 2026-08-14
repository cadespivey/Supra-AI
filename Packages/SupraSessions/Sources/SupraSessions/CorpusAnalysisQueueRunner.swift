import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

public enum CorpusAnalysisQueueRunnerError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedPayloadSchema(Int)
    case unsupportedTask
    case preparedRequestMismatch(String)
    case pinnedModelUnavailable(repository: String, revision: String)
    case resolvedModelMismatch(repository: String, revision: String)
    case liveModelNotResolved
    case runtimeCancellationUnconfirmed
    case paused

    public var errorDescription: String? {
        switch self {
        case .unsupportedPayloadSchema(let version):
            "Corpus-analysis queue payload schema \(version) is not supported."
        case .unsupportedTask:
            "The queued corpus-analysis task is not supported."
        case .preparedRequestMismatch(let field):
            "The queued corpus-analysis request does not match its frozen \(field)."
        case .pinnedModelUnavailable(let repository, let revision):
            "The exact pinned model \(repository) at revision \(revision) is unavailable; fallback is disabled."
        case .resolvedModelMismatch(let repository, let revision):
            "The resolved model does not match the pinned repository \(repository), revision \(revision), and artifact fingerprint."
        case .liveModelNotResolved:
            "The exact content-bound model was not resolved before corpus generation."
        case .runtimeCancellationUnconfirmed:
            "The runtime did not confirm that the cancelled corpus generation became quiescent."
        case .paused:
            "Corpus analysis paused after its current partition."
        }
    }
}

/// Validates and executes reconstructible corpus work claimed by the existing
/// app-wide document FIFO. The persisted run and partition ledger remain the sole
/// execution/progress authority; this adapter owns neither a scheduler nor a cache.
public final class CorpusAnalysisQueueRunner: @unchecked Sendable {
    public typealias PinnedModelResolver = @Sendable (
        CorpusAnalysisPinnedModel,
        ExhaustiveListQueuedRequest
    ) async throws -> CorpusAnalysisPinnedModel?
    public typealias ProgressHandler = @Sendable (
        String,
        CorpusAnalysisCoverage
    ) async -> Void

    private let store: SupraStore
    private let resolvePinnedModel: PinnedModelResolver
    private let exhaustiveListGenerator: ExhaustiveListTask.Generator
    private let generationConfiguration: ExhaustiveListGenerationConfiguration?
    private let progressHandler: ProgressHandler
    private let pauseRequests = CorpusAnalysisPauseRequests()

    public init(
        store: SupraStore,
        resolvePinnedModel: @escaping PinnedModelResolver,
        exhaustiveListGenerator: @escaping ExhaustiveListTask.Generator,
        generationConfiguration: ExhaustiveListGenerationConfiguration? = nil,
        progressHandler: @escaping ProgressHandler = { _, _ in }
    ) {
        self.store = store
        self.resolvePinnedModel = resolvePinnedModel
        self.exhaustiveListGenerator = exhaustiveListGenerator
        self.generationConfiguration = generationConfiguration
        self.progressHandler = progressHandler
    }

    public func run(_ payload: CorpusAnalysisJobPayload) async throws {
        let request = try validatePreparedRequest(payload)
        defer { pauseRequests.clear(runID: payload.runID) }
        try await runValidated(payload, request: request)
    }

    /// Thread-safe, non-cancelling signal consumed only after a partition has
    /// checkpointed. The queue uses this synchronous seam from its main-actor API.
    public func requestPause(runID: String) {
        pauseRequests.request(runID: runID)
    }

    private func runValidated(
        _ payload: CorpusAnalysisJobPayload,
        request: ExhaustiveListQueuedRequest
    ) async throws {
        let resolved: CorpusAnalysisPinnedModel?
        do {
            try Task.checkCancellation()
            resolved = try await resolvePinnedModel(payload.pinnedModel, request)
            try Task.checkCancellation()
        } catch {
            guard Task.isCancelled
                    || (error as? ContentBoundModelLoadError) == .cancelled else {
                throw error
            }
            balancePreparedCancellation(payload: payload, request: request)
            throw CancellationError()
        }
        guard let resolved else {
            throw CorpusAnalysisQueueRunnerError.pinnedModelUnavailable(
                repository: payload.pinnedModel.modelRepository,
                revision: payload.pinnedModel.modelRevision
            )
        }
        guard resolved == payload.pinnedModel else {
            throw CorpusAnalysisQueueRunnerError.resolvedModelMismatch(
                repository: payload.pinnedModel.modelRepository,
                revision: payload.pinnedModel.modelRevision
            )
        }
        do {
            _ = try await ExhaustiveListTask(store: store).runPrepared(
                payload: payload,
                generationConfiguration: generationConfiguration,
                progressHandler: { [progressHandler] coverage in
                    await progressHandler(payload.runID, coverage)
                },
                partitionBoundaryHandler: { [pauseRequests] in
                    if pauseRequests.consume(runID: payload.runID) {
                        throw CorpusAnalysisExecutionInterruption.pauseRequested
                    }
                },
                generator: exhaustiveListGenerator
            )
        } catch CorpusAnalysisExecutionInterruption.pauseRequested {
            throw CorpusAnalysisQueueRunnerError.paused
        }
    }

    private func balancePreparedCancellation(
        payload: CorpusAnalysisJobPayload,
        request: ExhaustiveListQueuedRequest
    ) {
        _ = try? store.corpusAnalysis.cancelRun(
            matterID: request.matterID,
            runID: payload.runID
        )
    }

    private func validatePreparedRequest(
        _ payload: CorpusAnalysisJobPayload
    ) throws -> ExhaustiveListQueuedRequest {
        guard payload.schemaVersion == 2 else {
            throw CorpusAnalysisQueueRunnerError.unsupportedPayloadSchema(payload.schemaVersion)
        }
        guard case .exhaustiveList(let request) = payload.task else {
            throw CorpusAnalysisQueueRunnerError.unsupportedTask
        }
        guard request.taskSchemaVersion == ExhaustiveListTask.schemaVersion else {
            throw CorpusAnalysisPreparationError.unsupportedTaskSchema(
                request.taskSchemaVersion
            )
        }
        guard request.promptBuilderVersion == ExhaustiveListTask.promptBuilderVersion else {
            throw CorpusAnalysisPreparationError.unsupportedPromptBuilder(
                request.promptBuilderVersion
            )
        }
        guard request.query == CorpusAnalysisRequestDigest.normalizeQuery(request.query) else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("normalized query")
        }
        try payload.pinnedModel.validate()
        guard let run = try store.corpusAnalysis.fetchRun(
            matterID: request.matterID,
            id: payload.runID
        ) else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("run identity")
        }
        let scopeJSON = try CorpusAnalysisRequestDigest.canonicalJSON(request.scope)
        let modelJSON = try CorpusAnalysisRequestDigest.canonicalJSON(payload.pinnedModel)
        guard run.matterID == request.matterID,
              run.runKey == request.runKey,
              run.taskKind == CorpusAnalysisTaskKind.exhaustiveList.rawValue,
              run.scopeJSON == scopeJSON,
              run.partitionStrategy == "exact_revision_slice:characters=\(request.characterBudget)",
              run.partitionStrategyVersion == 2,
              run.modelLineageJSON == modelJSON,
              run.requestSchemaVersion == 2,
              run.requestDigest == payload.requestDigest else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("request identity")
        }
        guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(
                  CorpusAnalysisSnapshot.self,
                  from: snapshotData
              ) else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("snapshot")
        }
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: request.matterID,
            runID: run.id
        )
        let slices = try store.corpusAnalysis.fetchSlices(
            matterID: request.matterID,
            runID: run.id
        )
        let partitionIDs = Set(partitions.map(\.id))
        let partitionKeys = Set(partitions.map(\.partitionKey))
        let slicePartitionIDs = Set(slices.map(\.partitionID))
        guard !partitions.isEmpty,
              partitionIDs.count == partitions.count,
              partitionKeys.count == partitions.count,
              slicePartitionIDs == partitionIDs,
              slices.allSatisfy({ $0.runID == run.id }) else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("exact slice ledger")
        }
        let recomputedDigest = try CorpusAnalysisRequestDigest.exhaustiveList(
            request: request,
            snapshot: snapshot,
            partitions: partitions,
            slices: slices,
            pinnedModel: payload.pinnedModel
        )
        guard Self.isLowercaseSHA256(payload.requestDigest),
              recomputedDigest == payload.requestDigest else {
            throw CorpusAnalysisQueueRunnerError.preparedRequestMismatch("request digest")
        }
        return request
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

extension CorpusAnalysisQueueRunner {
    /// Shipping composition for an exact, app-managed, content-bound local model.
    /// The fixed extraction settings are part of this task implementation rather
    /// than mutable chat preferences or role-based fallback routing.
    @MainActor
    public static func live(
        store: SupraStore,
        modelLibrary: ModelLibrary,
        runtimeClient: any RuntimeClientProtocol,
        progressHandler: @escaping ProgressHandler = { _, _ in }
    ) -> CorpusAnalysisQueueRunner {
        let selection = CorpusAnalysisLiveModelSelection()
        let generationConfiguration = ExhaustiveListGenerationConfiguration(
            systemPrompt: "Return only the requested strict JSON object. Do not add prose or markdown fences.",
            options: GenerationOptions(
                preset: .extractive,
                temperature: 0,
                topP: 1,
                topK: nil,
                maxContextTokens: 32_768,
                maxOutputTokens: 4_096,
                thinkingBudget: .off,
                repetitionPenalty: nil
            )
        )
        return CorpusAnalysisQueueRunner(
            store: store,
            resolvePinnedModel: { pinnedModel, _ in
                let modelID = try await modelLibrary.loadContentBoundModel(
                    matching: pinnedModel
                )
                await selection.set(
                    modelID,
                    expectedModelSHA256: pinnedModel.artifactFingerprintSHA256
                )
                return pinnedModel
            },
            exhaustiveListGenerator: { input in
                let resolvedSelection = try await selection.requireSelection()
                let generationID = GenerationID()
                let request = GenerateRequest(
                    generationID: generationID,
                    modelID: resolvedSelection.modelID,
                    expectedModelSHA256: resolvedSelection.expectedModelSHA256,
                    prompt: input.prompt,
                    systemPrompt: generationConfiguration.systemPrompt,
                    history: [],
                    contextWorkload: .groundedExactEvidence,
                    options: generationConfiguration.options
                )
                let cancellation = CorpusAnalysisGenerationCancellation(
                    runtimeClient: runtimeClient,
                    generationID: generationID
                )
                do {
                    let raw = try await withTaskCancellationHandler {
                        try await runtimeClient.collectGeneratedText(request)
                    } onCancel: {
                        cancellation.request()
                    }
                    try Task.checkCancellation()
                    return ReasoningContent.answer(from: raw)
                } catch GenerationStreamError.cancelled {
                    if Task.isCancelled {
                        try await cancellation.waitForQuiescence()
                    }
                    throw CancellationError()
                } catch {
                    if Task.isCancelled {
                        try await cancellation.waitForQuiescence()
                        throw CancellationError()
                    }
                    throw error
                }
            },
            generationConfiguration: generationConfiguration,
            progressHandler: progressHandler
        )
    }
}

private final class CorpusAnalysisPauseRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var runIDs: Set<String> = []

    func request(runID: String) {
        _ = lock.withLock {
            runIDs.insert(runID)
        }
    }

    func consume(runID: String) -> Bool {
        lock.withLock {
            runIDs.remove(runID) != nil
        }
    }

    func clear(runID: String) {
        _ = lock.withLock {
            runIDs.remove(runID)
        }
    }
}

private final class CorpusAnalysisGenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let runtimeClient: any RuntimeClientProtocol
    private let generationID: GenerationID
    private var cancellationTask: Task<Void, Error>?

    init(runtimeClient: any RuntimeClientProtocol, generationID: GenerationID) {
        self.runtimeClient = runtimeClient
        self.generationID = generationID
    }

    func request() {
        lock.withLock {
            guard cancellationTask == nil else { return }
            let runtimeClient = runtimeClient
            let generationID = generationID
            cancellationTask = Task.detached {
                try await Self.cancelAndAwaitQuiescence(
                    runtimeClient: runtimeClient,
                    generationID: generationID
                )
            }
        }
    }

    func waitForQuiescence() async throws {
        request()
        guard let task = lock.withLock({ cancellationTask }) else {
            throw CorpusAnalysisQueueRunnerError.runtimeCancellationUnconfirmed
        }
        try await task.value
    }

    private static func cancelAndAwaitQuiescence(
        runtimeClient: any RuntimeClientProtocol,
        generationID: GenerationID
    ) async throws {
        let response = try await runtimeClient.cancelGeneration(generationID)
        guard response.generationID == generationID,
              response.error == nil,
              response.status == .cancelled || response.status == .notFound else {
            throw CorpusAnalysisQueueRunnerError.runtimeCancellationUnconfirmed
        }
        guard response.status == .notFound else { return }

        // RuntimeClient also requests cancellation when a cancelled consumer
        // abandons its stream. If that request wins, bounded status polling proves
        // the original generation reservation disappeared before FIFO advances.
        for attempt in 0..<3_000 {
            let status = try await runtimeClient.runtimeStatus()
            guard let activeGenerationID = status.activeGenerationID else { return }
            guard activeGenerationID == generationID else {
                throw CorpusAnalysisQueueRunnerError.runtimeCancellationUnconfirmed
            }
            if attempt < 2_999 {
                try await Task<Never, Never>.sleep(for: .milliseconds(10))
            }
        }
        throw CorpusAnalysisQueueRunnerError.runtimeCancellationUnconfirmed
    }
}

private actor CorpusAnalysisLiveModelSelection {
    struct Selection: Sendable {
        var modelID: ModelID
        var expectedModelSHA256: String
    }

    private var selection: Selection?

    func set(_ modelID: ModelID, expectedModelSHA256: String) {
        selection = Selection(
            modelID: modelID,
            expectedModelSHA256: expectedModelSHA256
        )
    }

    func requireSelection() throws -> Selection {
        guard let selection else {
            throw CorpusAnalysisQueueRunnerError.liveModelNotResolved
        }
        return selection
    }
}
