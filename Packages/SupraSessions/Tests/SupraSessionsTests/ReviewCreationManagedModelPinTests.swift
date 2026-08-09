import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// T-RP-CREATE-MODEL-01
///
/// Review creation must freeze the exact bytes of the explicitly selected,
/// app-managed model before it persists a runnable request. Resolving a chat
/// route, trusting a model UUID, or loading the runtime are not substitutes for
/// this content identity.
@MainActor
final class ReviewCreationManagedModelPinTests: XCTestCase {
    private static let selectedModelIDString = "77777777-7777-4777-8777-777777777777"
    private static let canaryModelIDString = "11111111-1111-4111-8111-111111111111"
    private static let selectedRepository = "mlx-community/Release-Smoke-4bit"
    private static let selectedRevision = String(repeating: "a", count: 40)
    private static let selectedFingerprint =
        "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"

    func testTRPCREATEMODEL01ExplicitManagedSelectionProducesExactPinWithoutRuntimeLoad() async throws {
        // Expected RED: ModelLibrary cannot derive a CorpusAnalysisPinnedModel
        // from an explicitly selected registered model ID.
        let fixture = try makeFixture()
        let runtime = StubRuntimeClient()
        let library = try makeLibrary(fixture: fixture, runtime: runtime)
        let selectedModelID = ModelID(
            try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
        )

        let pin = try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)

