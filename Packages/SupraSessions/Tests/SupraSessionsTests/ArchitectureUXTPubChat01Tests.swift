import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore
@testable import SupraSessions
import XCTest

/// T-PUB-CHAT-01 — the real matter-chat terminal path must cross the Store's
/// atomic grounded-publication boundary. A grounded answer is not complete
/// until its message/variant/generation, exact packet, citations, verification,
/// assurance, authorization evidence, receipt, and audit commit together.
///
/// Expected RED: `GlobalChatController` currently completes the variant and
/// generation before creating the source packet, and source-citation writes are
/// swallowed with `try?`. The complete-first sentinel therefore aborts a normal
/// answer, a citation fault leaves a completed partial packet, and cancellation
/// immediately before terminal publication still produces completion.
@MainActor
final class ArchitectureUXTPubChat01Tests: XCTestCase {
    func testTPUBCHAT01ControllerNeverCompletesBeforeAtomicStorePublication() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "complete-first")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try installCompleteFirstSentinel(in: fixture.store)
        let controller = makeArchitectureUXPubChatController(
            fixture: fixture,
            runtimeClient: architectureUXPubChatSuccessRuntime()
        )

        await performArchitectureUXPubChatSend(controller)

        let assistant = try XCTUnwrap(
            controller.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.status, .completed)
        XCTAssertTrue(assistant.content.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        XCTAssertEqual(assistant.citations.map(\.label), ["S1"])
        XCTAssertEqual(assistant.citations.first?.displayName, ArchitectureUXPubChatWire.documentName)
        XCTAssertEqual(assistant.assuranceState, .preliminary)

        let sourceSet = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(messageID: assistant.id)
        )
        XCTAssertEqual(sourceSet.matterID, fixture.matter.id)
        XCTAssertEqual(sourceSet.messageID, assistant.id)
        XCTAssertEqual(sourceSet.retrievalQuery, ArchitectureUXPubChatWire.question)
        XCTAssertEqual(sourceSet.retrievalDepth, RetrievalDepth.fast.rawValue)
        XCTAssertEqual(sourceSet.embeddingModelID, ArchitectureUXPubChatWire.embeddingModelRepoID)
        XCTAssertEqual(
            sourceSet.embeddingModelRevision,
            ArchitectureUXPubChatWire.embeddingModelRevision
        )
        XCTAssertEqual(sourceSet.chunkerVersion, 2)
        XCTAssertFalse(sourceSet.scopeJSON.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        let sources = try fixture.store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(sources.map(\.citationLabel), ["S1"])
        XCTAssertEqual(sources.map(\.documentID), [fixture.document.id])
        XCTAssertEqual(sources.map(\.rank), [0])
        XCTAssertEqual(
            try fixture.store.chats.fetchCitations(messageID: assistant.id).map(\.label),
            ["S1"]
        )

        let receipt = try XCTUnwrap(
            try architectureUXPubChatReceipt(store: fixture.store, messageID: assistant.id)
        )
        XCTAssertEqual(receipt.messageID, assistant.id)
        XCTAssertEqual(receipt.sourceSetID, sourceSet.id)
        XCTAssertEqual(receipt.assuranceState, .preliminary)
        XCTAssertTrue(receipt.verificationDimensions.isComplete)
        XCTAssertFalse(receipt.idempotencyKey.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(receipt.idempotencyKey.contains(ArchitectureUXPubChatWire.sourceBody))
        XCTAssertFalse(receipt.idempotencyKey.contains(ArchitectureUXPubChatWire.forbiddenDefault))

        let audit = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(
                relatedTable: "messages",
                relatedID: assistant.id,
                eventType: ArchitectureUXPubChatWire.auditEventType
            ).first
        )
        XCTAssertEqual(audit.matterID, fixture.matter.id)
        XCTAssertEqual(audit.relatedID, assistant.id)
        XCTAssertFalse(audit.summary.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse((audit.metadataJSON ?? "{}").contains(ArchitectureUXPubChatWire.sourceBody))
    }

    func testTPUBCHAT01CitationFaultIsNotSwallowedOrLeftAsPartialSuccess() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "citation-fault")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try installCitationFailure(in: fixture.store)
        let controller = makeArchitectureUXPubChatController(
            fixture: fixture,
            runtimeClient: architectureUXPubChatSuccessRuntime()
        )

        await performArchitectureUXPubChatSend(controller)

        let assistant = try XCTUnwrap(
            controller.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(
            assistant.status,
            .failed,
            "a terminal publication fault must become a typed failed turn, never completed"
        )
        XCTAssertTrue(assistant.citations.isEmpty)
        XCTAssertNil(assistant.assuranceState)
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        let error = try XCTUnwrap(controller.errorMessage)
        XCTAssertTrue(
            error.localizedCaseInsensitiveContains("retry"),
            "the failed, retained turn must identify its recovery action"
        )
        XCTAssertFalse(error.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(error.contains(ArchitectureUXPubChatWire.sourceBody))
        XCTAssertFalse(error.contains(ArchitectureUXPubChatWire.forbiddenDefault))

        XCTAssertNil(
            try fixture.store.documentSources.fetchSourceSet(messageID: assistant.id),
            "a citation failure must roll the source set and rows back with it"
        )
        XCTAssertTrue(try fixture.store.chats.fetchCitations(messageID: assistant.id).isEmpty)
        XCTAssertNil(
            try architectureUXPubChatReceipt(store: fixture.store, messageID: assistant.id)
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "messages",
                relatedID: assistant.id,
                eventType: ArchitectureUXPubChatWire.auditEventType
            ).isEmpty
        )
        try assertArchitectureUXPubChatOwners(
            store: fixture.store,
            messageID: assistant.id,
            expectedStatus: .failed,
            expectedTerminalContentPresent: false
        )
    }

    func testTPUBCHAT01CancellationAtTerminalBoundaryNeverPublishesCompletion() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "cancel")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let holder = ArchitectureUXPubChatControllerHolder()
        let runtime = ArchitectureUXPubChatTerminalCancellationRuntime {
            await holder.cancelAtTerminalBoundary()
        }
        let controller = makeArchitectureUXPubChatController(
            fixture: fixture,
            runtimeClient: runtime
        )
        holder.controller = controller

        await performArchitectureUXPubChatSend(controller)

        XCTAssertEqual(runtime.terminalBoundaryCount, 1)
        let assistant = try XCTUnwrap(
            controller.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.status, .cancelled)
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        XCTAssertTrue(assistant.citations.isEmpty)
        XCTAssertNil(assistant.assuranceState)
        XCTAssertNil(try fixture.store.documentSources.fetchSourceSet(messageID: assistant.id))
        XCTAssertTrue(try fixture.store.chats.fetchCitations(messageID: assistant.id).isEmpty)
        XCTAssertNil(
            try architectureUXPubChatReceipt(store: fixture.store, messageID: assistant.id)
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "messages",
                relatedID: assistant.id,
                eventType: ArchitectureUXPubChatWire.auditEventType
            ).isEmpty
        )
        try assertArchitectureUXPubChatOwners(
            store: fixture.store,
            messageID: assistant.id,
            expectedStatus: .cancelled,
            expectedTerminalContentPresent: false
        )
    }

    private func installCompleteFirstSentinel(in store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER t_pub_chat_01_complete_first
                    BEFORE INSERT ON document_source_sets
                    WHEN NEW.message_id IS NOT NULL
                        AND EXISTS (
                            SELECT 1 FROM messages
                            WHERE id = NEW.message_id AND status = 'completed'
                        )
                    BEGIN
                        SELECT RAISE(ABORT, 'T-PUB-CHAT-01 observed complete-first publication');
                    END
                    """
            )
        }
    }

    private func installCitationFailure(in store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER t_pub_chat_01_citation_failure
                    BEFORE INSERT ON message_citations
                    WHEN NEW.label = 'S1'
                        AND NEW.display_name = '\(ArchitectureUXPubChatWire.documentName)'
                    BEGIN
                        SELECT RAISE(ABORT, 'T-PUB-CHAT-01 synthetic citation failure');
                    END
                    """
            )
        }
    }
}

