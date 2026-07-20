import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Phase 1 gate switch (P1-T4): a matter-document CONTENT question is answered by typed
/// generation (validated exactly, rendered to [S#]-prose) when the flag is on, with a clean
/// fallback to the existing prose streaming path. The streaming path and the inventory path
/// are untouched. Driven by a stub runtime — no real model.
@MainActor
final class TypedGatedGroundingTests: XCTestCase {

    private func enableTypedGeneration(_ store: SupraStore) throws {
        try store.appSettings.setSetting(GlobalChatController.typedGroundedGenerationKey, value: true)
    }

    /// A stub that returns a typed AnswerDraft for the schema prompt and prose otherwise, so
    /// the test can tell which path ran.
    private func splitStub(typed: String, prose: String) -> StubRuntimeClient {
        StubRuntimeClient { request in
            let text = request.prompt.contains("insufficient_evidence") ? typed : prose
            return .events([.event(request, 0, .token, token: text), .event(request, 1, .generationCompleted)])
        }
    }

    func testFlagOnContentQuestionUsesTypedGeneration() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024 by both parties.")
        try enableTypedGeneration(store)

        let stub = splitStub(
            typed: #"{"segments": [{"text": "The agreement was signed on March 3, 2024.", "citations": ["S1"]}]}"#,
            prose: "PROSE STREAMING PATH [S1]"
        )
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(
            prompt: "What do my documents say about the agreement date?",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("The agreement was signed on March 3, 2024. [S1]"), "typed answer rendered with [S#]; got: \(answer)")
        XCTAssertFalse(answer.contains("PROSE STREAMING PATH"), "the streaming path must not run when typed succeeds")
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testFlagOffContentQuestionUsesProseStreaming() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024.")
        // flag NOT enabled

        let stub = splitStub(
            typed: #"{"segments": [{"text": "TYPED", "citations": ["S1"]}]}"#,
            prose: "PROSE STREAMING PATH [S1]."
        )
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(
            prompt: "What do my documents say about the agreement date?",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("PROSE STREAMING PATH"), "flag off must use the existing streaming path")
        XCTAssertFalse(answer.contains("TYPED"))
    }

    func testFlagOnTypedFallbackDropsToProseStreaming() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024.")
        try enableTypedGeneration(store)

        // Typed schema prompt always returns unparseable → TypedGroundedGenerator exhausts and
        // falls back; the streaming (QA) prompt then returns prose.
        let stub = splitStub(typed: "not json at all", prose: "PROSE FALLBACK ANSWER [S1].")
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(
            prompt: "What do my documents say about the agreement date?",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("PROSE FALLBACK ANSWER"), "an unparseable typed reply must fall back to streaming; got: \(answer)")
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testFlagOnEmptyTypedDraftFallsBackToProse() async throws {
        // A weak model that emits a structurally-valid but EMPTY draft must not produce a blank
        // completed answer — it falls back to the prose streaming path.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024.")
        try enableTypedGeneration(store)

        let stub = splitStub(
            typed: #"{"insufficient_evidence": false, "segments": []}"#,
            prose: "PROSE FALLBACK ANSWER [S1]."
        )
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(
            prompt: "What do my documents say about the agreement date?",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        let answer = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(answer.contains("PROSE FALLBACK ANSWER"), "an empty typed draft must fall back to prose; got: \(answer)")
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "must never persist a blank completed answer")
    }

    func testFlagOnInventoryQuestionStaysDeterministic() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        _ = try insertDoc(store, matter.id, "Avatar Props. v. Gundel.pdf")
        try enableTypedGeneration(store)

        // Inventory has no packed [S#] sources → typed path is skipped; the deterministic
        // inventory listing streams as before.
        let captured = RequestBox()
        let stub = StubRuntimeClient { request in
            captured.set(request.prompt)
            return .events([.event(request, 0, .token, token: "ok"), .event(request, 1, .generationCompleted)])
        }
        let controller = makeGlobalChatController(store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(
            prompt: "list all documents in this matter",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        let prompt = try XCTUnwrap(captured.value)
        XCTAssertTrue(prompt.contains("DOCUMENT INVENTORY"), "inventory stays the deterministic listing prompt")
        XCTAssertFalse(prompt.contains("insufficient_evidence"), "inventory must not use the typed schema prompt")
    }

    // MARK: - Helpers

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock(); private var _v: String?
        func set(_ s: String) { lock.withLock { _v = s } }
        var value: String? { lock.withLock { _v } }
    }

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypedGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    @discardableResult
    private func insertDoc(_ store: SupraStore, _ matterID: String, _ name: String) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/\(UUID().uuidString).pdf")
        ).blob
        return try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: nil, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
    }

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ name: String, _ text: String) async throws {
        let document = try insertDoc(store, matterID, name)
        let revision = DocumentPartRevisionRecord(
            documentID: document.id, partIndex: 0, derivationKey: "typedgate-\(document.id)",
            origin: "parser", method: "synthetic", text: text, charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            documentID: document.id, partIndex: 0, selectedRevisionID: revision.id,
            selectionKey: "typedgate-sel-\(document.id)", selectedBy: "system", policyVersion: 1,
            decisionJSON: #"{"rule":"synthetic_fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [DocumentPagePartRecord(documentID: document.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)],
            revisions: [revision], selections: [selection]
        )
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: document.id)
    }
}
