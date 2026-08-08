import Foundation
import SupraCore
@testable import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest

final class ExclusiveRuntimeClientTests: XCTestCase {
    func testTLEASE01ReviewWaitsForOrdinaryStreamAndRejectsLateOrdinaryWork() async throws {
        // T-LEASE-01 expected RED: SupraRuntimeClient has no process-wide
        // ExclusiveRuntimeClient, so an exhaustive Review cannot wait for an
        // admitted ordinary stream or close admission to later ordinary work.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: false)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-writer-preference")
        let modelID = ModelID()
        let ordinaryGenerationID = GenerationID()
        let ordinaryStream = try client.generate(makeRequest(
            generationID: ordinaryGenerationID,
            modelID: modelID,
            prompt: "ordinary-in-flight"
        ))
        let ordinaryTask = Task {
            try await drain(ordinaryStream)
        }
        try await waitUntil("ordinary generation reaches the base client") {
            base.generatedPrompts.contains("ordinary-in-flight")
        }

        let reviewEntered = RuntimeLeaseFlag()
        let reviewTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { _ in
                await reviewEntered.set()
            }
        }
        try await waitUntil("exclusive Review becomes the waiting writer") {
            let snapshot = await client.currentAdmissionSnapshot()
            return snapshot.phase == .waiting && snapshot.purpose == purpose
        }

        let lateError = await capturedError {
            _ = try await client.countTokens(
                CountTokensRequest(modelID: modelID, texts: ["late ordinary request"])
            )
        }
        let typedLateError = try XCTUnwrap(lateError as? RuntimeLeaseError)
        XCTAssertEqual(typedLateError, .reserved(purpose: purpose))
        XCTAssertEqual(base.countTokenCallCount, 0, "rejected work must not reach the raw client")
        let enteredBeforeTerminal = await reviewEntered.isSet
        XCTAssertFalse(enteredBeforeTerminal, "the Review must not overlap the ordinary stream")

        XCTAssertTrue(base.finishGeneration(ordinaryGenerationID))
        try await ordinaryTask.value
        try await reviewTask.value

