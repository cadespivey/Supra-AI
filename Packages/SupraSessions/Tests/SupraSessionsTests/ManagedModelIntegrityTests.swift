import Foundation
import SupraCore
import SupraRuntimeClient
@testable import SupraSessions
import SupraStore
import XCTest

final class ManagedModelIntegrityTests: XCTestCase {
    private let repoID = "mlx-community/Integrity-Test-4bit"
    private let revisionA = String(repeating: "a", count: 40)
    private let revisionB = String(repeating: "b", count: 40)

    @MainActor
    func testACR_MODEL_successWritesRevisionBoundVerifiedManifest() async throws {
        let context = try makeContext()
        let payloads = validPayloads()
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let fetcher = IntegrityFetcher(manifest: manifest, payloads: payloads)

        await context.controller(fetcher: fetcher).performDownload(repoID: repoID, displayName: "Verified")

        let modelDirectory = context.modelDirectory(repoID: repoID)
        let installed = try ManagedModelStorage.loadVerifiedManifest(at: modelDirectory)
        XCTAssertEqual(installed, manifest)
        XCTAssertEqual(installed.schemaVersion, ModelArtifactManifest.currentSchemaVersion)
        XCTAssertEqual(installed.revision, revisionA)
        XCTAssertEqual(Set(installed.files.map(\.relativePath)), Set(payloads.keys))
        XCTAssertTrue(installed.files.allSatisfy { $0.size > 0 && !$0.digest.isEmpty })
        XCTAssertEqual(Set(fetcher.requestedRevisions()), [revisionA], "every file URL must be revision-pinned")
        XCTAssertFalse(containsPartialFile(in: modelDirectory))
    }

