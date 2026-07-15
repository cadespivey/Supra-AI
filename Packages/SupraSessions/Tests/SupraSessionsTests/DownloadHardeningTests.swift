import Combine
import Foundation
import SupraRuntimeClient
@testable import SupraSessions
import SupraStore
import XCTest

/// Gating tests for two defects found by adversarial review of the byte-progress
/// feature (branch feat/model-download-ux):
///
/// 1. A byte report bridged through an unstructured Task can land AFTER the
///    download was cancelled/failed and overwrite the settled state with
///    .downloading — wedging the controller (isBusy forever: cancel() is a
///    no-op on the finished task, dismissResult() no-ops mid-download, and
///    download() is blocked by the isBusy guard). EXPECTED RED (runtime): the
///    straggler currently reaches the aggregator (the file never completed, so
///    the finished-files guard passes) and resurrects .downloading.
///
/// 2. A mid-transfer network stall freezes the MB/s label at the last healthy
///    rate: speed samples are only recorded on byte-advancing emissions, so
///    DownloadRateTracker's decay-to-zero contract is unreachable in
///    production. EXPECTED RED (compile): the injectable clock and the
///    recordSpeedSample() tick seam do not exist yet.
final class DownloadHardeningTests: XCTestCase {

    @MainActor
    func testLateByteReportCannotResurrectSettledState() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let fetcher = StragglerFetcher(
            instantFiles: ["config.json": Data(#"{"model_type":"qwen2"}"#.utf8)],
            gatedFile: ("model.safetensors", Data(repeating: 0x5A, count: 400))
        )
        let controller = ModelDownloadController(
            store: store, modelLibrary: library, fetcher: fetcher, modelsDirectory: tempDir()
        )

        controller.download(repoID: "mlx-community/Straggler-4bit", displayName: "Straggler")
        // Wait until the gated file's transfer is genuinely in flight (its
        // onBytes callback has been captured), then cancel.
        try await poll(timeout: 5, message: "gated transfer never started") {
            fetcher.capturedOnBytes() != nil
        }
        controller.cancel()
        try await poll(timeout: 5, message: "cancel did not settle to idle") {
            if case .idle = controller.state { return true }
            return false
        }

        // The bridged byte report for the never-completed file arrives late —
        // exactly what HuggingFaceClient's unstructured Task bridging produces
        // after a cancel. It must not resurrect .downloading.
        let straggler = try XCTUnwrap(fetcher.capturedOnBytes())
        await straggler(123)
        await Task.yield()

        guard case .idle = controller.state else {
            return XCTFail("late byte report resurrected state: \(controller.state)")
        }
        XCTAssertFalse(controller.isBusy, "controller wedged busy by a straggler byte report")
    }

    @MainActor
    func testStalledDownloadSpeedDecaysToZeroInPublishedState() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let fetcher = StragglerFetcher(
            instantFiles: ["config.json": Data(#"{"model_type":"qwen2"}"#.utf8)],
            gatedFile: ("model.safetensors", Data(repeating: 0x5A, count: 400)),
            reportPartialBytesBeforeGating: 100
        )
        var fakeNow: TimeInterval = 1_000
        let controller = ModelDownloadController(
            store: store, modelLibrary: library, fetcher: fetcher, modelsDirectory: tempDir(),
            now: { fakeNow }
        )

        controller.download(repoID: "mlx-community/Stall-4bit", displayName: "Stall")
        // Wait for the partial-bytes emission, recorded at t=1000.
        try await poll(timeout: 5, message: "never saw a partial byte snapshot") {
            if case let .downloading(_, p) = controller.state { return p.bytesReceived > 0 }
            return false
        }

        // The transfer now stalls (the fetcher is gated; no further bytes).
        // Once the tracker's window has passed with no byte movement, ticks
        // must drive the PUBLISHED speed to 0 — not leave it stale/nil forever
        // — which is what the 1s speed ticker does in production. (Within the
        // window a positive rate is correct: that's the locked windowed-average
        // contract, so this asserts only the post-window steady state.)
        for tick in 1...6 {
            fakeNow = 1_000 + TimeInterval(tick)
            controller.recordSpeedSample()
        }
        guard case let .downloading(_, progress) = controller.state else {
            return XCTFail("expected downloading, got \(controller.state)")
        }
        XCTAssertEqual(
            try XCTUnwrap(progress.bytesPerSecond), 0, accuracy: 0.001,
            "a stalled download must publish 0 B/s, not a stale or missing rate"
        )

        controller.cancel()
        try await poll(timeout: 5, message: "cleanup cancel did not settle") {
            if case .idle = controller.state { return true }
            return false
        }
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HardeningTests-\(UUID().uuidString)", isDirectory: true)
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

/// Instant files download immediately; the gated file captures its onBytes
/// callback (optionally reporting some partial bytes first) and then blocks
/// until task cancellation — letting tests replay a late byte report after the
/// download has settled, and freeze a transfer to simulate a stall.
private final class StragglerFetcher: ModelRepositoryFetching, @unchecked Sendable {
    private let instantFiles: [String: Data]
    private let gatedFile: (name: String, payload: Data)
    private let partialBytes: Int64?
    private let lock = NSLock()
    private var onBytesForGatedFile: (@Sendable (Int64) async -> Void)?
    private let revision = String(repeating: "a", count: 40)

    init(
        instantFiles: [String: Data],
        gatedFile: (String, Data),
        reportPartialBytesBeforeGating: Int64? = nil
    ) {
        self.instantFiles = instantFiles
        self.gatedFile = (gatedFile.0, gatedFile.1)
        self.partialBytes = reportPartialBytesBeforeGating
    }

    func capturedOnBytes() -> (@Sendable (Int64) async -> Void)? {
        lock.withLock { onBytesForGatedFile }
    }

    private var allFiles: [String: Data] {
        var files = instantFiles
        files[gatedFile.name] = gatedFile.payload
        return files
    }

    func fetchManifest(repoID: String) async throws -> ModelArtifactManifest {
        ModelArtifactManifest(
            repositoryID: repoID,
            revision: revision,
            files: allFiles.map { name, payload in
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
        if artifact.relativePath == gatedFile.name {
            lock.withLock { onBytesForGatedFile = onBytes }
            if let partialBytes { await onBytes?(partialBytes) }
            try await Task.sleep(nanoseconds: 600_000_000_000)
            return
        }
        guard let payload = instantFiles[artifact.relativePath] else {
            throw HuggingFaceError.requestFailed(artifact.relativePath, 404)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destination)
        await onBytes?(Int64(payload.count))
    }

    func fetchConfigJSON(repoID: String, revision: String) async throws -> Data? {
        instantFiles["config.json"]
    }
}