        let finalSnapshot = await client.currentAdmissionSnapshot()
        XCTAssertEqual(finalSnapshot.phase, .available)
        XCTAssertNil(finalSnapshot.purpose)
    }

    func testTLEASE02ReviewOwnerRetainsAdmissionAcrossPartitionGap() async throws {
        // T-LEASE-02 expected RED: corpus load and generation calls are currently
        // independent protocol calls. Nothing identifies one Review owner across
        // the idle gap between mapper partitions, so ordinary work can jump in.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: true)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-two-partitions")
        let modelID = ModelID()
        let gapReached = RuntimeLeaseLatch()
        let continueReview = RuntimeLeaseLatch()

        let reviewTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { _ in
                _ = try await client.loadModel(LoadModelRequest(
                    modelID: modelID,
                    modelPath: "/synthetic/review-model",
                    displayName: "Synthetic Review Model"
                ))
                try await drain(try client.generate(makeRequest(
                    generationID: GenerationID(),
                    modelID: modelID,
                    prompt: "review-partition-1"
                )))
                await gapReached.signal()
                await continueReview.wait()
                try await drain(try client.generate(makeRequest(
                    generationID: GenerationID(),
                    modelID: modelID,
                    prompt: "review-partition-2"
                )))
            }
        }

        await gapReached.wait()
        let gapSnapshot = await client.currentAdmissionSnapshot()
        XCTAssertEqual(gapSnapshot.phase, .exclusive)
        XCTAssertEqual(gapSnapshot.purpose, purpose)

        let outsiderError = await capturedError {
            try await drain(try client.generate(makeRequest(
                generationID: GenerationID(),
                modelID: modelID,
                prompt: "ordinary-gap-intruder"
            )))
        }
        let typedOutsiderError = try XCTUnwrap(outsiderError as? RuntimeLeaseError)
        XCTAssertEqual(typedOutsiderError, .reserved(purpose: purpose))
        XCTAssertEqual(
            base.generatedPrompts,
            ["review-partition-1"],
            "the outsider must be rejected before the raw generation boundary"
        )

        await continueReview.signal()
        try await reviewTask.value
        XCTAssertEqual(base.loadRequests.count, 1)
        XCTAssertEqual(base.generatedPrompts, ["review-partition-1", "review-partition-2"])
    }

    func testTLEASE03ExplicitReleaseFreesRuntimeBeforeHostOnlyReconciliationCompletes() async throws {
        // T-LEASE-03 expected RED: there is no lease handle that can release after
        // the final model-backed partition while host-only reconciliation and
        // publication continue, so a coarse runner lock would reserve too much.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: true)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-host-reconciliation")
        let modelID = ModelID()
        let hostOnlyWorkStarted = RuntimeLeaseLatch()
        let finishHostOnlyWork = RuntimeLeaseLatch()

        let reviewTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { lease in
                try await drain(try client.generate(makeRequest(
                    generationID: GenerationID(),
                    modelID: modelID,
                    prompt: "final-review-partition"
                )))
                await lease.release()
                await hostOnlyWorkStarted.signal()
                await finishHostOnlyWork.wait()
            }
        }

        await hostOnlyWorkStarted.wait()
        let releasedSnapshot = await client.currentAdmissionSnapshot()
        XCTAssertEqual(releasedSnapshot.phase, .available)
        XCTAssertNil(releasedSnapshot.purpose)
        let counts = try await client.countTokens(
            CountTokensRequest(modelID: modelID, texts: ["ordinary work after model phase"])
        )
        XCTAssertEqual(counts.counts, [37])
        XCTAssertEqual(base.countTokenCallCount, 1)

        await finishHostOnlyWork.signal()
        try await reviewTask.value
    }

    func testTLEASE04RecoveryQuarantineBlocksWorkUntilRestartConfirmsIdle() async throws {
        // T-LEASE-04 expected RED: an unconfirmed Review cancellation currently
        // unwinds as an ordinary error. There is no recovery-required quarantine
        // preventing a successor from entering an XPC runtime that may still work.
        let activeGenerationID = GenerationID()
        let base = RuntimeLeaseBaseClient(
            autoCompletesGenerations: true,
            initialStatus: RuntimeStatus(
                state: .generating,
                loadedModelID: ModelID(),
                activeGenerationID: activeGenerationID,
                message: nil,
                metrics: nil
            )
        )
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-unconfirmed-cancel")

        try await client.withExclusiveLease(purpose: purpose) { lease in
            await lease.markRecoveryRequired(
                message: "The Review generation did not confirm runtime quiescence."
            )
        }

        let quarantined = await client.currentAdmissionSnapshot()
        XCTAssertEqual(quarantined.phase, .recoveryRequired)
        XCTAssertEqual(quarantined.purpose, purpose)
        XCTAssertTrue(quarantined.blocksOrdinaryWork)

        let blockedError = await capturedError {
            _ = try await client.countTokens(
                CountTokensRequest(modelID: ModelID(), texts: ["must not cross quarantine"])
            )
        }
        let typedBlockedError = try XCTUnwrap(blockedError as? RuntimeLeaseError)
        XCTAssertEqual(typedBlockedError, .recoveryRequired(purpose: purpose))
        XCTAssertEqual(base.countTokenCallCount, 0)

        let prematureRecoveryError = await capturedError {
            try await client.recoverRuntime()
        }
        XCTAssertNotNil(prematureRecoveryError)
        let stillQuarantined = await client.currentAdmissionSnapshot()
        XCTAssertEqual(stillQuarantined.phase, .recoveryRequired)

        base.setRuntimeStatus(RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ModelID(),
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        ))
        try await client.recoverRuntime()

        let recovered = await client.currentAdmissionSnapshot()
        XCTAssertEqual(recovered.phase, .available)
        XCTAssertNil(recovered.purpose)
        XCTAssertGreaterThanOrEqual(base.restartCallCount, 1)
        _ = try await client.countTokens(
            CountTokensRequest(modelID: ModelID(), texts: ["admitted after recovery"])
        )
        XCTAssertEqual(base.countTokenCallCount, 1)
    }

    func testTLEASE05AdmissionSnapshotsPublishObservableLifecycle() async throws {
        // T-LEASE-05 expected RED: runtime status reports only XPC load/generation
        // state and is idle between Review partitions. No observable app-admission
        // snapshot exists for SwiftUI to show waiting/exclusive/recovery states.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: true)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-observable")
        let observations = RuntimeAdmissionObservations()
        let finishReview = RuntimeLeaseLatch()
        let observationTask = Task {
            for await snapshot in client.admissionSnapshots() {
                await observations.append(snapshot)
            }
        }
        try await waitUntil("admission observer receives its initial snapshot") {
            await observations.containsPhase(.available)
        }

        let reviewTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { _ in
                await finishReview.wait()
            }
        }
        try await waitUntil("admission observer sees the exclusive Review") {
            await observations.contains(phase: .exclusive, purpose: purpose)
        }
        await finishReview.signal()
        try await reviewTask.value
        try await waitUntil("admission observer sees availability after Review") {
            await observations.containsAvailableAfterExclusive()
        }

        observationTask.cancel()
        _ = await observationTask.result
    }

    func testTLEASE06ControlPlaneRemainsAvailableDuringReviewLease() async throws {
        // T-LEASE-06 expected RED: without an admission layer there is no explicit
        // distinction between blocked model/data-plane work and the cancellation,
        // status, and recent-event control plane required to unwind a Review safely.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: true)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "review-run-control-plane")
        let leaseEntered = RuntimeLeaseLatch()
        let releaseLease = RuntimeLeaseLatch()
        let generationID = GenerationID()

        let reviewTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { _ in
                await leaseEntered.signal()
                await releaseLease.wait()
            }
        }
        await leaseEntered.wait()

        try await client.connect()
        _ = try await client.runtimeStatus()
        _ = try await client.embeddingStatus()
        _ = try await client.recentEvents(for: generationID, after: 17)
        let cancellation = try await client.cancelGeneration(generationID)

        XCTAssertEqual(cancellation.status, .cancelled)
        XCTAssertEqual(cancellation.generationID, generationID)
        XCTAssertEqual(base.connectCallCount, 1)
        XCTAssertEqual(base.runtimeStatusCallCount, 1)
        XCTAssertEqual(base.embeddingStatusCallCount, 1)
        XCTAssertEqual(base.recentEventRequests, [.init(generationID: generationID, after: 17)])
        XCTAssertEqual(base.cancelledGenerationIDs, [generationID])

        await releaseLease.signal()
        try await reviewTask.value
    }

    func testTLEASE08CancellingWaitingReviewRemovesWriterPreference() async throws {
        // T-LEASE-08 expected RED: there is no cancellable exclusive waiter.
        // A cancelled Review request must not leave the admission gate closed to
        // later ordinary work while an earlier ordinary stream is still active.
        let base = RuntimeLeaseBaseClient(autoCompletesGenerations: false)
        let client = ExclusiveRuntimeClient(base: base)
        let purpose = RuntimeLeasePurpose.caseFileReview(runID: "cancelled-waiter-808")
        let generationID = GenerationID()
        let ordinaryTask = Task {
            try await drain(try client.generate(makeRequest(
                generationID: generationID,
                modelID: ModelID(),
                prompt: "ordinary-owner-before-cancelled-waiter"
            )))
        }
        try await waitUntil("ordinary owner reaches base") {
            base.generatedPrompts == ["ordinary-owner-before-cancelled-waiter"]
        }
        let waitingTask = Task {
            try await client.withExclusiveLease(purpose: purpose) { _ in
                XCTFail("cancelled waiting Review must never enter")
            }
        }
        try await waitUntil("Review enters waiting phase") {
            let snapshot = await client.currentAdmissionSnapshot()
            return snapshot.phase == .waiting && snapshot.purpose == purpose
        }

        waitingTask.cancel()
        let waitingResult = await waitingTask.result
        switch waitingResult {
        case .success:
            XCTFail("cancelled Review waiter unexpectedly succeeded")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }

        let countResponse = try await client.countTokens(
            CountTokensRequest(modelID: ModelID(), texts: ["ordinary-after-waiter-cancel"])
        )
        XCTAssertEqual(countResponse.counts, [37])
        XCTAssertEqual(base.countTokenCallCount, 1)
        XCTAssertTrue(base.finishGeneration(generationID))
        try await ordinaryTask.value
    }

    private func makeRequest(
        generationID: GenerationID,
        modelID: ModelID,
        prompt: String
    ) -> GenerateRequest {
        GenerateRequest(
            generationID: generationID,
            modelID: modelID,
            prompt: prompt,
            systemPrompt: nil,
            options: GenerationOptions(maxOutputTokens: 32)
        )
    }
}