enum ArchitectureUXPubChatWire {
    static let recordID = "record-713"
    static let version = 7
    static let nextVersion = 8
    static let forbiddenDefault = "DEFAULT-000"
    static let matterName = "T_PUB_CHAT_MATTER_719"
    static let documentName = "T_PUB_CHAT_01_WIRE_731.txt"
    static let sourceBody =
        "T_PUB_CHAT_SOURCE_739. The synthetic renewal date is June 17, 2031. Notice is due May 29, 2031."
    static let question = "According to my documents, what is the synthetic renewal date?"
    static let answerText = "The synthetic renewal date is June 17, 2031 [S1]."
    static let alteredAnswerText = "ALTERED: the synthetic renewal date is July 17, 2031 [S1]."
    static let embeddingModelID = "t-pub-chat-embedding-model-743"
    static let embeddingModelRepoID = "synthetic/t-pub-chat-embedding-743"
    static let embeddingModelRevision = "t-pub-chat-embedding-revision-7"
    static let auditEventType = "grounded_chat_terminal_published"
    static let timestamp = Date(timeIntervalSince1970: 1_946_253_751)
    static let metrics = RuntimeMetrics(
        loadTimeMs: 317,
        firstTokenLatencyMs: 419,
        tokensPerSecond: 23.75,
        peakMemoryMb: 1_927,
        generatedTokenCount: 83
    )
}

