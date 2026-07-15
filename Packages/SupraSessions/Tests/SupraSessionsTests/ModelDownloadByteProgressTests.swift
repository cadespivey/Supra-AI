import Combine
import Foundation
import SupraRuntimeClient
@testable import SupraSessions
import SupraStore
import XCTest

/// Gating tests for byte-accurate download progress surfacing through both
/// download controllers (Models module: fill-by-percentage bar + MB/s + cancel).
///
/// EXPECTED RED (pre-implementation): the `.downloading` case does not yet carry
/// a `ModelDownloadProgress`, and `ModelRepositoryFetching.downloadFile` has no
/// byte-progress callback, so this suite fails to build — that compile failure
/// is the observable RED state for the not-yet-existing API surface.
final class ModelDownloadByteProgressTests: XCTestCase {

    // MARK: - Text-model controller

    @MainActor
    func testDownloadingStateCarriesByteProgress() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let fetcher = ByteReportingFetcher(files: [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data(repeating: 0x5A, count: 600),
            "tokenizer.json": Data(repeating: 0x21, count: 200),
        ])
        let controller = ModelDownloadController(
            store: store, modelLibrary: library, fetcher: fetcher, modelsDirectory: tempDir()
        )

        var snapshots: [ModelDownloadProgress] = []
        let sink = controller.$state.sink { state in
            if case let .downloading(_, progress) = state { snapshots.append(progress) }
        }
        defer { sink.cancel() }

        await controller.performDownload(repoID: "mlx-community/Bytes-4bit", displayName: "Bytes")

        guard case .finished = controller.state else {
            return XCTFail("Expected finished, got \(controller.state)")
        }
        XCTAssertFalse(snapshots.isEmpty, "no .downloading states were published")