        XCTAssertEqual(pin.modelRepository, Self.selectedRepository)
        XCTAssertFalse(
            pin.modelRepository == "mlx-community/Default-Review-Model-4bit",
            "the explicit selected model must not fall back to the other registered model"
        )
        XCTAssertEqual(pin.modelRevision, Self.selectedRevision)
        XCTAssertEqual(pin.modelRevision.count, 40)
        XCTAssertFalse(pin.modelRevision == String(repeating: "0", count: 40))
        XCTAssertEqual(
            pin.contentBindingAlgorithm,
            RuntimeModelContentBinding.fingerprintAlgorithm
        )
        XCTAssertEqual(
            pin.contentBindingSchemaVersion,
            RuntimeModelContentBinding.supportedManifestSchemaVersion
        )
        XCTAssertEqual(pin.artifactFingerprintSHA256, Self.selectedFingerprint)
        XCTAssertEqual(pin.artifactFingerprintSHA256.count, 64)
        XCTAssertFalse(
            pin.artifactFingerprintSHA256 == String(repeating: "0", count: 64)
        )
        XCTAssertNoThrow(try pin.validate())
        XCTAssertTrue(
            runtime.loadRequests.isEmpty,
            "pin inspection must not load or mutate the runtime"
        )
    }

    func testTRPCREATEMODEL01RejectsBookmarkBackedAndOutsideManagedSelections() async throws {
        // Expected RED: no Review pin API enforces the app-managed-only boundary.
        for placement in [ModelPlacement.bookmarkBacked, .outsideManagedRoot] {
            let fixture = try makeFixture(placement: placement)
            let runtime = StubRuntimeClient()
            let library = try makeLibrary(fixture: fixture, runtime: runtime)
            let selectedModelID = ModelID(
                try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
            )

            let error = await thrownError {
                try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)
            }

            XCTAssertEqual(
                error as? CorpusAnalysisModelPinError,
                .modelNotManaged(Self.selectedModelIDString),
                "\(placement) must fail at the managed-model boundary before bookmark resolution"
            )
            XCTAssertTrue(
                runtime.loadRequests.isEmpty,
                "rejected \(placement) selection must not reach the runtime"
            )
        }
    }

    func testTRPCREATEMODEL01RepinningSameRegisteredIDRecomputesChangedVerifiedBytes() async throws {
        // Expected RED: no Review pin API exists, and a future implementation
        // must not cache a content fingerprint forever under the registered UUID.
        let fixture = try makeFixture()
        let runtime = StubRuntimeClient()
        let library = try makeLibrary(fixture: fixture, runtime: runtime)
        let selectedModelID = ModelID(
            try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
        )
        let first = try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)
        let changedPayloads = [
            "config.json": Data(#"{"model_type":"qwen2","revision_canary":911}"#.utf8),
            "model.safetensors": Data("changed-protected-release-weight-canary-911".utf8),
        ]
        try writeModel(
            to: fixture.selectedModelDirectory,
            repository: Self.selectedRepository,
            revision: Self.selectedRevision,
            payloads: changedPayloads,
            writeManifest: true
        )

        let second = try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)

        XCTAssertEqual(first.modelRepository, second.modelRepository)
        XCTAssertEqual(first.modelRevision, second.modelRevision)
        XCTAssertEqual(first.contentBindingAlgorithm, second.contentBindingAlgorithm)
        XCTAssertEqual(first.contentBindingSchemaVersion, second.contentBindingSchemaVersion)
        XCTAssertEqual(first.artifactFingerprintSHA256.count, 64)
        XCTAssertEqual(second.artifactFingerprintSHA256.count, 64)
        XCTAssertNotEqual(
            second.artifactFingerprintSHA256,
            first.artifactFingerprintSHA256,
            "the same registered UUID must be re-inspected after verified artifact bytes change"
        )
        XCTAssertTrue(runtime.loadRequests.isEmpty)
    }

    func testTRPCREATEMODEL01RejectsUnverifiedMutatedAndTreeExtraInstalls() async throws {
        // Expected RED: no Review pin API reuses the signed-release manifest,
        // byte, and exclusive-tree verifier before returning a durable pin.
        for integrity in [ModelIntegrity.missingManifest, .mutatedArtifact, .extraTreeEntry] {
            let fixture = try makeFixture(integrity: integrity)
            let runtime = StubRuntimeClient()
            let library = try makeLibrary(fixture: fixture, runtime: runtime)
            let selectedModelID = ModelID(
                try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
            )

            let error = await thrownError {
                try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)
            }

            XCTAssertNotNil(error, "\(integrity) must not produce a durable Review pin")
            XCTAssertTrue(
                runtime.loadRequests.isEmpty,
                "rejected \(integrity) install must not reach the runtime"
            )
        }
    }

    func testTRPCREATEMODEL01PinInspectionLeavesMainActorResponsive() async throws {
        // Expected RED: ModelLibrary has no managed pinning executor seam, so
        // content hashing cannot be proven to run away from the MainActor.
        let fixture = try makeFixture()
        let runtime = StubRuntimeClient()
        let probe = PinInspectionProbe()
        let library = try makeLibrary(
            fixture: fixture,
            runtime: runtime,
            pinningExecutor: makePinningExecutor(probe: probe)
        )
        let selectedModelID = ModelID(
            try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
        )

        let operation = Task { @MainActor in
            try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)
        }
        let observation = await observeMainActorHeartbeat(whileHeldBy: probe)
        let pin = try await operation.value

        XCTAssertTrue(observation.entered, "pin inspection was never entered")
        XCTAssertTrue(
            observation.heartbeatRan,
            "MainActor was blocked while the model tree was being inspected"
        )
        XCTAssertEqual(pin.artifactFingerprintSHA256, Self.selectedFingerprint)
        XCTAssertTrue(runtime.loadRequests.isEmpty)
    }

    func testTRPCREATEMODEL01CancellationPreventsPinResultAndRuntimeLoad() async throws {
        // Expected RED: ModelLibrary has no cancellable off-main pin inspection
        // path for Review creation.
        let fixture = try makeFixture()
        let runtime = StubRuntimeClient()
        let probe = PinInspectionProbe()
        let library = try makeLibrary(
            fixture: fixture,
            runtime: runtime,
            pinningExecutor: makePinningExecutor(probe: probe)
        )
        let selectedModelID = ModelID(
            try XCTUnwrap(UUID(uuidString: Self.selectedModelIDString))
        )
        let operation = Task { @MainActor in
            try await library.makeCorpusAnalysisPinnedModel(modelID: selectedModelID)
        }

        let entered = await Task.detached { probe.waitUntilEntered() }.value
        operation.cancel()
        probe.release()
        let error = await thrownError { try await operation.value }

        XCTAssertTrue(entered, "pin inspection was never entered")
        XCTAssertNotNil(error, "a cancelled inspection must not return a durable pin")
        XCTAssertTrue(operation.isCancelled)
        XCTAssertTrue(runtime.loadRequests.isEmpty)
    }

    private func makeLibrary(
        fixture: Fixture,
        runtime: StubRuntimeClient
    ) throws -> ModelLibrary {
        try registerFixtureModels(fixture)
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
        runtime: StubRuntimeClient,
        pinningExecutor: ManagedModelPinningExecutor
    ) throws -> ModelLibrary {
        try registerFixtureModels(fixture)
        let library = ModelLibrary(
            store: fixture.store,
            runtimeClient: runtime,
            managedModelRoots: [fixture.managedRoot],
            authorizationExecutor: .live,
            modelPinningExecutor: pinningExecutor
        )
        library.refresh()
        return library
    }

    private func registerFixtureModels(_ fixture: Fixture) throws {
        try fixture.store.models.upsertModel(ModelRecord(
            id: Self.canaryModelIDString,
            displayName: "Default review model canary",
            path: fixture.canaryModelDirectory.path
        ))
        try fixture.store.models.upsertModel(ModelRecord(
            id: Self.selectedModelIDString,
            displayName: "Selected exact review model",
            path: fixture.selectedModelDirectory.path,
            bookmarkData: fixture.placement == .bookmarkBacked
                ? Data("synthetic-external-bookmark".utf8)
                : nil
        ))
    }

    private func makePinningExecutor(
        probe: PinInspectionProbe
    ) -> ManagedModelPinningExecutor {
        let expectedFingerprint = Self.selectedFingerprint
        return ManagedModelPinningExecutor(inspect: { modelDirectory, managedRoot in
            try probe.enter()
            return try SignedReleaseModelAuthorization.authorize(
                modelDirectory: modelDirectory,
                managedRoot: managedRoot,
                expectedSHA256: expectedFingerprint
            ).contentBinding
        })
    }

    private func observeMainActorHeartbeat(
        whileHeldBy probe: PinInspectionProbe
    ) async -> (entered: Bool, heartbeatRan: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let entered = probe.waitUntilEntered()
                guard entered else {
                    probe.release()
                    continuation.resume(returning: (false, false))
                    return
                }

                let heartbeat = DispatchSemaphore(value: 0)
                Task { @MainActor in heartbeat.signal() }
                let heartbeatRan = heartbeat.wait(timeout: .now() + 2) == .success
                probe.release()
                continuation.resume(returning: (true, heartbeatRan))
            }
        }
    }

    private func makeFixture(
        placement: ModelPlacement = .managed,
        integrity: ModelIntegrity = .verified
    ) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviewCreationManagedModelPin-\(UUID().uuidString)",
            isDirectory: true
        )
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let externalRoot = base.appendingPathComponent("ExternalModels", isDirectory: true)
        let selectedParent = placement == .outsideManagedRoot ? externalRoot : managedRoot
        let selectedModelDirectory = selectedParent.appendingPathComponent(
            "selected-exact-review-model",
            isDirectory: true
        )
        let canaryModelDirectory = managedRoot.appendingPathComponent(
            "default-review-model-canary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedModelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: canaryModelDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let selectedPayloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data("protected-release-weight-canary".utf8),
        ]
        try writeModel(
            to: selectedModelDirectory,
            repository: Self.selectedRepository,
            revision: Self.selectedRevision,
            payloads: selectedPayloads,
            writeManifest: integrity != .missingManifest
        )
        try writeModel(
            to: canaryModelDirectory,
            repository: "mlx-community/Default-Review-Model-4bit",
            revision: String(repeating: "b", count: 40),
            payloads: [
                "config.json": Data(#"{"model_type":"default-canary"}"#.utf8),
                "model.safetensors": Data("default-review-weight-canary".utf8),
            ],
            writeManifest: true
        )

        switch integrity {
        case .verified, .missingManifest:
            break
        case .mutatedArtifact:
            let weights = selectedModelDirectory.appendingPathComponent("model.safetensors")
            let original = try Data(contentsOf: weights)
            try Data(repeating: 0x58, count: original.count).write(to: weights)
        case .extraTreeEntry:
            try Data("undeclared-review-note".utf8).write(
                to: selectedModelDirectory.appendingPathComponent("notes.txt")
            )
        }

        return Fixture(
            placement: placement,
            managedRoot: managedRoot,
            selectedModelDirectory: selectedModelDirectory,
            canaryModelDirectory: canaryModelDirectory,
            store: try SupraStore(url: base.appendingPathComponent("test.sqlite"))
        )
    }

    private func writeModel(
        to directory: URL,
        repository: String,
        revision: String,
        payloads: [String: Data],
        writeManifest: Bool
    ) throws {
        for (relativePath, data) in payloads {
            try data.write(to: directory.appendingPathComponent(relativePath))
        }
        if writeManifest {
            let manifest = ModelArtifactManifest(
                repositoryID: repository,
                revision: revision,
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
                to: ManagedModelStorage.manifestURL(in: directory)
            )
        }
    }

    private func thrownError<T>(
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

private enum ModelPlacement: Equatable, CustomStringConvertible {
    case managed
    case bookmarkBacked
    case outsideManagedRoot

    var description: String {
        switch self {
        case .managed: "managed"
        case .bookmarkBacked: "bookmark-backed"
        case .outsideManagedRoot: "outside-managed-root"
        }
    }
}

private enum ModelIntegrity: Equatable, CustomStringConvertible {
    case verified
    case missingManifest
    case mutatedArtifact
    case extraTreeEntry

    var description: String {
        switch self {
        case .verified: "verified"
        case .missingManifest: "missing-manifest"
        case .mutatedArtifact: "mutated-artifact"
        case .extraTreeEntry: "extra-tree-entry"
        }
    }
}

private struct Fixture {
    var placement: ModelPlacement
    var managedRoot: URL
    var selectedModelDirectory: URL
    var canaryModelDirectory: URL
    var store: SupraStore
}

private final class PinInspectionProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)

    func enter() throws {
        entered.signal()
        releaseGate.wait()
        try Task.checkCancellation()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        releaseGate.signal()
    }
}
