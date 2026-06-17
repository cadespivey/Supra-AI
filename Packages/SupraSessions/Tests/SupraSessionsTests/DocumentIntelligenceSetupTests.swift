import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentIntelligenceSetupTests: XCTestCase {

    func testSetupGatingBlocksThenCompletesWhenAllStepsPass() async throws {
        let store = try makeStore()
        // A downloaded, selected embedding model is already registered.
        let model = DocumentEmbeddingModelRecord(
            repoID: "BAAI/bge-base-en-v1.5",
            localPath: "/tmp/embedder",
            displayName: "BGE Base",
            dimension: 768,
            runtimeFamily: "bert",
            isDefault: true
        )
        try store.documentSettings.upsertEmbeddingModel(model)
        try store.documentSettings.selectEmbeddingModel(id: model.id)

        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupTests-\(UUID().uuidString)", isDirectory: true))
        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 768),
            notifier: FakeNotifier(status: .authorized),
            storage: storage,
            capabilitiesProvider: { capableToolchain }
        )

        // Import is blocked before setup is complete.
        XCTAssertFalse(controller.isReadyForImport)
        XCTAssertFalse(controller.canCompleteSetup)

        controller.initializeStorage()
        controller.refreshToolchain()
        await controller.refreshChatModelStatus()
        await controller.testLoadEmbeddingModel()
        await controller.requestNotificationPermission()

        XCTAssertTrue(controller.chatModelLoaded)
        XCTAssertTrue(controller.embeddingTestPassed)
        XCTAssertTrue(controller.storageInitialized)
        XCTAssertTrue(controller.canCompleteSetup, "outstanding: \(controller.outstandingSteps)")

        XCTAssertTrue(controller.completeSetup())
        XCTAssertTrue(controller.isComplete)
        XCTAssertTrue(controller.isReadyForImport)
        XCTAssertTrue(controller.outstandingSteps.isEmpty)
    }

    func testSelectingDifferentEmbeddingModelInvalidatesSetup() async throws {
        let store = try makeStore()
        let modelA = DocumentEmbeddingModelRecord(repoID: "BAAI/bge-base-en-v1.5", localPath: "/tmp/a", displayName: "A", dimension: 768, runtimeFamily: "bert", isDefault: true)
        let modelB = DocumentEmbeddingModelRecord(repoID: "BAAI/bge-large-en-v1.5", localPath: "/tmp/b", displayName: "B", dimension: 1024, runtimeFamily: "bert")
        try store.documentSettings.upsertEmbeddingModel(modelA)
        try store.documentSettings.upsertEmbeddingModel(modelB)
        try store.documentSettings.selectEmbeddingModel(id: modelA.id)
        // Pretend setup was completed.
        try store.documentSettings.updateSettings { $0.setupCompletedAt = Date() }

        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 768),
            notifier: FakeNotifier(status: .authorized),
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SetupTests-\(UUID().uuidString)")),
            capabilitiesProvider: { capableToolchain }
        )
        XCTAssertTrue(controller.isComplete)

        controller.selectEmbeddingModel(id: modelB.id)
        XCTAssertFalse(controller.isComplete)
        XCTAssertEqual(controller.settings.setupInvalidatedReason, "embedding model changed")
    }

    func testEmbeddingDimensionMismatchFailsTestLoad() async throws {
        let store = try makeStore()
        let model = DocumentEmbeddingModelRecord(repoID: "r", localPath: "/tmp/e", displayName: "E", dimension: 768, runtimeFamily: "bert")
        try store.documentSettings.upsertEmbeddingModel(model)
        try store.documentSettings.selectEmbeddingModel(id: model.id)

        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 384), // wrong dimension
            notifier: FakeNotifier(status: .authorized),
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SetupTests-\(UUID().uuidString)")),
            capabilitiesProvider: { capableToolchain }
        )
        await controller.testLoadEmbeddingModel()
        XCTAssertFalse(controller.embeddingTestPassed)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private let capableToolchain = DocumentToolchainCapabilities(
    version: "test", pdfText: true, ocr: true, nativeImageDecoding: true,
    heicDecoding: true, supportedFamilies: ["pdf"], ocrLanguages: ["en-US"]
)

/// Runtime client stub that reports a loaded chat model and loads embeddings at a
/// configurable dimension, honoring the request's expected-dimension check.
private final class SetupStubRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let embeddingDimension: Int
    private let chatModelID = ModelID()

    init(embeddingDimension: Int) {
        self.embeddingDimension = embeddingDimension
    }

    func connect() async throws {}
    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }
    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }
    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] { [] }
    func unloadModel() async throws -> UnloadModelResponse { UnloadModelResponse(status: .unloaded) }
    func reloadCurrentModel() async throws -> LoadModelResponse { LoadModelResponse(status: .loaded, modelID: chatModelID) }
    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(state: .modelLoaded, loadedModelID: chatModelID, activeGenerationID: nil, message: nil, metrics: nil)
    }
    func restartRuntimeService() async throws {}

    func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse {
        if let expected = request.expectedDimension, expected != embeddingDimension {
            return LoadEmbeddingModelResponse(
                state: .failed, embeddingModelID: request.embeddingModelID,
                error: RuntimeError(category: "dimension", message: "dimension mismatch")
            )
        }
        return LoadEmbeddingModelResponse(
            state: .loaded, embeddingModelID: request.embeddingModelID, dimension: embeddingDimension, loadTimeMs: 1
        )
    }
    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        EmbedTextResponse(state: .loaded, vectors: request.texts.map { _ in [Float](repeating: 0, count: embeddingDimension) }, dimension: embeddingDimension)
    }
    func embeddingStatus() async throws -> EmbeddingModelStatus {
        EmbeddingModelStatus(state: .loaded, dimension: embeddingDimension)
    }
}

private struct FakeNotifier: DocumentNotifying {
    let status: DocumentNotificationAuthorizationStatus
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { status }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { status }
    func notify(title: String, body: String) async {}
}
