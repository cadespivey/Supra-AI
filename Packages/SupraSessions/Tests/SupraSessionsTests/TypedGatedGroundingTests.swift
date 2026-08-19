import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// A stale pre-redesign setting must not reactivate typed generation in matter chat.
@MainActor
final class TypedGatedGroundingTests: XCTestCase {
    func testStaleTypedGenerationSettingCannotReactivateMatterChat() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024.")
        try store.appSettings.setSetting("reasoning.typedGroundedGeneration.enabled", value: true)

        let capture = RequestBox()
        let prose = "## Natural answer\n\nThe agreement was signed on March 3, 2024. [S1] [S99]"
        let runtime = StubRuntimeClient { request in
            capture.set(request.prompt)
            return .events([
                .event(request, 0, .token, token: prose),
                .event(request, 1, .generationCompleted),
            ])
        }
        let controller = makeGlobalChatController(
            store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What do my documents say about the agreement date?",
            modelID: ModelID(), systemPrompt: nil, options: GenerationOptions()
        )

        XCTAssertFalse(try XCTUnwrap(capture.value).contains("insufficient_evidence"))
        XCTAssertEqual(controller.messages.last?.content, prose)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: String?
        func set(_ value: String) { lock.withLock { request = value } }
        var value: String? { lock.withLock { request } }
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ name: String, _ text: String) async throws {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(UUID().uuidString).txt")
        ).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: nil, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
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
