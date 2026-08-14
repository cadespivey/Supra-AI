import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore
@testable import SupraSessions
import XCTest

/// T-ATTACH-02. An inline file is a session-only, unverified quick attachment,
/// never a durable source packet. The only transition to durable grounding is
/// an explicit handoff that runs normal import/indexing and returns success only
/// with the Store's canonical ready receipt.
///
/// Expected RED: the current send path has no answer-time quick-attachment
/// presentation, and `QuickAttachmentMatterHandoff` does not exist. Attachment
/// text can be used in a model prompt, but there is no typed way to distinguish
/// that nondurable context from a grounded source or to await canonical readiness.
@MainActor
final class ArchitectureUXTAttach02Tests: XCTestCase {
    private enum Wire {
        static let recordID = "record-713"
        static let version = 7
        static let nextVersion = 8
        static let attachmentName = "T_ATTACH_02_WIRE_731.txt"
        static let attachmentText = "T_ATTACH_02_SESSION_ONLY_BODY_739"
        static let answerText = "T_ATTACH_02_SESSION_ONLY_ANSWER_743"
        static let matterName = "T_ATTACH_02_MATTER_751"
        static let embeddingModelID = "T_ATTACH_02_MODEL_757"
        static let embeddingModelRevision = "T_ATTACH_02_MODEL_REVISION_7"
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_252_731)
    }

    func testActualAttachmentOnlySendHasSessionDisclosureButNoDurablePacketPromotionOrExport() async throws {
        let fixture = try await makeAttachmentFixture(prefix: "send")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let matter = try fixture.store.matters.createMatter(name: Wire.matterName)
        let requests = AttachmentRequestCapture()
        let runtime = StubRuntimeClient { request in
            requests.record(request)
            return .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: Wire.answerText),
                .event(request, 3, .generationCompleted),
            ])
        }
        let controller = makeGlobalChatController(
            store: fixture.store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id)
        )
        controller.loadChats()

        // Exercise the real persist-and-stream boundary with no textual prompt.
        await controller.performSend(
            prompt: "",
            attachments: [fixture.attachment],
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions()
        )

        let user = try XCTUnwrap(controller.messages.first { $0.role == .user })
        let assistant = try XCTUnwrap(controller.messages.last { $0.role == .assistant })
        XCTAssertEqual(assistant.content, Wire.answerText)
        XCTAssertEqual(assistant.status, .completed)
        XCTAssertNil(assistant.assuranceState)
        XCTAssertTrue(try XCTUnwrap(requests.lastPrompt).contains(Wire.attachmentText))
        XCTAssertTrue(try XCTUnwrap(requests.lastPrompt).contains(Wire.attachmentName))
        XCTAssertFalse(try XCTUnwrap(requests.lastPrompt).contains(Wire.forbiddenDefault))

        let composition = fixture.attachment.presentation
        XCTAssertEqual(composition.title, "Quick attachment")
        XCTAssertEqual(composition.contentStatus, "Full content")
        XCTAssertEqual(composition.durabilityStatus, "Session only")
        XCTAssertEqual(composition.verificationStatus, "Unverified")
        XCTAssertEqual(
            controller.quickAttachmentPresentations(messageID: user.id),
            [composition],
            "the composition disclosure must follow the echoed turn"
        )
        XCTAssertEqual(
            controller.quickAttachmentPresentations(messageID: assistant.id),
            [composition],
            "the same disclosure must remain visible beside the answer"
        )

        XCTAssertNil(try fixture.store.documentSources.fetchSourceSet(messageID: user.id))
        XCTAssertNil(try fixture.store.documentSources.fetchSourceSet(messageID: assistant.id))
        XCTAssertTrue(try fixture.store.documentSources.fetchSourceSets(matterID: matter.id).isEmpty)
        XCTAssertTrue(controller.availableArtifactActions(messageID: assistant.id).isEmpty)
        XCTAssertNil(controller.saveToOutputs(messageID: assistant.id))
        XCTAssertTrue(try fixture.store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: matter.id).isEmpty)
        XCTAssertTrue(try fixture.store.documentLibrary.fetchDocuments(matterID: matter.id).isEmpty)

        // Reopening can retain ordinary chat history, but it cannot reconstruct or
        // imply attachment provenance from a filename in the display message.
        let reopened = makeGlobalChatController(
            store: fixture.store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id)
        )
        reopened.loadChats()
        let reopenedAnswer = try XCTUnwrap(reopened.messages.last { $0.role == .assistant })
        XCTAssertEqual(reopenedAnswer.content, Wire.answerText)
        XCTAssertTrue(
            reopened.quickAttachmentPresentations(messageID: reopenedAnswer.id).isEmpty,
            "session-only context must not be fabricated after relaunch"
        )
        XCTAssertTrue(reopened.availableArtifactActions(messageID: reopenedAnswer.id).isEmpty)
    }

    func testAddToMatterCannotCompleteBeforeNormalImportAndCanonicalReadiness() async throws {
        let unready = try await makeAttachmentFixture(prefix: "unready")
        defer { try? FileManager.default.removeItem(at: unready.root) }
        let unreadyMatter = try unready.store.matters.createMatter(
            name: "\(Wire.matterName)_UNREADY_761"
        )
        let unreadyHandoff = QuickAttachmentMatterHandoff(
            store: unready.store,
            importService: DocumentImportService(
                store: unready.store,
                storage: unready.storage,
                ocr: nil
            ),
            indexingService: DocumentIndexingService(store: unready.store, embedder: nil)
        )

        let unreadyOutcome = await unreadyHandoff.addToMatter(
            attachment: unready.attachment,
            matterID: unreadyMatter.id
        )
        guard case let .awaitingReadiness(documentID, observedReceipt) = unreadyOutcome else {
            return XCTFail("text-only import must remain awaiting canonical semantic readiness")
        }
        let imported = try XCTUnwrap(
            unready.store.documentLibrary.fetchDocument(id: documentID)
        )
        let canonicalUnready = try unready.store.documentReadiness.fetchReceipt(
            documentID: documentID
        )
        XCTAssertEqual(imported.matterID, unreadyMatter.id)
        XCTAssertEqual(imported.displayName, Wire.attachmentName)
        XCTAssertEqual(observedReceipt, canonicalUnready)
        XCTAssertFalse(observedReceipt.isBaseReady)
        XCTAssertTrue(observedReceipt.exclusions.contains(.activeEmbeddingModelMissing))
        XCTAssertTrue(observedReceipt.exclusions.contains(.semanticIndexIncomplete))
        XCTAssertEqual(
            try unready.store.documentJobs.fetchBatches(matterID: unreadyMatter.id).count,
            1,
            "the handoff must be a normal durable import before it waits for readiness"
        )
        XCTAssertTrue(try unready.store.structuredOutputs.fetchOutputs(matterID: unreadyMatter.id).isEmpty)

        let ready = try await makeAttachmentFixture(prefix: "ready")
        defer { try? FileManager.default.removeItem(at: ready.root) }
        let readyMatter = try ready.store.matters.createMatter(
            name: "\(Wire.matterName)_READY_769"
        )
        let embedder = AttachmentReadinessEmbedder()
        try configureActiveEmbeddingModel(ready.store, embedder: embedder)
        let readyHandoff = QuickAttachmentMatterHandoff(
            store: ready.store,
            importService: DocumentImportService(
                store: ready.store,
                storage: ready.storage,
                ocr: nil
            ),
            indexingService: DocumentIndexingService(store: ready.store, embedder: embedder)
        )

        let readyOutcome = await readyHandoff.addToMatter(
            attachment: ready.attachment,
            matterID: readyMatter.id
        )
        guard case let .completed(completion) = readyOutcome else {
            return XCTFail("a handoff may complete only after canonical readiness is green")
        }
        let canonicalReady = try ready.store.documentReadiness.fetchReceipt(
            documentID: completion.documentID
        )
        XCTAssertEqual(completion.attachmentID, ready.attachment.id)
        XCTAssertEqual(completion.matterID, readyMatter.id)
        XCTAssertEqual(completion.readinessReceipt, canonicalReady)
        XCTAssertTrue(completion.readinessReceipt.isBaseReady)
        XCTAssertFalse(completion.readinessReceipt.receiptID.contains(Wire.attachmentText))
        XCTAssertFalse(completion.readinessReceipt.receiptID.contains(Wire.attachmentName))
        XCTAssertFalse(completion.readinessReceipt.receiptID.contains(Wire.forbiddenDefault))
        XCTAssertFalse(completion.importBatchID.isEmpty)
        XCTAssertNotNil(
            try ready.store.documentJobs.fetchBatch(id: completion.importBatchID)
        )
        XCTAssertEqual(ready.attachment.durability, .sessionOnly)
        XCTAssertEqual(ready.attachment.verificationState, .unverified)
    }

    private struct AttachmentFixture {
        let root: URL
        let sourceURL: URL
        let storage: DocumentStorage
        let store: SupraStore
        let attachment: ChatAttachmentContext
    }

    private func makeAttachmentFixture(prefix: String) async throws -> AttachmentFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TAttach02-\(prefix)-\(Wire.recordID)-v\(Wire.version)-\(UUID().uuidString)",
            isDirectory: true
        )
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let sourceURL = sources.appendingPathComponent(Wire.attachmentName)
        try Wire.attachmentText.write(to: sourceURL, atomically: true, encoding: .utf8)
        let storage = DocumentStorage(root: root.appendingPathComponent("Managed", isDirectory: true))
        let store = try SupraStore.inMemory()
        let attachment = try await ChatAttachmentLoader().load(url: sourceURL)
        XCTAssertEqual(attachment.sourceURL, sourceURL)
        XCTAssertEqual(attachment.text, Wire.attachmentText)
        XCTAssertEqual(attachment.originalCharacterCount, Wire.attachmentText.count)
        XCTAssertEqual(attachment.includedCharacterCount, Wire.attachmentText.count)
        XCTAssertFalse(attachment.isTruncated)
        XCTAssertEqual(Wire.nextVersion, Wire.version + 1)
        return AttachmentFixture(
            root: root,
            sourceURL: sourceURL,
            storage: storage,
            store: store,
            attachment: attachment
        )
    }

    private func configureActiveEmbeddingModel(
        _ store: SupraStore,
        embedder: AttachmentReadinessEmbedder
    ) throws {
        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: embedder.modelID,
                repoID: embedder.modelRepoID,
                localPath: "/synthetic/t-attach-02/\(embedder.modelID)",
                displayName: embedder.modelDisplayName,
                dimension: embedder.dimension,
                runtimeFamily: "t-attach-02-readiness-v7",
                revision: embedder.modelRevision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: Wire.timestamp,
                lastTestLoadResult: "passed",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: embedder.modelID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
        }
    }
}

private final class AttachmentRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    func record(_ request: GenerateRequest) {
        lock.withLock { prompts.append(request.prompt) }
    }

    var lastPrompt: String? { lock.withLock { prompts.last } }
}

private struct AttachmentReadinessEmbedder: TextEmbedder {
    let modelID = "T_ATTACH_02_MODEL_757"
    let modelRepoID = "T_ATTACH_02_MODEL_REPO_761"
    let modelDisplayName = "T Attach 02 Readiness Model 7"
    let modelRevision: String? = "T_ATTACH_02_MODEL_REVISION_7"
    let dimension = 7

    func embed(_ texts: [String]) async throws -> [[Float]] {
        // A deterministic unit vector exercises the real semantic-index path
        // without relying on production normalization to make the fixture valid.
        texts.map { _ in [1, 0, 0, 0, 0, 0, 0] }
    }
}
