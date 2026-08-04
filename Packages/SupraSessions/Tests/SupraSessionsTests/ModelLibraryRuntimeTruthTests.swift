import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Reported bug (2026-07-19): generating a chronology failed with the runtime's
/// "No matching runtime model is loaded." even though the feature resolves and
/// ensures its routed model first. Every generation surface (chat, chronology,
/// drafting, billing, outputs, research) funnels through
/// `ensureLoadedChatModelID` / `ensureLoadedRoutedModelID`, whose fast path
/// trusts the app-side `loadState` cache. That cache goes stale whenever the
/// XPC runtime service is reclaimed or crashes between uses, so ensure handed
/// generation a model the service no longer held instead of loading it.
///
/// Expected RED reasons:
/// - After a simulated service restart, ensure returns success from the stale
///   cache without issuing a new load RPC (load count stays 1, runtime still
///   holds nothing).
/// - The fast path never consults `runtimeStatus()` (status call count 0).
/// - While another caller's load of the same model is in flight, ensure fails
///   immediately ("did not confirm") instead of waiting for that load.
final class ModelLibraryRuntimeTruthTests: XCTestCase {

    /// A runtime stub that reports the truth: `runtimeStatus()` reflects the
    /// last successful load, `simulateServiceRestart()` models the OS reclaiming
    /// the XPC service (a fresh service holds no model), and an optional load
    /// delay models a multi-second MLX load in flight.
    private final class RestartableRuntimeStub: RuntimeClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private let blockFirstLoad: Bool
        private var _held: ModelID?
        private var _loadRequests: [LoadModelRequest] = []
        private var _statusCalls = 0
        private var _firstLoadContinuation: CheckedContinuation<Void, Never>?
        private var _firstLoadReleased = false
        var loadDelayNanoseconds: UInt64 = 0

        var loadRequestCount: Int { lock.withLock { _loadRequests.count } }
        var loadRequestedModelIDs: [ModelID] { lock.withLock { _loadRequests.map(\.modelID) } }
        var statusCallCount: Int { lock.withLock { _statusCalls } }
        var runtimeHeldModelID: ModelID? { lock.withLock { _held } }

        init(blockFirstLoad: Bool = false) {
            self.blockFirstLoad = blockFirstLoad
        }

        func simulateServiceRestart() {
            lock.withLock { _held = nil }
        }

