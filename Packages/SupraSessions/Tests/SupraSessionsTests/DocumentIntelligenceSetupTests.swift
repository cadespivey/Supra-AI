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

    func testTOPS04ModelSwitchEnqueuesOneReembedAndRetrievesWithModelB() async throws {
        // T-OPS-04 expected RED: DocumentIntelligenceSetupController has no
        // setReindexEnqueuer seam, so selecting model B cannot dispatch work.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic model-switch wire proof")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: "tops04-orthogonal",
                byteSize: 1,
                originalExtension: "txt",
                managedRelativePath: "blobs/tops04-orthogonal.txt"
            )
        ).blob
        let aDocument = try insertExtractedDocument(
            store: store,
            matterID: matter.id,
            blobID: blob.id,
            name: "A-only Evidence.txt",
            text: "A_VECTOR_CANARY belongs only to the first orthogonal branch."
        )
        let bDocument = try insertExtractedDocument(
            store: store,
            matterID: matter.id,
            blobID: blob.id,
            name: "B-only Evidence.txt",
            text: "B_VECTOR_CANARY belongs only to the second orthogonal branch."
        )
        let modelA = DocumentEmbeddingModelRecord(
            repoID: "synthetic/model-a",
            localPath: "/tmp/tops04-a",
            displayName: "Synthetic Model A",
            dimension: 2,
            runtimeFamily: "synthetic"
        )
        let modelB = DocumentEmbeddingModelRecord(
            repoID: "synthetic/model-b",
            localPath: "/tmp/tops04-b",
            displayName: "Synthetic Model B",
            dimension: 2,
            runtimeFamily: "synthetic"
        )
        try store.documentSettings.upsertEmbeddingModel(modelA)
        try store.documentSettings.upsertEmbeddingModel(modelB)
        try store.documentSettings.selectEmbeddingModel(id: modelA.id)
        _ = try await DocumentIndexingService(
            store: store,
            embedder: OrthogonalTestEmbedder(modelID: modelA.id, counter: EmbedCallCounter())
        ).indexMatter(matterID: matter.id)

        let modelBCalls = EmbedCallCounter()
        let modelBEmbedder = OrthogonalTestEmbedder(modelID: modelB.id, counter: modelBCalls)
        let importer = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("TOPS04-Storage-\(UUID().uuidString)", isDirectory: true)),
            ocr: nil
        )
        let queue = DocumentProcessingQueue(
            store: store,
            importService: importer,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: modelBEmbedder) },
            notifier: FakeNotifier(status: .denied)
        )
        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 2),
            notifier: FakeNotifier(status: .denied),
            capabilitiesProvider: { capableToolchain }
        )
        controller.setReindexEnqueuer { [weak queue] matterID in
            _ = queue?.enqueueReindex(matterID: matterID)
        }

        controller.selectEmbeddingModel(id: modelB.id)

        XCTAssertEqual(modelBCalls.value, 0, "model selection must not embed in the foreground")
        XCTAssertEqual(try store.documentJobs.fetchJobs(matterID: matter.id).count, 1)
        await queue.waitUntilIdle()
        XCTAssertFalse(try store.documentIndex.fetchEmbeddings(
            documentID: aDocument.id,
            embeddingModelID: modelB.id
        ).isEmpty)
        XCTAssertFalse(try store.documentIndex.fetchEmbeddings(
            documentID: bDocument.id,
            embeddingModelID: modelB.id
        ).isEmpty)

        let result = try await DocumentRetrievalService(
            store: store,
            embedder: modelBEmbedder,
            minSemanticSimilarity: 0.5
        ).retrieve(
            matterID: matter.id,
            query: "ORTHOGONAL_QUERY_CANARY",
            scope: .wholeMatter
        )
        XCTAssertTrue(result.sources.contains {
            $0.documentID == bDocument.id && !$0.ftsMatched && $0.semanticBucket != nil
        })
        XCTAssertFalse(result.sources.contains { $0.documentID == aDocument.id })
    }

    func testTOPS06ToolchainDriftMarksOnlyOlderLineageStaleWithoutReprocessing() throws {
        // T-OPS-06 expected RED: refreshToolchain overwrites the stored version
        // without comparing document lineage or marking the v1 document stale.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic converter drift")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: "tops06-converter",
                byteSize: 1,
                originalExtension: "txt",
                managedRelativePath: "blobs/tops06-converter.txt"
            )
        ).blob
        let v1Document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Converted Under V1.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue,
            extractionMethod: "text@toolchain:v1"
        ))
        let v2Document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Converted Under V2.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue,
            extractionMethod: "text@toolchain:v2"
        ))
        try store.documentIndex.replaceParts(documentID: v1Document.id, parts: [
            DocumentPagePartRecord(
                documentID: v1Document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: "V1 sentinel text must survive drift detection.",
                charCount: 46
            ),
        ])
        try store.documentIndex.replaceParts(documentID: v2Document.id, parts: [
            DocumentPagePartRecord(
                documentID: v2Document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: "V2 current text remains ready.",
                charCount: 30
            ),
        ])
        try store.documentSettings.updateSettings { $0.converterToolchainVersion = "v1" }

        let runtimeV2 = DocumentToolchainCapabilities(
            version: "v2",
            pdfText: true,
            ocr: true,
            nativeImageDecoding: true,
            heicDecoding: true,
            supportedFamilies: ["text"],
            ocrLanguages: ["en-US"]
        )
        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 2),
            notifier: FakeNotifier(status: .authorized),
            capabilitiesProvider: { runtimeV2 }
        )
        controller.refreshToolchain()

        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: v1Document.id)?.indexStatus,
            DocumentIndexStatus.stale.rawValue
        )
        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: v2Document.id)?.indexStatus,
            DocumentIndexStatus.ready.rawValue
        )
        XCTAssertEqual(
            try store.auditEvents.fetchEvents(
                relatedTable: "matter_documents",
                relatedID: v1Document.id,
                eventType: "document_converter_lineage_stale"
            ).first?.summary,
            "Converter toolchain changed from v1 to v2; document requires manual reprocessing."
        )
        XCTAssertEqual(
            try store.documentIndex.fetchParts(documentID: v1Document.id).first?.normalizedText,
            "V1 sentinel text must survive drift detection."
        )
        XCTAssertTrue(try store.documentJobs.fetchJobs(matterID: matter.id).isEmpty)
    }

    func testSetupGatingBlocksThenCompletesWhenAllStepsPass() async throws {
        let store = try makeStore()
        let modelPath = try makeModelDirectory()
        // A downloaded, selected embedding model is already registered.
        let model = DocumentEmbeddingModelRecord(
            repoID: "BAAI/bge-base-en-v1.5",
            localPath: modelPath,
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

        XCTAssertTrue(controller.isComplete)
        XCTAssertTrue(controller.isReadyForImport)
        XCTAssertNotNil(controller.settings.setupCompletedAt)
        XCTAssertTrue(controller.outstandingSteps.isEmpty)
    }

    func testSelectingDifferentEmbeddingModelInvalidatesSetup() async throws {
        let store = try makeStore()
        let modelA = DocumentEmbeddingModelRecord(repoID: "BAAI/bge-base-en-v1.5", localPath: "/tmp/a", displayName: "A", dimension: 768, runtimeFamily: "bert", isDefault: true)
        let modelB = DocumentEmbeddingModelRecord(repoID: "BAAI/bge-large-en-v1.5", localPath: "/tmp/b", displayName: "B", dimension: 1024, runtimeFamily: "bert")
        try store.documentSettings.upsertEmbeddingModel(modelA)
        try store.documentSettings.upsertEmbeddingModel(modelB)
        try store.documentSettings.selectEmbeddingModel(id: modelA.id)
        try store.documentSettings.recordTestLoad(modelID: modelA.id, result: "passed")
        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SetupTests-\(UUID().uuidString)"))
        try storage.initializeStorage()
        let capabilityJSON = String(data: try JSONEncoder().encode(capableToolchain), encoding: .utf8)
        try store.documentSettings.updateSettings {
            $0.chatModelLastLoadedAt = Date()
            $0.embeddingModelLastTestedAt = Date()
            $0.converterToolchainVersion = capableToolchain.version
            $0.converterCapabilityJSON = capabilityJSON
            $0.ocrAvailable = capableToolchain.ocr
            $0.ocrCheckedAt = Date()
            $0.storageInitializedAt = Date()
            $0.setupCompletedAt = Date()
        }

        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 768),
            notifier: FakeNotifier(status: .authorized),
            storage: storage,
            capabilitiesProvider: { capableToolchain }
        )
        XCTAssertTrue(controller.isComplete)

        controller.selectEmbeddingModel(id: modelB.id)
        XCTAssertFalse(controller.isComplete)
        XCTAssertEqual(controller.settings.setupInvalidatedReason, "embedding model changed")
    }

    func testEmbeddingDimensionMismatchFailsTestLoad() async throws {
        let store = try makeStore()
        let model = DocumentEmbeddingModelRecord(repoID: "r", localPath: try makeModelDirectory(), displayName: "E", dimension: 768, runtimeFamily: "bert")
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

    func testCustomEmbeddingModelDimensionDiscoveredOnVerify() async throws {
        let store = try makeStore()
        // A custom (non-curated) model registered without a known dimension.
        let model = DocumentEmbeddingModelRecord(
            repoID: "acme/custom-embedder", localPath: try makeModelDirectory(),
            displayName: "Custom", dimension: 0, runtimeFamily: ""
        )
        try store.documentSettings.upsertEmbeddingModel(model)
        try store.documentSettings.selectEmbeddingModel(id: model.id)

        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 1024),
            notifier: FakeNotifier(status: .authorized),
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SetupTests-\(UUID().uuidString)")),
            capabilitiesProvider: { capableToolchain }
        )

        // Dimension 0 means "unknown": the expected-dimension assertion is skipped,
        // the load succeeds, and the probed dimension is captured back onto the record.
        await controller.testLoadEmbeddingModel()
        XCTAssertTrue(controller.embeddingTestPassed)
        XCTAssertEqual(controller.selectedEmbeddingModel?.dimension, 1024)
        XCTAssertEqual(try store.documentSettings.fetchEmbeddingModel(id: model.id)?.dimension, 1024)
    }

    func testHandleEmbeddingModelDownloadedReloadsAndVerifies() async throws {
        let store = try makeStore()
        let controller = DocumentIntelligenceSetupController(
            store: store,
            runtimeClient: SetupStubRuntimeClient(embeddingDimension: 768),
            notifier: FakeNotifier(status: .authorized),
            storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SetupTests-\(UUID().uuidString)")),
            capabilitiesProvider: { capableToolchain }
        )

        // Simulate a download that registered + selected a model directly in the store
        // (as EmbeddingModelDownloadController does), bypassing the controller's cache.
        let model = DocumentEmbeddingModelRecord(
            repoID: "BAAI/bge-base-en-v1.5", localPath: try makeModelDirectory(),
            displayName: "BGE Base", dimension: 768, runtimeFamily: "bert"
        )
        try store.documentSettings.upsertEmbeddingModel(model)
        try store.documentSettings.selectEmbeddingModel(id: model.id)
        XCTAssertFalse(controller.availableEmbeddingModels.contains { $0.id == model.id },
                       "cache should be stale until the download callback fires")

        controller.handleEmbeddingModelDownloaded()
        // The list refresh is synchronous (nit #1).
        XCTAssertTrue(controller.availableEmbeddingModels.contains { $0.id == model.id })
        XCTAssertEqual(controller.selectedEmbeddingModel?.id, model.id)

        // The auto-verify runs as a spawned main-actor task; let it complete.
        for _ in 0..<100 where !controller.embeddingTestPassed { await Task.yield() }
        XCTAssertTrue(controller.embeddingTestPassed)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    private func makeModelDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func insertExtractedDocument(
        store: SupraStore,
        matterID: String,
        blobID: String,
        name: String,
        text: String
    ) throws -> MatterDocumentRecord {
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blobID,
            displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            ),
        ])
        return document
    }
}

private final class EmbedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func record(_ units: Int) {
        lock.withLock { count += units }
    }
}

private struct OrthogonalTestEmbedder: TextEmbedder {
    let modelID: String
    let counter: EmbedCallCounter
    var modelRepoID: String { modelID }
    var modelDisplayName: String { modelID }
    let modelRevision: String? = nil
    let dimension = 2

    func embed(_ texts: [String]) async throws -> [[Float]] {
        counter.record(texts.count)
        return texts.map { text in
            let normalized = text.uppercased()
            if normalized.contains("B_VECTOR_CANARY") || normalized.contains("ORTHOGONAL_QUERY_CANARY") {
                return [1, 0]
            }
            return [0, 1]
        }
    }
}

private let capableToolchain = DocumentToolchainCapabilities(
    version: "test", pdfText: true, ocr: true, nativeImageDecoding: true,
    heicDecoding: true, supportedFamilies: ["pdf"], ocrLanguages: ["en-US"]
)

/// Runtime client stub that reports a loaded runtime text model and loads embeddings at a
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