    @MainActor
    func testACR_MODEL_sameSizeCorruptionIsRedownloaded() async throws {
        let context = try makeContext()
        let payloads = validPayloads()
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        await context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))
            .performDownload(repoID: repoID, displayName: "Verified")

        let weight = context.modelDirectory(repoID: repoID).appendingPathComponent("model.safetensors")
        let original = try XCTUnwrap(payloads["model.safetensors"])
        try Data(repeating: 0x58, count: original.count).write(to: weight)
        let repair = IntegrityFetcher(manifest: manifest, payloads: payloads)

        await context.controller(fetcher: repair).performDownload(repoID: repoID, displayName: "Verified")

        XCTAssertEqual(repair.downloadedFiles(), ["model.safetensors"])
        XCTAssertEqual(try Data(contentsOf: weight), original)
        _ = try ManagedModelStorage.loadVerifiedManifest(at: context.modelDirectory(repoID: repoID))
    }

    @MainActor
    func testACR_MODEL_truncatedCheckpointIsRedownloaded() async throws {
        let context = try makeContext()
        let payloads = validPayloads()
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        await context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))
            .performDownload(repoID: repoID, displayName: "Verified")

        let weight = context.modelDirectory(repoID: repoID).appendingPathComponent("model.safetensors")
        try Data("short".utf8).write(to: weight)
        let repair = IntegrityFetcher(manifest: manifest, payloads: payloads)

        await context.controller(fetcher: repair).performDownload(repoID: repoID, displayName: "Verified")

        XCTAssertEqual(repair.downloadedFiles(), ["model.safetensors"])
        XCTAssertEqual(try Data(contentsOf: weight), payloads["model.safetensors"])
    }

    @MainActor
    func testACR_MODEL_wrongDigestNeverRegistersAndCleansPartial() async throws {
        let context = try makeContext()
        let expected = validPayloads()
        var delivered = expected
        delivered["model.safetensors"] = Data(repeating: 0xEE, count: expected["model.safetensors"]!.count)
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: expected)

        let controller = context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: delivered))
        await controller.performDownload(repoID: repoID, displayName: "Bad")

        context.library.refresh()
        XCTAssertTrue(context.library.models.isEmpty)
        guard case .failed = controller.state else {
            return XCTFail("wrong digest must fail, got \(controller.state)")
        }
        let directory = context.modelDirectory(repoID: repoID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedModelStorage.manifestURL(in: directory).path))
        XCTAssertFalse(containsPartialFile(in: directory))
    }

    @MainActor
    func testACR_MODEL_fourByteConfigNeverRegisters() async throws {
        let context = try makeContext()
        let payloads = [
            "config.json": Data("{}  ".utf8),
            "model.safetensors": Data("valid-weights".utf8),
        ]
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let controller = context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))

        await controller.performDownload(repoID: repoID, displayName: "Tiny Config")

        guard case .failed = controller.state else { return XCTFail("four-byte config must fail") }
        context.library.refresh()
        XCTAssertTrue(context.library.models.isEmpty)
    }

    @MainActor
    func testACR_MODEL_missingRequiredFileNeverRegisters() async throws {
        let context = try makeContext()
        let payloads = ["model.safetensors": Data("weights".utf8)]
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let controller = context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))

        await controller.performDownload(repoID: repoID, displayName: "Missing Config")

        guard case .failed = controller.state else { return XCTFail("missing config must fail") }
        context.library.refresh()
        XCTAssertTrue(context.library.models.isEmpty)
    }

    @MainActor
    func testACR_MODEL_pathTraversalIsRejectedBeforeWrite() async throws {
        let context = try makeContext()
        let payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "../escape.safetensors": Data("escape".utf8),
        ]
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let controller = context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))

        await controller.performDownload(repoID: repoID, displayName: "Traversal")

        guard case .failed = controller.state else { return XCTFail("traversal must fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.modelsDirectory.appendingPathComponent("escape.safetensors").path))
    }

    @MainActor
    func testACR_MODEL_revisionChangeRedownloadsInsteadOfMixingArtifacts() async throws {
        let context = try makeContext()
        let payloads = validPayloads()
        let first = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        await context.controller(fetcher: IntegrityFetcher(manifest: first, payloads: payloads))
            .performDownload(repoID: repoID, displayName: "Revision A")

        let second = makeManifest(repoID: repoID, revision: revisionB, payloads: payloads)
        let refetch = IntegrityFetcher(manifest: second, payloads: payloads)
        await context.controller(fetcher: refetch).performDownload(repoID: repoID, displayName: "Revision B")

        XCTAssertEqual(Set(refetch.downloadedFiles()), Set(payloads.keys))
        XCTAssertEqual(
            try ManagedModelStorage.loadVerifiedManifest(at: context.modelDirectory(repoID: repoID)).revision,
            revisionB
        )
    }

    @MainActor
    func testACR_MODEL_cancelLeavesOnlyVerifiedResumeStateAndResumeSkipsGoodFiles() async throws {
        let payloads = validPayloads(includingTokenizer: true)
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let directory = tempDir().appendingPathComponent("model", isDirectory: true)
        let interrupted = IntegrityFetcher(
            manifest: manifest,
            payloads: payloads,
            failureFile: "tokenizer.json",
            failure: CancellationError()
        )

        do {
            try await ManagedModelDownloader.downloadFiles(
                manifest: manifest,
                destinationRoot: directory,
                fetcher: interrupted,
                maxConcurrent: 1
            ) { _, _, _ in }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedModelStorage.manifestURL(in: directory).path))
        XCTAssertFalse(containsPartialFile(in: directory))

        let resumed = IntegrityFetcher(manifest: manifest, payloads: payloads)
        try await ManagedModelDownloader.downloadFiles(
            manifest: manifest,
            destinationRoot: directory,
            fetcher: resumed,
            maxConcurrent: 1
        ) { _, _, _ in }

        XCTAssertEqual(resumed.downloadedFiles(), ["tokenizer.json"])
        XCTAssertEqual(try ManagedModelStorage.loadVerifiedManifest(at: directory), manifest)
    }

    @MainActor
    func testACR_MODEL_manifestTamperAndArtifactTamperBlockManagedLoad() async throws {
        let context = try makeContext()
        let payloads = validPayloads()
        let manifest = makeManifest(repoID: repoID, revision: revisionA, payloads: payloads)
        let controller = context.controller(fetcher: IntegrityFetcher(manifest: manifest, payloads: payloads))
        await controller.performDownload(repoID: repoID, displayName: "Verified")
        let model = try XCTUnwrap(context.library.models.first)
        let directory = context.modelDirectory(repoID: repoID)

        var tampered = manifest
        tampered.files[0].digest = String(repeating: "0", count: 64)
        try JSONEncoder().encode(tampered).write(to: ManagedModelStorage.manifestURL(in: directory))
        XCTAssertThrowsError(try ManagedModelStorage.loadVerifiedManifest(at: directory))

        await context.library.activateAndLoad(modelID: model.id)
        guard case let .failed(message) = context.library.loadState else {
            return XCTFail("tampered managed model must not load")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("verify") || message.localizedCaseInsensitiveContains("integrity"))
        XCTAssertTrue(context.runtime.loadRequests.isEmpty)
    }

    private func validPayloads(includingTokenizer: Bool = false) -> [String: Data] {
        var payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data(repeating: 0xA5, count: 128),
        ]
        if includingTokenizer { payloads["tokenizer.json"] = Data(#"{"version":"1"}"#.utf8) }
        return payloads
    }

    @MainActor
    private func makeContext() throws -> ModelIntegrityContext {
        let modelsDirectory = tempDir()
        let storeDirectory = tempDir()
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = try SupraStore(url: storeDirectory.appendingPathComponent("test.sqlite"))
        let runtime = StubRuntimeClient()
        let library = ModelLibrary(
            store: store,
            runtimeClient: runtime,
            managedModelRoots: [modelsDirectory]
        )
        return ModelIntegrityContext(
            store: store,
            library: library,
            runtime: runtime,
            modelsDirectory: modelsDirectory
        )
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ACR-Model-\(UUID().uuidString)", isDirectory: true)
    }

    private func containsPartialFile(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.compactMap { $0 as? URL }.contains { $0.lastPathComponent.contains(".partial") }
    }
}

