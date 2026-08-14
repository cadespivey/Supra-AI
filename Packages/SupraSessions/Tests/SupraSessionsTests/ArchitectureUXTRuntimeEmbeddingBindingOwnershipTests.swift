import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// T-RUNTIME-BIND-02
///
/// Expected RED: the runtime permit can now require exact embedding artifact
/// identity, but the two shipping managed-embedding producers still construct
/// `LoadEmbeddingModelRequest` without a content binding.
@MainActor
final class ArchitectureUXTRuntimeEmbeddingBindingOwnershipTests: XCTestCase {
    private static let modelID = "00000000-0000-0000-0000-000000000713"
    private static let repositoryID = "synthetic/embedding-model-wire-713"
    private static let revision = String(repeating: "7", count: 40)
    private static let forbiddenDefault = "DEFAULT-000"

    func testRuntimeTextEmbedderLoadsTheExactManagedArtifactBinding() async throws {
        let fixture = try makeFixture(suffix: "indexing")
        let runtime = EmbeddingBindingRuntimeRecorder(dimension: 7)
        let embedder = try XCTUnwrap(RuntimeTextEmbedder(
            model: fixture.model,
            runtimeClient: runtime,
            batchSize: 7
        ))

        let vectors = try await embedder.embed(["T_RUNTIME_BIND_02_WIRE_731"])

        XCTAssertEqual(vectors.count, 1)
        let request = try XCTUnwrap(runtime.embeddingLoadRequests.only)
        assertExactBinding(request.contentBinding, fixture: fixture)
        XCTAssertFalse(
            String(describing: request.contentBinding).contains(Self.forbiddenDefault)
        )
    }

    func testSetupVerificationAndPrewarmLoadTheExactManagedArtifactBinding() async throws {
        let fixture = try makeFixture(suffix: "setup")
        let store = try SupraStore(url: fixture.base.appendingPathComponent("test.sqlite"))
        try store.documentSettings.upsertEmbeddingModel(fixture.model)
        try store.documentSettings.selectEmbeddingModel(id: fixture.model.id)
        let runtime = EmbeddingBindingRuntimeRecorder(dimension: 7)
        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: runtime,
            notifier: EmbeddingBindingNotifier()
        )

        await controller.testLoadEmbeddingModel()
        XCTAssertTrue(controller.embeddingTestPassed)
        let verification = try XCTUnwrap(runtime.embeddingLoadRequests.first)
        assertExactBinding(verification.contentBinding, fixture: fixture)

        controller.prewarmEmbeddingModel()
        for _ in 0..<100 where runtime.embeddingLoadRequests.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(runtime.embeddingLoadRequests.count, 2)
        let prewarm = try XCTUnwrap(runtime.embeddingLoadRequests.last)
        assertExactBinding(prewarm.contentBinding, fixture: fixture)
        XCTAssertFalse(
            String(describing: runtime.embeddingLoadRequests).contains(Self.forbiddenDefault)
        )
    }

    private func assertExactBinding(
        _ binding: RuntimeModelContentBinding?,
        fixture: EmbeddingBindingFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(binding?.repositoryID, Self.repositoryID, file: file, line: line)
        XCTAssertEqual(binding?.revision, Self.revision, file: file, line: line)
        XCTAssertEqual(
            binding?.fingerprintSHA256,
            fixture.expectedFingerprintSHA256,
            file: file,
            line: line
        )
        XCTAssertEqual(
            binding?.files.map(\.path),
            ["config.json", "model.safetensors"],
            file: file,
            line: line
        )
    }

    private func makeFixture(suffix: String) throws -> EmbeddingBindingFixture {
        let base = ManagedModelStorage.embeddingModelsDirectory()
            .appendingPathComponent(
                "ArchitectureUXTRuntimeEmbeddingBinding-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let payloads: [String: Data] = [
            "config.json": Data(#"{"model_type":"synthetic-embedding-wire-713"}"#.utf8),
            "model.safetensors": Data("T_RUNTIME_BIND_02_WEIGHT_WIRE_739".utf8),
        ]
        for (relativePath, data) in payloads {
            try data.write(to: base.appendingPathComponent(relativePath))
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
            to: ManagedModelStorage.manifestURL(in: base)
        )
        let expectedBinding = try SignedReleaseModelAuthorization.inspectContentBinding(
            modelDirectory: base,
            managedRoot: ManagedModelStorage.embeddingModelsDirectory()
        )
        let model = DocumentEmbeddingModelRecord(
            id: Self.modelID,
            repoID: Self.repositoryID,
            localPath: base.path,
            displayName: "Embedding model wire 713",
            dimension: 7,
            runtimeFamily: "synthetic",
            revision: Self.revision
        )
        return EmbeddingBindingFixture(
            base: base,
            model: model,
            expectedFingerprintSHA256: expectedBinding.fingerprintSHA256
        )
    }
}

private struct EmbeddingBindingFixture {
    let base: URL
    let model: DocumentEmbeddingModelRecord
    let expectedFingerprintSHA256: String
}

private final class EmbeddingBindingRuntimeRecorder: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let dimension: Int
    private var recordedEmbeddingLoadRequests: [LoadEmbeddingModelRequest] = []

    init(dimension: Int) {
        self.dimension = dimension
    }

    var embeddingLoadRequests: [LoadEmbeddingModelRequest] {
        lock.withLock { recordedEmbeddingLoadRequests }
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] { [] }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: nil,
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}

    func loadEmbeddingModel(
        _ request: LoadEmbeddingModelRequest
    ) async throws -> LoadEmbeddingModelResponse {
        lock.withLock { recordedEmbeddingLoadRequests.append(request) }
        return LoadEmbeddingModelResponse(
            state: .loaded,
            embeddingModelID: request.embeddingModelID,
            dimension: dimension,
            loadTimeMs: 7
        )
    }

    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(
            state: .loaded,
            vectors: request.texts.map { _ in
                [Float](repeating: 0, count: max(0, dimension - 1)) + [1]
            },
            dimension: dimension
        )
    }

    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .loaded, dimension: dimension)
    }
}

private struct EmbeddingBindingNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
