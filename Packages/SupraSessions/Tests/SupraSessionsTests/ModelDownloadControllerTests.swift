import Foundation
import SupraRuntimeClient
@testable import SupraSessions
import SupraStore
import XCTest

final class ModelDownloadControllerTests: XCTestCase {

    @MainActor
    func testDownloadWritesFilesAndRegistersManagedModel() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let modelsDir = tempDir()
        let fetcher = StubFetcher(files: ["config.json", "model.safetensors", "tokenizer.json"])
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: fetcher,
            modelsDirectory: modelsDir
        )

        await controller.performDownload(repoID: "mlx-community/Test-4bit", displayName: "Test Model")

        guard case let .finished(repoID, name) = controller.state else {
            return XCTFail("Expected finished, got \(controller.state)")
        }
        XCTAssertEqual(repoID, "mlx-community/Test-4bit")
        XCTAssertEqual(name, "Test Model")

        library.refresh()
        XCTAssertEqual(library.models.count, 1)
        let model = try XCTUnwrap(library.models.first)
        XCTAssertEqual(model.displayName, "Test Model")

        let modelDir = modelsDir.appendingPathComponent("mlx-community__Test-4bit", isDirectory: true)
        XCTAssertEqual(model.path, modelDir.path)
        for file in ["config.json", "model.safetensors", "tokenizer.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(file).path),
                "missing \(file)"
            )
        }
    }

    @MainActor
    func testListFailureSurfacesErrorAndRegistersNothing() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let fetcher = StubFetcher(files: [], listError: HuggingFaceError.emptyRepository("bad/repo"))
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: fetcher,
            modelsDirectory: tempDir()
        )

        await controller.performDownload(repoID: "bad/repo", displayName: nil)

        guard case .failed = controller.state else {
            return XCTFail("Expected failed, got \(controller.state)")
        }
        XCTAssertTrue(library.models.isEmpty)
    }

    @MainActor
    func testDownloadingSameRepoTwiceDoesNotDuplicate() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let modelsDir = tempDir()
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: StubFetcher(files: ["config.json"]),
            modelsDirectory: modelsDir
        )

        await controller.performDownload(repoID: "mlx-community/Test-4bit", displayName: "Test")
        await controller.performDownload(repoID: "mlx-community/Test-4bit", displayName: "Test")

        library.refresh()
        XCTAssertEqual(library.models.count, 1)
    }

    func testManagedStorageHelpers() {
        let dir = ManagedModelStorage.modelsDirectory()
        XCTAssertEqual(ManagedModelStorage.folderName(forRepoID: "mlx-community/Qwen2.5-32B-Instruct-4bit"), "mlx-community__Qwen2.5-32B-Instruct-4bit")
        XCTAssertTrue(ManagedModelStorage.isManaged(path: dir.appendingPathComponent("foo").path))
        XCTAssertFalse(ManagedModelStorage.isManaged(path: "/tmp/somewhere-else"))
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = tempDir()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private final class StubFetcher: ModelRepositoryFetching, @unchecked Sendable {
    private let files: [String]
    private let listError: Error?

    init(files: [String], listError: Error? = nil) {
        self.files = files
        self.listError = listError
    }

    func listModelFiles(repoID: String) async throws -> [String] {
        if let listError { throw listError }
        return files
    }

    func downloadFile(repoID: String, file: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub-\(file)".utf8).write(to: destination)
    }
}
