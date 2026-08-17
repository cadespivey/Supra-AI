import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Production composition proofs for the exhaustive-review model boundary.
///
/// These tests deliberately bypass routed/recommended model selection. A queued
/// exact-corpus request authorizes one manifest-backed artifact identity, and the
/// runtime must independently return that same verified fingerprint before any
/// partition may generate.
@MainActor
final class ModelLibraryContentBoundLoadingTests: XCTestCase {
    private static let modelIDString = "77777777-7777-4777-8777-777777777777"
    private static let repositoryID = "mlx-community/Release-Smoke-4bit"
    private static let revision = String(repeating: "a", count: 40)
    private static let fingerprint =
        "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"

    func testTQUEUE03LiveExactManagedModelSendsContentBindingAndAcceptsExactRuntimeFingerprint() async throws {
        // Expected RED: ModelLibrary has no loadContentBoundModel(matching:)
        // API, so shipping code cannot make or verify a content-bound runtime
        // load for the pinned corpus-analysis artifact.
        let fixture = try makeFixture(location: .managed)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let library = try makeLibrary(fixture: fixture, runtime: runtime)
        let expectedModelID = ModelID(try XCTUnwrap(UUID(uuidString: Self.modelIDString)))

        let loadedModelID = try await library.loadContentBoundModel(
            matching: Self.pinnedModel
        )

        let request = try XCTUnwrap(runtime.loadRequests.only)
        let binding = try XCTUnwrap(request.contentBinding)
        XCTAssertEqual(loadedModelID, expectedModelID)
        XCTAssertEqual(request.modelID, expectedModelID)
        XCTAssertEqual(request.modelPath, fixture.modelDirectory.path)
        XCTAssertEqual(request.managedRootPath, fixture.managedRoot.path)
        XCTAssertFalse(request.modelBookmark?.isEmpty ?? true)
        XCTAssertNotNil(request.modelDirectoryIdentity)
        XCTAssertEqual(binding.algorithm, RuntimeModelContentBinding.fingerprintAlgorithm)
        XCTAssertEqual(
            binding.schemaVersion,
            RuntimeModelContentBinding.supportedManifestSchemaVersion
        )
        XCTAssertEqual(binding.repositoryID, Self.repositoryID)
        XCTAssertEqual(binding.revision, Self.revision)
        XCTAssertEqual(binding.fingerprintSHA256, Self.fingerprint)
        XCTAssertEqual(binding.files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(
            library.loadState,
            .loaded(modelID: Self.modelIDString)
        )
    }

    func testOrdinaryManagedActivationCannotBypassExactContentBinding() async throws {
        // Expected RED: the ordinary Models-tab activation path constructs an
        // unbound LoadModelRequest even for a verified managed installation.
        let fixture = try makeFixture(location: .managed)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let library = try makeLibrary(fixture: fixture, runtime: runtime)

        await library.activateAndLoad(modelID: Self.modelIDString)

        let request = try XCTUnwrap(runtime.loadRequests.only)
        let binding = try XCTUnwrap(
            request.contentBinding,
            "ordinary shipping activation must authorize exact model bytes"
        )
        XCTAssertEqual(binding.repositoryID, Self.repositoryID)
        XCTAssertEqual(binding.revision, Self.revision)
        XCTAssertEqual(binding.files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(binding.fingerprintSHA256, Self.fingerprint)
        XCTAssertFalse(
            String(describing: request).contains("DEFAULT-000")
        )
    }

    func testTQUEUE03LiveExactModelRejectsMissingAndWrongRuntimeFingerprints() async throws {
        // Expected RED: no strict live load API inspects
        // LoadModelResponse.verifiedModelSHA256, so an unbound or forged load
        // response cannot yet be rejected.
        let fixture = try makeFixture(location: .managed)
        let missingRuntime = ContentBoundLoadingRuntimeStub(reply: .missingFingerprint)
        let wrongRuntime = ContentBoundLoadingRuntimeStub(
            reply: .fixedFingerprint(String(repeating: "f", count: 64))
        )
        let missingLibrary = try makeLibrary(fixture: fixture, runtime: missingRuntime)
        let wrongLibrary = try makeLibrary(fixture: fixture, runtime: wrongRuntime)

        let missingError = await thrownError {
            try await missingLibrary.loadContentBoundModel(matching: Self.pinnedModel)
        }
        let wrongError = await thrownError {
            try await wrongLibrary.loadContentBoundModel(matching: Self.pinnedModel)
        }

        XCTAssertNotNil(missingError)
        XCTAssertNotNil(wrongError)
        XCTAssertTrue(
            missingError?.localizedDescription.localizedCaseInsensitiveContains("fingerprint") == true
        )
        XCTAssertTrue(
            wrongError?.localizedDescription.localizedCaseInsensitiveContains("fingerprint") == true
        )
        XCTAssertEqual(missingRuntime.loadRequests.count, 1)
        XCTAssertEqual(wrongRuntime.loadRequests.count, 1)
        XCTAssertNotNil(missingRuntime.loadRequests.first?.contentBinding)
        XCTAssertNotNil(wrongRuntime.loadRequests.first?.contentBinding)
    }

    func testTQUEUE03LiveExactModelDoesNotLoadWhenManagedRepositoryOrRevisionIsMissing() async throws {
        // Expected RED: there is no fail-closed exact managed-model resolver;
        // existing ModelLibrary routing may select a different registered model.
        let fixture = try makeFixture(location: .managed)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let library = try makeLibrary(fixture: fixture, runtime: runtime)
        var missingIdentity = Self.pinnedModel
        missingIdentity.modelRepository = "synthetic/no-such-review-model"
        missingIdentity.modelRevision = String(repeating: "d", count: 40)

        let error = await thrownError {
            try await library.loadContentBoundModel(matching: missingIdentity)
        }

        XCTAssertNotNil(error)
        XCTAssertTrue(
            error?.localizedDescription.contains(missingIdentity.modelRepository) == true
        )
        XCTAssertTrue(runtime.loadRequests.isEmpty)
    }

    func testTQUEUE03LiveExactModelDoesNotLoadUnmanagedExactCandidate() async throws {
        // Expected RED: the strict live resolver does not exist, so the shipping
        // boundary cannot yet enforce the initial managed-manifest-only policy.
        let fixture = try makeFixture(location: .unmanaged)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let library = try makeLibrary(fixture: fixture, runtime: runtime)

        let error = await thrownError {
            try await library.loadContentBoundModel(matching: Self.pinnedModel)
        }

        XCTAssertNotNil(error)
        XCTAssertTrue(runtime.loadRequests.isEmpty)
    }

    func testTQUEUE03LiveExactModelReloadsSameUUIDCacheThroughBoundRuntimeRequest() async throws {
        // Expected RED: the exact load API is absent. Its eventual fast path must
        // not trust ModelLibrary's UUID-only cache, because RuntimeStatus carries
        // no independently verified artifact fingerprint.
        let fixture = try makeFixture(location: .managed)
        let modelID = ModelID(try XCTUnwrap(UUID(uuidString: Self.modelIDString)))
        let runtime = ContentBoundLoadingRuntimeStub(
            reply: .echoRequestFingerprint,
            initiallyLoadedModelID: modelID
        )
        let library = try makeLibrary(fixture: fixture, runtime: runtime)
        library.reconcileLoadedModel(modelID)
        XCTAssertEqual(library.loadedModelID, modelID, "precondition: UUID-only cache is loaded")

        let loadedModelID = try await library.loadContentBoundModel(
            matching: Self.pinnedModel
        )

        XCTAssertEqual(loadedModelID, modelID)
        XCTAssertEqual(runtime.loadRequests.count, 1)
        XCTAssertEqual(
            runtime.loadRequests.first?.contentBinding?.fingerprintSHA256,
            Self.fingerprint
        )
    }

    func testTQUEUE03AuthorizationHashingLeavesMainActorResponsive() async throws {
        // T-QUEUE-03 expected RED: ModelLibrary has no authorizationExecutor
        // injection seam, and both authorize and makeLoadRequest currently hash
        // synchronously on ModelLibrary's MainActor.
        for phase in HeldAuthorizationPhase.allCases {
            let fixture = try makeFixture(location: .managed)
            let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
            let probe = AuthorizationPhaseProbe(holding: phase)
            let library = try makeLibrary(
                fixture: fixture,
                runtime: runtime,
                authorizationExecutor: makeAuthorizationExecutor(probe: probe)
            )

            let load = Task { @MainActor in
                try await library.loadContentBoundModel(matching: Self.pinnedModel)
            }
            let observation = await observeMainActorHeartbeat(whileHeldBy: probe)
            let loadedModelID = try await load.value

            XCTAssertTrue(observation.entered, "\(phase.rawValue) was never entered")
            XCTAssertTrue(
                observation.heartbeatRan,
                "MainActor was blocked while \(phase.rawValue) was held"
            )
            XCTAssertEqual(loadedModelID.rawValue.uuidString, Self.modelIDString.uppercased())
            XCTAssertEqual(runtime.loadRequests.count, 1)
        }
    }

    func testTQUEUE03AuthorizationHashingPropagatesCancellationBeforeRuntimeLoad() async throws {
        // T-QUEUE-03 expected RED: ModelLibrary has no authorizationExecutor
        // injection seam, so cancellation cannot be proven to reach off-main
        // authorize and makeLoadRequest hashing before runtime admission.
        for phase in HeldAuthorizationPhase.allCases {
            let fixture = try makeFixture(location: .managed)
            let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
            let probe = AuthorizationPhaseProbe(holding: phase)
            let library = try makeLibrary(
                fixture: fixture,
                runtime: runtime,
                authorizationExecutor: makeAuthorizationExecutor(probe: probe)
            )

            let load = Task { @MainActor in
                try await library.loadContentBoundModel(matching: Self.pinnedModel)
            }
            let entered = await Task.detached { probe.waitUntilHeldPhaseEntered() }.value
            load.cancel()
            probe.releaseHeldPhase()
            let error = await thrownError { try await load.value }

            XCTAssertTrue(entered, "\(phase.rawValue) was never entered")
            XCTAssertEqual(error as? ContentBoundModelLoadError, .cancelled)
            XCTAssertTrue(
                runtime.loadRequests.isEmpty,
                "runtime load must not begin after cancellation during \(phase.rawValue)"
            )
            if phase == .authorize {
                XCTAssertEqual(probe.enteredPhases, [.authorize])
            } else {
                XCTAssertEqual(probe.enteredPhases, [.authorize, .makeLoadRequest])
            }
        }
    }

    func testSpeculativePrewarmReleasesLaneWhileStartupLoadIsAuthorizing() async throws {
        // HOTFIX-LOAD-01 expected RED: ModelLibrary has no coordinator-safe
        // prewarm entry point, so this test does not compile before the fix.
        let fixture = try makeFixture(location: .managed)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let probe = AuthorizationPhaseProbe(holding: .authorize)
        let library = try makeLibrary(
            fixture: fixture,
            runtime: runtime,
            authorizationExecutor: makeAuthorizationExecutor(probe: probe)
        )
        let startupLoad = Task { @MainActor in
            await library.activateAndLoad(modelID: Self.modelIDString)
        }
        defer { probe.releaseHeldPhase() }

        let authorizationStarted = await Task.detached {
            probe.waitUntilHeldPhaseEntered()
        }.value
        XCTAssertTrue(authorizationStarted, "startup authorization never began")
        XCTAssertEqual(library.loadState, .loading(modelID: Self.modelIDString))

        // This call models the point after a speculative request acquired the
        // shared coordinator permit. It must return immediately instead of
        // waiting for the startup load that will need that permit next.
        await library.executePrewarmUnlessLoadIsInFlight(
            role: .legalReasoning,
            configuration: .fromEnvironment(),
            honorsForcedChatSelection: true,
            runtimeGateway: runtime
        )
        XCTAssertTrue(
            runtime.loadRequests.isEmpty,
            "speculative prewarm must not issue or wait on a second load"
        )

        probe.releaseHeldPhase()
        await startupLoad.value

        XCTAssertEqual(runtime.loadRequests.count, 1)
        XCTAssertEqual(library.loadState, .loaded(modelID: Self.modelIDString))
    }

    func testQueuedChatPrewarmCannotDeadlockStartupModelLoad() async throws {
        // HOTFIX-LOAD-02 expected RED: the queued prewarm holds the shared
        // execution lane while waiting for the startup load, so this test times
        // out before the startup load can issue its only runtime request.
        let fixture = try makeFixture(location: .managed)
        let runtime = ContentBoundLoadingRuntimeStub(reply: .echoRequestFingerprint)
        let coordinator = ModelExecutionCoordinator(
            runtimeClient: RuntimeSafetyClient(base: runtime),
            configuration: ModelExecutionConfiguration(
                maximumQueuedTasks: 7,
                agingIntervalTicks: 10
            ),
            monotonicNow: { 0 }
        )
        let probe = AuthorizationPhaseProbe(holding: .authorize)
        let library = try makeLibrary(
            fixture: fixture,
            runtime: coordinator,
            authorizationExecutor: makeAuthorizationExecutor(probe: probe)
        )
        let blockerGate = ArchitectureUXAsyncGate()
        let blockerStarted = ArchitectureUXAsyncSignal()
        let blockerRequest = ModelExecutionRequest(
            taskID: ModelExecutionTaskID(rawValue: "startup-prewarm-blocker-394"),
            operation: .generation,
            priority: .foregroundInteractive,
            modelBinding: nil,
            duplicateKey: nil
        )
        let blocker = Task {
            try await coordinator.execute(blockerRequest) { permit -> Void in
                await permit.markRunning()
                await blockerStarted.signal()
                await blockerGate.wait()
            }
        }
        defer {
            probe.releaseHeldPhase()
            Task { await blockerGate.open() }
        }

        await blockerStarted.wait()
        library.prewarmChatModel()
        try await waitForArchitectureUXRuntime("chat prewarm queued behind blocker") {
            await coordinator.queuedTaskCount == 1
        }

        let startupLoad = Task { @MainActor in
            await library.activateAndLoad(modelID: Self.modelIDString)
        }
        let authorizationStarted = await Task.detached {
            probe.waitUntilHeldPhaseEntered()
        }.value
        XCTAssertTrue(authorizationStarted, "startup authorization never began")
        XCTAssertEqual(library.loadState, .loading(modelID: Self.modelIDString))

        await blockerGate.open()
        try await blocker.value
        try await waitForArchitectureUXRuntime("chat prewarm released shared lane") {
            let active = await coordinator.runtimeResidencyActiveTaskCount
            let queued = await coordinator.queuedTaskCount
            return active == 0 && queued == 0
        }
        XCTAssertTrue(
            runtime.loadRequests.isEmpty,
            "prewarm must release the lane before startup authorization finishes"
        )

        probe.releaseHeldPhase()
        await startupLoad.value

        XCTAssertEqual(runtime.loadRequests.count, 1)
        XCTAssertEqual(library.loadState, .loaded(modelID: Self.modelIDString))
        let finalActiveTaskCount = await coordinator.runtimeResidencyActiveTaskCount
        let finalQueuedTaskCount = await coordinator.queuedTaskCount
        XCTAssertEqual(finalActiveTaskCount, 0)
        XCTAssertEqual(finalQueuedTaskCount, 0)
    }

    private static var pinnedModel: CorpusAnalysisPinnedModel {
        CorpusAnalysisPinnedModel(
            modelRepository: repositoryID,
            modelRevision: revision,
            contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
            contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
            artifactFingerprintSHA256: fingerprint
        )
    }

    private func makeLibrary(
        fixture: Fixture,
        runtime: ContentBoundLoadingRuntimeStub
    ) throws -> ModelLibrary {
        try fixture.store.models.upsertModel(ModelRecord(
            id: Self.modelIDString,
            displayName: "Synthetic exact review model",
            path: fixture.modelDirectory.path,
            bookmarkData: fixture.location == .unmanaged ? Data("synthetic-bookmark".utf8) : nil
        ))
        let library = ModelLibrary(
            store: fixture.store,
            runtimeClient: runtime,
            managedModelRoots: [fixture.managedRoot]
        )
        library.refresh()
        return library
    }

    private func makeLibrary(
        fixture: Fixture,
        runtime: any ModelExecutionGateway,
        authorizationExecutor: ContentBoundAuthorizationExecutor
    ) throws -> ModelLibrary {
        try fixture.store.models.upsertModel(ModelRecord(
            id: Self.modelIDString,
            displayName: "Synthetic exact review model",
            path: fixture.modelDirectory.path,
            bookmarkData: nil
        ))
        let library = ModelLibrary(
            store: fixture.store,
            runtimeClient: runtime,
            managedModelRoots: [fixture.managedRoot],
            authorizationExecutor: authorizationExecutor
        )
        library.refresh()
        return library
    }

    private func makeAuthorizationExecutor(
        probe: AuthorizationPhaseProbe
    ) -> ContentBoundAuthorizationExecutor {
        ContentBoundAuthorizationExecutor(
            authorize: { modelDirectory, managedRoot, expectedSHA256 in
                try probe.enter(.authorize)
                return try SignedReleaseModelAuthorization.authorize(
                    modelDirectory: modelDirectory,
                    managedRoot: managedRoot,
                    expectedSHA256: expectedSHA256
                )
            },
            makeLoadRequest: { authorization, modelID, displayName in
                try probe.enter(.makeLoadRequest)
                return try authorization.makeLoadRequest(
                    modelID: modelID,
                    displayName: displayName
                )
            }
        )
    }

    private func observeMainActorHeartbeat(
        whileHeldBy probe: AuthorizationPhaseProbe
    ) async -> (entered: Bool, heartbeatRan: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let entered = probe.waitUntilHeldPhaseEntered()
                guard entered else {
                    probe.releaseHeldPhase()
                    continuation.resume(returning: (false, false))
                    return
                }

                let heartbeat = DispatchSemaphore(value: 0)
                Task { @MainActor in heartbeat.signal() }
                let heartbeatRan = heartbeat.wait(timeout: .now() + 2) == .success
                probe.releaseHeldPhase()
                continuation.resume(returning: (true, heartbeatRan))
            }
        }
    }