        func releaseFirstLoad() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                _firstLoadReleased = true
                defer { _firstLoadContinuation = nil }
                return _firstLoadContinuation
            }
            continuation?.resume()
        }

        func connect() async throws {}

        func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
            let requestNumber = lock.withLock { () -> Int in
                _loadRequests.append(request)
                return _loadRequests.count
            }
            if blockFirstLoad, requestNumber == 1 {
                await withCheckedContinuation { continuation in
                    let released = lock.withLock { () -> Bool in
                        guard !_firstLoadReleased else { return true }
                        _firstLoadContinuation = continuation
                        return false
                    }
                    if released { continuation.resume() }
                }
            } else if loadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: loadDelayNanoseconds)
            }
            lock.withLock { _held = request.modelID }
            return LoadModelResponse(status: .loaded, modelID: request.modelID)
        }

        func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
            CountTokensResponse(modelID: request.modelID, counts: request.texts.map { ($0.utf8.count + 3) / 4 })
        }

        func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
            CancelGenerationResponse(status: .cancelled, generationID: generationID)
        }

        func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] {
            []
        }

        func unloadModel() async throws -> UnloadModelResponse {
            lock.withLock { _held = nil }
            return UnloadModelResponse(status: .unloaded)
        }

        func reloadCurrentModel() async throws -> LoadModelResponse {
            LoadModelResponse(status: .loaded, modelID: lock.withLock { _held } ?? ModelID())
        }

        func runtimeStatus() async throws -> RuntimeStatus {
            let held = lock.withLock { () -> ModelID? in
                _statusCalls += 1
                return _held
            }
            return RuntimeStatus(
                state: held == nil ? .modelUnloaded : .modelLoaded,
                loadedModelID: held,
                activeGenerationID: nil,
                message: nil,
                metrics: nil
            )
        }

        func restartRuntimeService() async throws {}
    }

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelRuntimeTruthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    // MARK: - Stale cache after a service restart (the chronology bug)

    @MainActor
    func testEnsureRoutedModelReloadsAfterRuntimeServiceRestart() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let model = try library.addModel(displayName: "Chronology Task Model", path: "/tmp/chronology", bookmarkData: nil)

        let first = await library.ensureLoadedRoutedModelID(for: .drafting)
        guard case .success = first else { return XCTFail("initial ensure should load and succeed: \(first)") }
        XCTAssertEqual(stub.loadRequestCount, 1)

        // The OS reclaims the idle XPC service; the app-side cache still says loaded.
        stub.simulateServiceRestart()
        XCTAssertEqual(library.loadedModelID?.rawValue.uuidString, model.id, "precondition: cache is stale")

        let second = await library.ensureLoadedRoutedModelID(for: .drafting)

        guard case let .success(modelID) = second else {
            return XCTFail("ensure must reload after a service restart, got \(second)")
        }
        XCTAssertEqual(modelID.rawValue.uuidString, model.id)
        XCTAssertEqual(stub.loadRequestCount, 2, "a fresh load RPC must reach the restarted service")
        XCTAssertEqual(stub.runtimeHeldModelID?.rawValue.uuidString, model.id, "the runtime must actually hold the model again")
    }

    @MainActor
    func testEnsureChatModelReloadsAfterRuntimeServiceRestart() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let model = try library.addModel(displayName: "Pinned Chat Model", path: "/tmp/chat", bookmarkData: nil)
        guard let uuid = UUID(uuidString: model.id) else { return XCTFail("model id is not a UUID") }
        library.setForcedModel(ModelID(uuid))

        let first = await library.ensureLoadedChatModelID(for: .legalReasoning)
        guard case .success = first else { return XCTFail("initial ensure should load and succeed: \(first)") }

        stub.simulateServiceRestart()

        let second = await library.ensureLoadedChatModelID(for: .legalReasoning)

        guard case .success = second else {
            return XCTFail("chat ensure must reload after a service restart, got \(second)")
        }
        XCTAssertEqual(stub.loadRequestCount, 2)
        XCTAssertEqual(stub.runtimeHeldModelID?.rawValue.uuidString, model.id)
    }

    // MARK: - Racing an in-flight load must wait, not fail

    @MainActor
    func testEnsureWaitsForInFlightLoadOfTheSameModel() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub()
        stub.loadDelayNanoseconds = 500_000_000
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let model = try library.addModel(displayName: "Prewarming Model", path: "/tmp/prewarm", bookmarkData: nil)

        // A prewarm (screen open) kicks off the load; the user clicks Generate
        // while it is still in flight.
        let prewarm = Task { await library.activateAndLoad(modelID: model.id) }
        var waited = 0
        while library.loadState != .loading(modelID: model.id), waited < 200 {
            waited += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .loading = library.loadState else {
            prewarm.cancel()
            return XCTFail("precondition: the prewarm load should be in flight")
        }

        let result = await library.ensureLoadedRoutedModelID(for: .drafting)
        await prewarm.value

        guard case let .success(modelID) = result else {
            return XCTFail("ensure must wait out the in-flight load and succeed, got \(result)")
        }
        XCTAssertEqual(modelID.rawValue.uuidString, model.id)
        XCTAssertEqual(stub.loadRequestCount, 1, "waiting must not issue a duplicate load")
    }

    // Expected RED: settleInFlightLoad swallows CancellationError from Task.sleep.
    // When the first load resolves while ensure is asleep, the cancelled task wakes
    // and replaces it with the newly assigned model.
    @MainActor
    func testCancelledEnsureWaitingOnAnotherLoadDoesNotReplaceIt() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub(blockFirstLoad: true)
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let first = try library.addModel(
            displayName: "First Loading Model",
            path: "/tmp/first-loading",
            bookmarkData: nil
        )
        let second = try library.addModel(
            displayName: "Second Assigned Model",
            path: "/tmp/second-assigned",
            bookmarkData: nil
        )
        let firstModelID = ModelID(try XCTUnwrap(UUID(uuidString: first.id)))

        let prewarm = Task { await library.activateAndLoad(modelID: first.id) }
        var waited = 0
        while library.loadState != .loading(modelID: first.id), waited < 200 {
            waited += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .loading = library.loadState else {
            stub.releaseFirstLoad()
            await prewarm.value
            return XCTFail("precondition: the model load should be in flight")
        }
        library.assignModel(second.id, to: .drafting)

        let ensureStarted = expectation(description: "ensure started")
        let ensure = Task {
            ensureStarted.fulfill()
            return await library.ensureLoadedRoutedModelID(for: .drafting)
        }
        await fulfillment(of: [ensureStarted], timeout: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        stub.releaseFirstLoad()
        await prewarm.value
        ensure.cancel()
        let result = await ensure.value

        guard case let .failure(issue) = result else {
            return XCTFail("cancelled ensure unexpectedly succeeded: \(result)")
        }
        XCTAssertTrue(
            issue.message.localizedCaseInsensitiveContains("cancelled"),
            "cancelled wait surfaced a stale load result: \(issue.message)"
        )
        XCTAssertEqual(stub.loadRequestedModelIDs, [firstModelID])
        XCTAssertEqual(stub.runtimeHeldModelID?.rawValue.uuidString, first.id)
        XCTAssertEqual(library.loadedModelID?.rawValue.uuidString, first.id)
    }

    // Expected RED: an ensure task cancelled before entry still activates the
    // assigned model because neither ensure nor activateAndLoad checks cancellation.
    @MainActor
    func testAlreadyCancelledEnsureDoesNotActivateAssignedModel() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let first = try library.addModel(displayName: "Loaded Model", path: "/tmp/loaded", bookmarkData: nil)
        let second = try library.addModel(displayName: "Assigned Model", path: "/tmp/assigned", bookmarkData: nil)
        let firstModelID = ModelID(try XCTUnwrap(UUID(uuidString: first.id)))
        await library.activateAndLoad(modelID: first.id)
        library.assignModel(second.id, to: .drafting)

        let ensure = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await library.ensureLoadedRoutedModelID(for: .drafting)
        }
        let result = await ensure.value

        guard case let .failure(issue) = result else {
            return XCTFail("already-cancelled ensure unexpectedly succeeded: \(result)")
        }
        XCTAssertTrue(issue.message.localizedCaseInsensitiveContains("cancelled"))
        XCTAssertEqual(stub.loadRequestedModelIDs, [firstModelID])
        XCTAssertEqual(stub.runtimeHeldModelID?.rawValue.uuidString, first.id)
    }

    // Expected RED: ensure directly awaits the continuation-backed load RPC.
    // Cancelling the caller therefore cannot return until the shared load replies.
    @MainActor
    func testCancelledEnsureReturnsBeforeContinuationBackedSharedLoadCompletes() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub(blockFirstLoad: true)
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let model = try library.addModel(
            displayName: "Continuation-backed Drafting Model",
            path: "/tmp/continuation-backed",
            bookmarkData: nil
        )
        var result: Result<ModelID, ModelRouteResolutionIssue>?
        let returned = expectation(description: "cancelled ensure returned")
        let ensure = Task { @MainActor in
            result = await library.ensureLoadedRoutedModelID(for: .drafting)
            returned.fulfill()
        }

        var waited = 0
        while stub.loadRequestCount == 0, waited < 200 {
            waited += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard stub.loadRequestCount == 1 else {
            ensure.cancel()
            stub.releaseFirstLoad()
            await ensure.value
            return XCTFail("precondition: ensure never started the model load")
        }

        ensure.cancel()
        await fulfillment(of: [returned], timeout: 1.0)
        stub.releaseFirstLoad()
        await ensure.value

        guard case let .failure(issue) = result else {
            return XCTFail("cancelled ensure unexpectedly succeeded: \(String(describing: result))")
        }
        XCTAssertTrue(issue.message.localizedCaseInsensitiveContains("cancelled"))
        XCTAssertEqual(stub.loadRequestCount, 1, "cancellation must not duplicate the shared load")

        waited = 0
        while (stub.runtimeHeldModelID == nil
            || library.loadedModelID?.rawValue.uuidString != model.id), waited < 200 {
            waited += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(stub.runtimeHeldModelID?.rawValue.uuidString, model.id)
        XCTAssertEqual(library.loadedModelID?.rawValue.uuidString, model.id)
    }

    // MARK: - Guards: the fast path stays fast, and truth is actually consulted

    @MainActor
    func testEnsureDoesNotReloadWhenRuntimeConfirmsTheModel() async throws {
        let store = try makeStore()
        let stub = RestartableRuntimeStub()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        _ = try library.addModel(displayName: "Confirmed Model", path: "/tmp/confirmed", bookmarkData: nil)

        _ = await library.ensureLoadedRoutedModelID(for: .drafting)
        let statusCallsAfterLoad = stub.statusCallCount
        let again = await library.ensureLoadedRoutedModelID(for: .drafting)

        guard case .success = again else { return XCTFail("repeat ensure should succeed: \(again)") }
        XCTAssertEqual(stub.loadRequestCount, 1, "a confirmed model must not be reloaded (evicting a multi-GB load)")
        XCTAssertGreaterThan(
            stub.statusCallCount, statusCallsAfterLoad,
            "the fast path must confirm with the runtime, not trust the app-side cache"
        )
    }
}