struct ArchitectureUXPubChatFixture {
    let root: URL
    let store: SupraStore
    let matter: MatterRecord
    let document: MatterDocumentRecord
}

@MainActor
func makeArchitectureUXPubChatFixture(prefix: String) async throws -> ArchitectureUXPubChatFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ArchitectureUXPubChat-\(prefix)-\(ArchitectureUXPubChatWire.recordID)-v\(ArchitectureUXPubChatWire.version)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SupraStore(url: root.appendingPathComponent("test.sqlite"))
    let matter = try store.matters.createMatter(name: ArchitectureUXPubChatWire.matterName)
    try configureArchitectureUXPubChatReadiness(store)

    let blob = try store.documentLibrary.upsertBlob(
        DocumentBlobRecord(
            sha256: String(repeating: "7", count: 64),
            byteSize: ArchitectureUXPubChatWire.sourceBody.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/t-pub-chat-01-wire-731.txt",
            mimeType: "text/plain",
            integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
            verifiedAt: ArchitectureUXPubChatWire.timestamp
        )
    ).blob
    let document = try store.documentLibrary.insertDocument(
        MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: ArchitectureUXPubChatWire.documentName,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            sourceKind: DocumentSourceKind.text.rawValue,
            extractionMethod: "synthetic_exact_text@toolchain:t-pub-chat-7",
            extractedTextChecksum: "t-pub-chat-source-checksum-739",
            pagePartCount: 1,
            importedAt: ArchitectureUXPubChatWire.timestamp
        )
    )
    let revision = DocumentPartRevisionRecord(
        documentID: document.id,
        partIndex: 0,
        derivationKey: "t-pub-chat-revision-751",
        origin: "parser",
        method: "synthetic_exact_text",
        text: ArchitectureUXPubChatWire.sourceBody,
        charCount: ArchitectureUXPubChatWire.sourceBody.count,
        toolchainVersion: "t-pub-chat-toolchain-7"
    )
    let selection = DocumentPartSelectionRecord(
        documentID: document.id,
        partIndex: 0,
        selectedRevisionID: revision.id,
        selectionKey: "t-pub-chat-selection-757",
        selectedBy: "system",
        policyVersion: ArchitectureUXPubChatWire.version,
        decisionJSON: #"{"rule":"t_pub_chat_exact_wire_731"}"#
    )
    let preservedUserEditIndexes = try store.documentRevisions.replacePartsAndPersistLineage(
        documentID: document.id,
        parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: ArchitectureUXPubChatWire.sourceBody,
                charCount: ArchitectureUXPubChatWire.sourceBody.count
            ),
        ],
        revisions: [revision],
        selections: [selection]
    )
    XCTAssertTrue(preservedUserEditIndexes.isEmpty)
    XCTAssertEqual(
        try store.documentRevisions.fetchRevisions(documentID: document.id, partIndex: 0).map(\.id),
        [revision.id]
    )
    XCTAssertEqual(
        try store.documentRevisions.fetchSelections(documentID: document.id, partIndex: 0)
            .map(\.selectedRevisionID),
        [revision.id]
    )
    let indexedChunkCount = try await DocumentIndexingService(
        store: store,
        embedder: ArchitectureUXPubChatEmbedder()
    ).indexDocument(documentID: document.id)
    XCTAssertEqual(indexedChunkCount, 1)
    let readiness = try store.documentReadiness.fetchReceipt(documentID: document.id)
    XCTAssertTrue(readiness.isBaseReady)
    XCTAssertFalse(readiness.receiptID.contains(ArchitectureUXPubChatWire.forbiddenDefault))
    let selectedModel = try XCTUnwrap(store.documentSettings.fetchSelectedEmbeddingModel())
    XCTAssertEqual(selectedModel.id, ArchitectureUXPubChatWire.embeddingModelID)
    XCTAssertEqual(selectedModel.repoID, ArchitectureUXPubChatWire.embeddingModelRepoID)
    XCTAssertEqual(selectedModel.revision, ArchitectureUXPubChatWire.embeddingModelRevision)
    XCTAssertEqual(ArchitectureUXPubChatWire.nextVersion, ArchitectureUXPubChatWire.version + 1)

    return ArchitectureUXPubChatFixture(
        root: root,
        store: store,
        matter: matter,
        document: document
    )
}