        let expectedTotal = fetcher.totalPayloadBytes
        for snapshot in snapshots {
            XCTAssertEqual(
                snapshot.totalBytes, expectedTotal,
                "every downloading state must carry the manifest's total byte size"
            )
            XCTAssertGreaterThanOrEqual(snapshot.bytesReceived, 0)
            XCTAssertLessThanOrEqual(snapshot.bytesReceived, expectedTotal)
        }
        // Monotonic fill: the bar never moves backwards during a clean download.
        let received = snapshots.map(\.bytesReceived)
        XCTAssertEqual(received, received.sorted(), "bytesReceived must be nondecreasing")
        // Sub-file granularity: the fetcher reports a half-file checkpoint and
        // waits for it to be observed, so some state must land strictly between
        // empty and full — a file-count-only implementation cannot produce it.
        XCTAssertTrue(
            snapshots.contains { $0.bytesReceived > 0 && $0.bytesReceived < expectedTotal },
            "expected at least one partial byte snapshot, got \(received)"
        )
        // The last downloading state accounts for every byte.
        XCTAssertEqual(snapshots.last?.bytesReceived, expectedTotal)
        XCTAssertEqual(snapshots.last?.completedFiles, 3)
        XCTAssertEqual(snapshots.last?.totalFiles, 3)
    }

    @MainActor
    func testResumeCountsPreexistingVerifiedBytesInFirstEmission() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let modelsDir = tempDir()
        let repo = "mlx-community/Resume-4bit"
        let configPayload = Data(#"{"model_type":"qwen2"}"#.utf8)
        let weights = Data(repeating: 0x5A, count: 400)
        let fetcher = ByteReportingFetcher(files: [
            "config.json": configPayload,
            "model.safetensors": weights,
        ])

        // Simulate an interrupted earlier run: the download-state manifest is in
        // place and config.json is already fully downloaded and verified.
        let manifest = try await fetcher.fetchManifest(repoID: repo)
        let root = modelsDir.appendingPathComponent(
            ManagedModelStorage.folderName(forRepoID: repo), isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ManagedModelStorage.writeManifest(
            manifest.canonicalized(),
            to: ManagedModelStorage.downloadStateURL(in: root)
        )
        try configPayload.write(to: root.appendingPathComponent("config.json"))

        let controller = ModelDownloadController(
            store: store, modelLibrary: library, fetcher: fetcher, modelsDirectory: modelsDir
        )
        var snapshots: [ModelDownloadProgress] = []
        let sink = controller.$state.sink { state in
            if case let .downloading(_, progress) = state { snapshots.append(progress) }
        }
        defer { sink.cancel() }

        await controller.performDownload(repoID: repo, displayName: "Resume")

        guard case .finished = controller.state else {
            return XCTFail("Expected finished, got \(controller.state)")
        }
        let first = try XCTUnwrap(snapshots.first)
        XCTAssertGreaterThanOrEqual(
            first.bytesReceived, Int64(configPayload.count),
            "resumed downloads must start the bar at the already-verified bytes, not zero"
        )
        XCTAssertEqual(first.totalBytes, Int64(configPayload.count + weights.count))
    }

    /// Safety net for the new Cancel affordances: locks in the engine behavior
    /// they invoke (task cancellation → state resets to .idle). This test is
    /// expected to pass as soon as the suite compiles — the RED here is the
    /// suite-level compile failure, not this assertion.
    @MainActor
    func testCancelMidDownloadReturnsToIdle() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let fetcher = GatedFetcher(files: [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data(repeating: 0x5A, count: 500),
        ])
        let controller = ModelDownloadController(
            store: store, modelLibrary: library, fetcher: fetcher, modelsDirectory: tempDir()
        )

        controller.download(repoID: "mlx-community/Cancel-4bit", displayName: "Cancel")
        try await poll(timeout: 5, message: "download never became busy") { controller.isBusy }

        controller.cancel()
        try await poll(timeout: 5, message: "cancel did not settle back to idle") {
            if case .idle = controller.state { return true }
            return false
        }
        XCTAssertFalse(controller.isBusy)
    }

    // MARK: - Embedding controller

    @MainActor
    func testEmbeddingDownloadingStateCarriesByteProgress() async throws {
        let store = try makeStore()
        let fetcher = ByteReportingFetcher(files: [
            "config.json": Data(#"{"model_type":"bert"}"#.utf8),
            "model.safetensors": Data(repeating: 0x5A, count: 300),
        ])
        let controller = EmbeddingModelDownloadController(
            store: store, fetcher: fetcher, modelsDirectory: tempDir()
        )
        var snapshots: [ModelDownloadProgress] = []
        let sink = controller.$state.sink { state in
            if case let .downloading(_, progress) = state { snapshots.append(progress) }
        }
        defer { sink.cancel() }

        await controller.performDownload(
            repoID: "mlx-community/Embed-Test",
            displayName: "Embed",
            dimension: 384,
            runtimeFamily: "bert",
            selectAfterDownload: false
        )

        guard case .finished = controller.state else {
            return XCTFail("Expected finished, got \(controller.state)")
        }
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertEqual(snapshots.last?.bytesReceived, fetcher.totalPayloadBytes)
        XCTAssertEqual(snapshots.last?.totalBytes, fetcher.totalPayloadBytes)
        XCTAssertTrue(
            snapshots.contains { $0.bytesReceived > 0 && $0.bytesReceived < fetcher.totalPayloadBytes },
            "embedding downloads must surface sub-file byte progress too"
        )
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteProgressTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = tempDir()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    @MainActor
    private func poll(
        timeout: TimeInterval,
        message: @autoclosure () -> String,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail(message()) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Serves fixed payloads and reports a HALF-file byte checkpoint through the
/// async progress callback before completing each file, awaiting the callback so
/// the partial snapshot is deterministically observable by the controller.
private final class ByteReportingFetcher: ModelRepositoryFetching, @unchecked Sendable {
    private let files: [String: Data]
    private let revision = String(repeating: "a", count: 40)

    init(files: [String: Data]) { self.files = files }

    var totalPayloadBytes: Int64 {
        files.values.reduce(0) { $0 + Int64($1.count) }
    }

    func fetchManifest(repoID: String) async throws -> ModelArtifactManifest {
        ModelArtifactManifest(
            repositoryID: repoID,
            revision: revision,
            files: files.map { name, payload in
                ModelArtifactManifest.File(
                    relativePath: name,
                    size: Int64(payload.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(payload)
                )
            }
        )
    }

    func downloadFile(
        repoID: String,
        revision: String,
        artifact: ModelArtifactManifest.File,
        to destination: URL,
        onBytes: (@Sendable (Int64) async -> Void)?
    ) async throws {
        guard let payload = files[artifact.relativePath] else {
            throw HuggingFaceError.requestFailed(artifact.relativePath, 404)
        }
        await onBytes?(Int64(payload.count / 2))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destination)
        await onBytes?(Int64(payload.count))
    }

    func fetchConfigJSON(repoID: String, revision: String) async throws -> Data? {
        files["config.json"]
    }
}

/// Blocks inside downloadFile until the surrounding task is cancelled, so tests
/// can cancel a genuinely in-flight transfer.
private final class GatedFetcher: ModelRepositoryFetching, @unchecked Sendable {
    private let files: [String: Data]
    private let revision = String(repeating: "a", count: 40)

    init(files: [String: Data]) { self.files = files }

    func fetchManifest(repoID: String) async throws -> ModelArtifactManifest {
        ModelArtifactManifest(
            repositoryID: repoID,
            revision: revision,
            files: files.map { name, payload in
                ModelArtifactManifest.File(
                    relativePath: name,
                    size: Int64(payload.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(payload)
                )
            }
        )
    }

    func downloadFile(
        repoID: String,
        revision: String,
        artifact: ModelArtifactManifest.File,
        to destination: URL,
        onBytes: (@Sendable (Int64) async -> Void)?
    ) async throws {
        // Never completes on its own; Task.sleep throws when the download task
        // tree is cancelled, which is exactly the path a user cancel takes.
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }

    func fetchConfigJSON(repoID: String, revision: String) async throws -> Data? {
        files["config.json"]
    }
}