    private func makeFixture(location: FixtureLocation) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ModelLibraryContentBoundLoading-\(UUID().uuidString)",
            isDirectory: true
        )
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let modelParent = location == .managed
            ? managedRoot
            : base.appendingPathComponent("ExternalModels", isDirectory: true)
        let modelDirectory = modelParent.appendingPathComponent(
            "exact-review-model",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data("protected-release-weight-canary".utf8),
        ]
        for (relativePath, data) in payloads {
            try data.write(to: modelDirectory.appendingPathComponent(relativePath))
        }
        let manifest = ModelArtifactManifest(
            repositoryID: Self.repositoryID,
            revision: Self.revision,
            files: payloads.map { relativePath, data in
                ModelArtifactManifest.File(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(data)
                )
            }
        )
        try ManagedModelStorage.writeManifest(
            manifest,
            to: ManagedModelStorage.manifestURL(in: modelDirectory)
        )
        let store = try SupraStore(url: base.appendingPathComponent("test.sqlite"))
        return Fixture(
            location: location,
            managedRoot: managedRoot,
            modelDirectory: modelDirectory,
            store: store
        )
    }

    private func thrownError<T: Sendable>(
        _ operation: () async throws -> T
    ) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private enum FixtureLocation {
    case managed
    case unmanaged
}