@MainActor
private final class ModelIntegrityContext {
    let store: SupraStore
    let library: ModelLibrary
    let runtime: StubRuntimeClient
    let modelsDirectory: URL

    init(store: SupraStore, library: ModelLibrary, runtime: StubRuntimeClient, modelsDirectory: URL) {
        self.store = store
        self.library = library
        self.runtime = runtime
        self.modelsDirectory = modelsDirectory
    }

    func controller(fetcher: ModelRepositoryFetching) -> ModelDownloadController {
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: fetcher,
            modelsDirectory: modelsDirectory
        )
        return controller
    }

    func modelDirectory(repoID: String) -> URL {
        modelsDirectory.appendingPathComponent(ManagedModelStorage.folderName(forRepoID: repoID), isDirectory: true)
    }
}

private final class IntegrityFetcher: ModelRepositoryFetching, @unchecked Sendable {
    let manifest: ModelArtifactManifest
    private let payloads: [String: Data]
    private let failureFile: String?
    private let failure: Error?
    private let lock = NSLock()
    private var downloads: [String] = []
    private var revisions: [String] = []

    init(
        manifest: ModelArtifactManifest,
        payloads: [String: Data],
        failureFile: String? = nil,
        failure: Error? = nil
    ) {
        self.manifest = manifest
        self.payloads = payloads
        self.failureFile = failureFile
        self.failure = failure
    }

    func fetchManifest(repoID: String) async throws -> ModelArtifactManifest { manifest }

    func downloadFile(
        repoID: String,
        revision: String,
        artifact: ModelArtifactManifest.File,
        to destination: URL
    ) async throws {
        lock.withLock {
            downloads.append(artifact.relativePath)
            revisions.append(revision)
        }
        if artifact.relativePath == failureFile, let failure { throw failure }
        let data = try payloads[artifact.relativePath].orThrow(TestFetcherError.missingPayload(artifact.relativePath))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    func fetchConfigJSON(repoID: String, revision: String) async throws -> Data? {
        payloads["config.json"]
    }

    func downloadedFiles() -> [String] { lock.withLock { downloads } }
    func requestedRevisions() -> [String] { lock.withLock { revisions } }
}

private enum TestFetcherError: Error {
    case missingPayload(String)
}

private func makeManifest(
    repoID: String,
    revision: String,
    payloads: [String: Data]
) -> ModelArtifactManifest {
    ModelArtifactManifest(
        repositoryID: repoID,
        revision: revision,
        files: payloads.map { path, data in
            ModelArtifactManifest.File(
                relativePath: path,
                size: Int64(data.count),
                digestAlgorithm: .sha256,
                digest: ModelArtifactIntegrity.sha256Hex(data)
            )
        }
    )
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
