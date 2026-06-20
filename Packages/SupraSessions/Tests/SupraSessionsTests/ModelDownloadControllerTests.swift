import Foundation
import SupraCore
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

    @MainActor
    func testUnsupportedModelTypeRejectedBeforeDownloadingWeights() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let modelsDir = tempDir()
        // A vision model_type the runtime registry does not contain.
        let vlmConfig = Data(#"{"architectures":["LlavaForConditionalGeneration"],"model_type":"llava"}"#.utf8)
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: StubFetcher(files: ["config.json", "model.safetensors"], configJSON: vlmConfig),
            modelsDirectory: modelsDir
        )

        await controller.performDownload(repoID: "some-org/Llava-7B-4bit", displayName: "VLM")

        guard case let .failed(message) = controller.state else {
            return XCTFail("Expected failed, got \(controller.state)")
        }
        XCTAssertTrue(message.contains("llava"))
        library.refresh()
        XCTAssertTrue(library.models.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: modelsDir.appendingPathComponent("some-org__Llava-7B-4bit").path
            ),
            "no weights should be downloaded for an unsupported model"
        )
    }

    @MainActor
    func testSupportedModelTypeIsAllowed() async throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        let config = Data(#"{"architectures":["Qwen2ForCausalLM"],"model_type":"qwen2"}"#.utf8)
        let controller = ModelDownloadController(
            store: store,
            modelLibrary: library,
            fetcher: StubFetcher(files: ["config.json"], configJSON: config),
            modelsDirectory: tempDir()
        )

        await controller.performDownload(repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "OK")

        guard case .finished = controller.state else {
            return XCTFail("Expected finished, got \(controller.state)")
        }
        library.refresh()
        XCTAssertEqual(library.models.count, 1)
    }

    func testModelCompatibilityGatesOnModelType() {
        // The runtime registers these, so they must not be blocked (incl. the
        // multimodal-named qwen3_5_moe, whose architecture is *ForConditionalGeneration).
        for json in [
            #"{"model_type":"qwen3_5_moe"}"#,
            #"{"model_type":"qwen2"}"#,
            #"{"model_type":"gemma3n","architectures":["Gemma3nForConditionalGeneration"]}"#
        ] {
            XCTAssertNil(ModelCompatibility.unsupportedReason(configJSON: Data(json.utf8)), json)
        }
        // Unregistered model_types are blocked even when named *ForCausalLM.
        for json in [
            #"{"architectures":["MixtralForCausalLM"],"model_type":"mixtral"}"#,
            #"{"model_type":"llava"}"#
        ] {
            XCTAssertNotNil(ModelCompatibility.unsupportedReason(configJSON: Data(json.utf8)), json)
        }
        // No model_type → don't block (let the runtime decide).
        XCTAssertNil(ModelCompatibility.unsupportedReason(configJSON: Data(#"{}"#.utf8)))
    }

    func testManagedStorageHelpers() {
        let dir = ManagedModelStorage.modelsDirectory()
        XCTAssertEqual(ManagedModelStorage.folderName(forRepoID: "mlx-community/Qwen2.5-32B-Instruct-4bit"), "mlx-community__Qwen2.5-32B-Instruct-4bit")
        XCTAssertTrue(ManagedModelStorage.isManaged(path: dir.appendingPathComponent("foo").path))
        XCTAssertFalse(ManagedModelStorage.isManaged(path: "/tmp/somewhere-else"))
    }

    @MainActor
    func testPlanRoleModelsAreInCatalogAndAutoResolveToTheirRoles() throws {
        // The three downloadable role models from the local-legal-model-setup plan.
        let planRepos: [ModelRole: String] = [
            .legalReasoning: "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit",
            .drafting: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            .critique: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
        ]

        // (1) Downloadable: each is offered in the guided-download catalog.
        let catalogRepos = Set(ModelCatalog.curated.map(\.repoID))
        for repo in planRepos.values {
            XCTAssertTrue(catalogRepos.contains(repo), "ModelCatalog is missing \(repo)")
        }

        // (2) Assignable: once registered, each repo resolves to its intended chat
        // route via the configured (plan-default) identifier — no manual assignment.
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        for repo in planRepos.values {
            let folder = ManagedModelStorage.folderName(forRepoID: repo)
            _ = try library.addModel(displayName: repo, path: "/models/\(folder)", bookmarkData: nil)
        }
        library.refresh()

        for (role, repo) in planRepos {
            XCTAssertEqual(
                library.resolvedModel(for: role)?.path,
                "/models/\(ManagedModelStorage.folderName(forRepoID: repo))",
                "role \(role.rawValue) did not resolve to \(repo)"
            )
        }

        // The plan's 6-bit high-quality model isn't published by mlx-community, so the
        // HQ route has no auto-resolved model until one is assigned manually.
        XCTAssertNil(library.resolvedModel(for: .legalReasoningHighQuality))
    }

    @MainActor
    func testRecommendedModelPicksBestRegisteredModelPerRole() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        // Neither is a plan default, so recommendation falls to the trait heuristic.
        _ = try library.addModel(displayName: "Llama 3.1 8B Instruct (4-bit)", path: "/m/llama-instruct", bookmarkData: nil)
        _ = try library.addModel(displayName: "DeepSeek-R1 Distill Qwen 7B (4-bit)", path: "/m/deepseek-r1", bookmarkData: nil)
        library.refresh()

        // Reasoning/critique routes prefer the reasoning model; drafting prefers instruct.
        XCTAssertEqual(library.recommendedModel(for: .legalReasoning)?.path, "/m/deepseek-r1")
        XCTAssertEqual(library.recommendedModel(for: .legalReasoningHighQuality)?.path, "/m/deepseek-r1")
        XCTAssertEqual(library.recommendedModel(for: .critique)?.path, "/m/deepseek-r1")
        XCTAssertEqual(library.recommendedModel(for: .drafting)?.path, "/m/llama-instruct")

        // The exact plan model wins over the heuristic when it is registered.
        _ = try library.addModel(
            displayName: "Qwen3 30B A3B Thinking 2507 (4-bit)",
            path: "/m/\(ManagedModelStorage.folderName(forRepoID: "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit"))",
            bookmarkData: nil
        )
        library.refresh()
        XCTAssertTrue(library.recommendedModel(for: .legalReasoning)?.path.contains("Thinking-2507-4bit") ?? false)

        // No models → no recommendation.
        let empty = ModelLibrary(store: try makeStore(), runtimeClient: StubRuntimeClient())
        XCTAssertNil(empty.recommendedModel(for: .legalReasoning))
    }

    @MainActor
    func testRecommendedHighQualityReasoningIsDeterministicLargestModel() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        // Both fit the high-quality reasoning route — its 6-bit plan default isn't
        // published, so neither matches it and the choice falls to the heuristic.
        // The recommendation must be deterministic (the larger 32B model), not flip
        // with `fetchModels()` ordering.
        _ = try library.addModel(displayName: "Qwen3 30B A3B Thinking 2507 (4-bit)", path: "/m/Qwen3-30B-A3B-Thinking-2507-4bit", bookmarkData: nil)
        _ = try library.addModel(displayName: "DeepSeek-R1 Distill Qwen 32B (4-bit)", path: "/m/DeepSeek-R1-Distill-Qwen-32B-4bit", bookmarkData: nil)
        library.refresh()

        let first = library.recommendedModel(for: .legalReasoningHighQuality)?.path
        let second = library.recommendedModel(for: .legalReasoningHighQuality)?.path
        XCTAssertEqual(first, "/m/DeepSeek-R1-Distill-Qwen-32B-4bit")
        XCTAssertEqual(first, second)
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
    private let configJSON: Data?

    init(files: [String], listError: Error? = nil, configJSON: Data? = nil) {
        self.files = files
        self.listError = listError
        self.configJSON = configJSON
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

    func fetchConfigJSON(repoID: String) async throws -> Data? {
        configJSON
    }
}