private struct Fixture {
    var location: FixtureLocation
    var managedRoot: URL
    var modelDirectory: URL
    var store: SupraStore
}

private enum HeldAuthorizationPhase: String, CaseIterable, Sendable {
    case authorize
    case makeLoadRequest
}

private final class AuthorizationPhaseProbe: @unchecked Sendable {
    private let heldPhase: HeldAuthorizationPhase
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var phases: [HeldAuthorizationPhase] = []

    init(holding heldPhase: HeldAuthorizationPhase) {
        self.heldPhase = heldPhase
    }

    var enteredPhases: [HeldAuthorizationPhase] {
        lock.withLock { phases }
    }

    func enter(_ phase: HeldAuthorizationPhase) throws {
        lock.withLock { phases.append(phase) }
        if phase == heldPhase {
            entered.signal()
            release.wait()
        }
        try Task.checkCancellation()
    }

    func waitUntilHeldPhaseEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func releaseHeldPhase() {
        release.signal()
    }
}

private final class ContentBoundLoadingRuntimeStub: RuntimeClientProtocol, @unchecked Sendable {
    enum Reply {
        case echoRequestFingerprint
        case missingFingerprint
        case fixedFingerprint(String)
    }

    private let lock = NSLock()
    private let reply: Reply
    private var recordedLoadRequests: [LoadModelRequest] = []
    private var heldModelID: ModelID?

    init(reply: Reply, initiallyLoadedModelID: ModelID? = nil) {
        self.reply = reply
        self.heldModelID = initiallyLoadedModelID
    }

    var loadRequests: [LoadModelRequest] {
        lock.withLock { recordedLoadRequests }
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        lock.withLock {
            recordedLoadRequests.append(request)
            heldModelID = request.modelID
        }
        let verifiedFingerprint: String?
        switch reply {
        case .echoRequestFingerprint:
            verifiedFingerprint = request.contentBinding?.fingerprintSHA256
        case .missingFingerprint:
            verifiedFingerprint = nil
        case .fixedFingerprint(let value):
            verifiedFingerprint = value
        }
        return LoadModelResponse(
            status: .loaded,
            modelID: request.modelID,
            metrics: RuntimeMetrics(loadTimeMs: 37),
            verifiedModelSHA256: verifiedFingerprint
        )
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        lock.withLock { heldModelID = nil }
        return UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: lock.withLock { heldModelID })
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        let modelID = lock.withLock { heldModelID }
        return RuntimeStatus(
            state: modelID == nil ? .modelUnloaded : .modelLoaded,
            loadedModelID: modelID,
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