private actor RuntimeLeaseFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

private actor RuntimeLeaseLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if isOpen { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor RuntimeAdmissionObservations {
    private var snapshots: [RuntimeAdmissionSnapshot] = []

    func append(_ snapshot: RuntimeAdmissionSnapshot) {
        snapshots.append(snapshot)
    }

    func containsPhase(_ phase: RuntimeAdmissionSnapshot.Phase) -> Bool {
        snapshots.contains { $0.phase == phase }
    }

    func contains(
        phase: RuntimeAdmissionSnapshot.Phase,
        purpose: RuntimeLeasePurpose
    ) -> Bool {
        snapshots.contains { $0.phase == phase && $0.purpose == purpose }
    }

    func containsAvailableAfterExclusive() -> Bool {
        if let exclusiveIndex = snapshots.firstIndex(where: { $0.phase == .exclusive }) {
            return snapshots[snapshots.index(after: exclusiveIndex)...].contains {
                $0.phase == .available
            }
        }
        return false
    }
}

private struct RuntimeRecentEventRequest: Equatable {
    var generationID: GenerationID
    var after: Int
}

private final class RuntimeLeaseBaseClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let autoCompletesGenerations: Bool
    private var status: RuntimeStatus
    private var heldGenerations: [
        GenerationID: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ] = [:]
    private var storedLoadRequests: [LoadModelRequest] = []
    private var storedGeneratedRequests: [GenerateRequest] = []
    private var storedCountTokenCallCount = 0
    private var storedConnectCallCount = 0
    private var storedRuntimeStatusCallCount = 0
    private var storedEmbeddingStatusCallCount = 0
    private var storedRestartCallCount = 0
    private var storedRecentEventRequests: [RuntimeRecentEventRequest] = []
    private var storedCancelledGenerationIDs: [GenerationID] = []

    init(
        autoCompletesGenerations: Bool,
        initialStatus: RuntimeStatus = RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ModelID(),
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    ) {
        self.autoCompletesGenerations = autoCompletesGenerations
        self.status = initialStatus
    }

    var loadRequests: [LoadModelRequest] {
        lock.withLock { storedLoadRequests }
    }

    var generatedPrompts: [String] {
        lock.withLock { storedGeneratedRequests.map(\.prompt) }
    }

    var countTokenCallCount: Int {
        lock.withLock { storedCountTokenCallCount }
    }

    var connectCallCount: Int {
        lock.withLock { storedConnectCallCount }
    }

    var runtimeStatusCallCount: Int {
        lock.withLock { storedRuntimeStatusCallCount }
    }

    var embeddingStatusCallCount: Int {
        lock.withLock { storedEmbeddingStatusCallCount }
    }

    var restartCallCount: Int {
        lock.withLock { storedRestartCallCount }
    }

    var recentEventRequests: [RuntimeRecentEventRequest] {
        lock.withLock { storedRecentEventRequests }
    }

    var cancelledGenerationIDs: [GenerationID] {
        lock.withLock { storedCancelledGenerationIDs }
    }

    func setRuntimeStatus(_ status: RuntimeStatus) {
        lock.withLock {
            self.status = status
        }
    }

    @discardableResult
    func finishGeneration(_ generationID: GenerationID) -> Bool {
        let continuation = lock.withLock { heldGenerations.removeValue(forKey: generationID) }
        if let continuation {
            continuation.yield(GenerationEvent(
                generationID: generationID,
                sequenceNumber: 2,
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                type: .generationCompleted
            ))
            continuation.finish()
            return true
        }
        return false
    }

    func connect() async throws {
        lock.withLock {
            storedConnectCallCount += 1
        }
    }

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        lock.withLock {
            storedLoadRequests.append(request)
        }
        return LoadModelResponse(
            status: .loaded,
            modelID: request.modelID,
            verifiedModelSHA256: request.contentBinding?.fingerprintSHA256
        )
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock {
            storedGeneratedRequests.append(request)
        }
        return AsyncThrowingStream { [self] continuation in
            continuation.yield(GenerationEvent(
                generationID: request.generationID,
                sequenceNumber: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                type: .generationStarted
            ))
            if autoCompletesGenerations {
                continuation.yield(GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 2,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                    type: .generationCompleted
                ))
                continuation.finish()
            } else {
                lock.withLock {
                    heldGenerations[request.generationID] = continuation
                }
            }
        }
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        lock.withLock {
            storedCountTokenCallCount += 1
        }
        return CountTokensResponse(
            modelID: request.modelID,
            counts: request.texts.map { _ in 37 }
        )
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        lock.withLock {
            storedCancelledGenerationIDs.append(generationID)
        }
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        lock.withLock {
            storedRecentEventRequests.append(.init(
                generationID: generationID,
                after: sequenceNumber
            ))
        }
        return []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        let currentStatus = lock.withLock { status }
        return LoadModelResponse(
            status: currentStatus.loadedModelID == nil ? .failed : .loaded,
            modelID: currentStatus.loadedModelID
        )
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        lock.withLock {
            storedRuntimeStatusCallCount += 1
            return status
        }
    }

    func restartRuntimeService() async throws {
        lock.withLock {
            storedRestartCallCount += 1
        }
    }

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        LoadEmbeddingModelResponse(
            state: .loaded,
            embeddingModelID: request.embeddingModelID,
            dimension: request.expectedDimension
        )
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(
            state: .loaded,
            vectors: request.texts.map { _ in [Float(1), 0] },
            dimension: 2,
            normalized: request.normalize
        )
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        lock.withLock {
            storedEmbeddingStatusCallCount += 1
        }
        return EmbeddingModelStatus(state: .unloaded)
    }
}

private func drain(
    _ stream: AsyncThrowingStream<GenerationEvent, Error>
) async throws {
    for try await _ in stream {}
}

private func capturedError(
    _ operation: @escaping @Sendable () async throws -> Void
) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

private enum RuntimeLeaseTestTimeout: Error {
    case expired(String)
}

private func waitUntil(
    _ description: String,
    attempts: Int = 400,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task<Never, Never>.sleep(for: .milliseconds(5))
    }
    throw RuntimeLeaseTestTimeout.expired(description)
}