@MainActor
func makeArchitectureUXPubChatController(
    fixture: ArchitectureUXPubChatFixture,
    runtimeClient: any RuntimeClientProtocol
) -> GlobalChatController {
    let controller = makeGlobalChatController(
        store: fixture.store,
        runtimeClient: runtimeClient,
        scope: .matter(id: fixture.matter.id),
        embedder: nil
    )
    controller.loadChats()
    return controller
}

@MainActor
func performArchitectureUXPubChatSend(_ controller: GlobalChatController) async {
    await controller.performSend(
        prompt: ArchitectureUXPubChatWire.question,
        modelID: ModelID(),
        systemPrompt: "T_PUB_CHAT_SYSTEM_761",
        options: GenerationOptions(maxContextTokens: 2_047, maxOutputTokens: 127),
        isExplicitCommand: true
    )
}

func architectureUXPubChatSuccessRuntime() -> StubRuntimeClient {
    StubRuntimeClient { request in
        .events([
            .event(request, 1, .generationStarted),
            .event(request, 2, .token, token: ArchitectureUXPubChatWire.answerText),
            .event(
                request,
                3,
                .generationCompleted,
                metrics: ArchitectureUXPubChatWire.metrics
            ),
        ])
    }
}

func architectureUXPubChatReceipt(
    store: SupraStore,
    messageID: String
) throws -> GroundedChatTerminalPublicationReceipt? {
    let idempotencyKey = try store.database.writer.read { db in
        try String.fetchOne(
            db,
            sql: """
                SELECT idempotency_key
                FROM grounded_chat_publications
                WHERE message_id = ?
                """,
            arguments: [messageID]
        )
    }
    guard let idempotencyKey else { return nil }
    return try store.groundedChatPublications.fetchReceipt(idempotencyKey: idempotencyKey)
}

func assertArchitectureUXPubChatOwners(
    store: SupraStore,
    messageID: String,
    expectedStatus: MessageStatus,
    expectedTerminalContentPresent: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let owners = try store.database.writer.read { db -> (
        message: MessageRecord,
        variant: MessageVariantRecord,
        generation: GenerationSessionRecord
    ) in
        let message = try XCTUnwrap(MessageRecord.fetchOne(db, key: messageID), file: file, line: line)
        let variantID = try XCTUnwrap(message.activeVariantID, file: file, line: line)
        let variant = try XCTUnwrap(
            MessageVariantRecord.fetchOne(db, key: variantID),
            file: file,
            line: line
        )
        let generationID = try XCTUnwrap(variant.generationSessionID, file: file, line: line)
        let generation = try XCTUnwrap(
            GenerationSessionRecord.fetchOne(db, key: generationID),
            file: file,
            line: line
        )
        return (message, variant, generation)
    }
    XCTAssertEqual(owners.message.status, expectedStatus.rawValue, file: file, line: line)
    XCTAssertEqual(owners.variant.status, expectedStatus.rawValue, file: file, line: line)
    XCTAssertEqual(owners.generation.status, expectedStatus.rawValue, file: file, line: line)
    XCTAssertEqual(
        owners.message.content.contains(ArchitectureUXPubChatWire.answerText),
        expectedTerminalContentPresent,
        file: file,
        line: line
    )
    XCTAssertEqual(
        owners.variant.content.contains(ArchitectureUXPubChatWire.answerText),
        expectedTerminalContentPresent,
        file: file,
        line: line
    )
}

private func configureArchitectureUXPubChatReadiness(_ store: SupraStore) throws {
    let embedder = ArchitectureUXPubChatEmbedder()
    let initialSettings = try store.documentSettings.loadSettings()
    XCTAssertEqual(initialSettings.id, DocumentIntelligenceSettingsRecord.singletonID)
    XCTAssertEqual(initialSettings.chunkerVersion, 2)
    try store.documentSettings.upsertEmbeddingModel(
        DocumentEmbeddingModelRecord(
            id: embedder.modelID,
            repoID: embedder.modelRepoID,
            localPath: "/synthetic/t-pub-chat/model-743",
            displayName: embedder.modelDisplayName,
            dimension: embedder.dimension,
            runtimeFamily: "t-pub-chat-readiness-7",
            revision: embedder.modelRevision,
            isDefault: false,
            isSelected: false,
            lastTestLoadAt: ArchitectureUXPubChatWire.timestamp,
            lastTestLoadResult: "passed",
            createdAt: ArchitectureUXPubChatWire.timestamp,
            updatedAt: ArchitectureUXPubChatWire.timestamp
        )
    )
    try store.documentSettings.selectEmbeddingModel(id: embedder.modelID)
    try store.documentSettings.updateSettings {
        $0.embeddingModelLastTestedAt = ArchitectureUXPubChatWire.timestamp
        // Version 2 is the shipping chunker contract. The independent 7 -> 8
        // wire above remains the nondefault revision/test sentinel.
        $0.chunkerVersion = 2
    }
}

private struct ArchitectureUXPubChatEmbedder: TextEmbedder {
    let modelID = ArchitectureUXPubChatWire.embeddingModelID
    let modelRepoID = ArchitectureUXPubChatWire.embeddingModelRepoID
    let modelDisplayName = "T PUB CHAT Embedding 743"
    let modelRevision: String? = ArchitectureUXPubChatWire.embeddingModelRevision
    let dimension = 8

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [0, 1, 0, 0, 0, 0, 0, 0] }
    }
}

@MainActor
private final class ArchitectureUXPubChatControllerHolder {
    weak var controller: GlobalChatController?

    func cancelAtTerminalBoundary() {
        controller?.cancel()
    }
}

private final class ArchitectureUXPubChatTerminalCancellationRuntime:
    RuntimeClientProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let onTerminalBoundary: @Sendable () async -> Void
    private var _terminalBoundaryCount = 0

    init(onTerminalBoundary: @escaping @Sendable () async -> Void) {
        self.onTerminalBoundary = onTerminalBoundary
    }

    var terminalBoundaryCount: Int {
        lock.withLock { _terminalBoundaryCount }
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        CountTokensResponse(
            modelID: request.modelID,
            counts: request.texts.map { ($0.utf8.count + 3) / 4 }
        )
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let onTerminalBoundary = onTerminalBoundary
        let incrementBoundaryCount: @Sendable () -> Void = { [weak self] in
            self?.lock.withLock { self?._terminalBoundaryCount += 1 }
        }
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.event(request, 1, .generationStarted))
                continuation.yield(
                    .event(
                        request,
                        2,
                        .token,
                        token: ArchitectureUXPubChatWire.answerText
                    )
                )
                incrementBoundaryCount()
                await onTerminalBoundary()
                continuation.yield(
                    .event(
                        request,
                        3,
                        .generationCompleted,
                        metrics: ArchitectureUXPubChatWire.metrics
                    )
                )
                continuation.finish()
            }
        }
    }

    func cancelGeneration(
        _ generationID: GenerationID
    ) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: ModelID())
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: ModelID(),
            activeGenerationID: nil,
            message: "T_PUB_CHAT_RUNTIME_READY_769",
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}
