import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Records the prompts a stub runtime is asked to generate, so tests can assert what
/// grounding actually injected into the model context.
private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    private var systemPrompts: [String?] = []

    func record(_ request: GenerateRequest) {
        lock.withLock { prompts.append(request.prompt); systemPrompts.append(request.systemPrompt) }
    }

    var lastPrompt: String? { lock.withLock { prompts.last } }
    var lastSystemPrompt: String? { lock.withLock { systemPrompts.last ?? nil } }
}

@MainActor
final class MatterChatGroundingTests: XCTestCase {

    // MARK: - Intent classifier

    func testFolderListingIsInventory() {
        // The exact query from the bug report.
        let intent = MatterChatDocumentIntent.classify(
            "provide a list of all cases located in the research folder of this matter",
            folderNames: ["Research"]
        )
        XCTAssertEqual(intent, .inventory(folderHint: "Research"))
    }

    func testHowManyFilesIsInventory() {
        let intent = MatterChatDocumentIntent.classify("how many files are in this matter?", folderNames: [])
        XCTAssertEqual(intent, .inventory(folderHint: nil))
    }

    func testDocumentContentQuestionIsContent() {
        let intent = MatterChatDocumentIntent.classify(
            "what do my documents say about indemnification?",
            folderNames: ["Research"]
        )
        XCTAssertEqual(intent, .content(folderHint: nil))
    }

    func testSummarizeFolderIsContentWithHint() {
        let intent = MatterChatDocumentIntent.classify(
            "summarize the documents in the Contracts folder",
            folderNames: ["Contracts", "Research"]
        )
        XCTAssertEqual(intent, .content(folderHint: "Contracts"))
    }

    func testPartyQuestionGroundsInMatterDocuments() {
        // The exact first-screenshot failure: a bare "who are the parties" must ground in
        // the matter's files (content path), not fall through to the model's memory.
        let intent = MatterChatDocumentIntent.classify(
            "Who are the parties in this action?", folderNames: ["Research"]
        )
        XCTAssertEqual(intent, .content(folderHint: nil))
    }

    func testCounselQuestionGroundsInMatterDocuments() {
        XCTAssertEqual(
            MatterChatDocumentIntent.classify("Who is counsel for McKernon Motors?", folderNames: []),
            .content(folderHint: nil)
        )
    }

    func testAttorneyContactQuestionGroundsInMatterDocuments() {
        XCTAssertEqual(
            MatterChatDocumentIntent.classify(
                "Name each of the attorneys, their email addresses, and phone numbers.",
                folderNames: []
            ),
            .content(folderHint: nil)
        )
    }

    func testOrdinaryEmailRequestIsNotGrounded() {
        // "rewrite this email" mentions email but is not a contact question — must NOT be
        // pulled into document retrieval.
        XCTAssertEqual(
            MatterChatDocumentIntent.classify("rewrite this email to be more formal", folderNames: []),
            MatterChatDocumentIntent.none
        )
    }

    func testGeneralLegalQuestionIsNotGrounded() {
        // Must NOT hijack legal research — this should flow to the normal/legal route.
        let intent = MatterChatDocumentIntent.classify(
            "what is the standard for summary judgment in Florida?",
            folderNames: ["Research"]
        )
        XCTAssertEqual(intent, MatterChatDocumentIntent.none)
    }

    func testResearchAsAVerbDoesNotTriggerFolder() {
        // "research" the verb must not be read as the "Research" folder when there's
        // no folder/collection reference.
        let intent = MatterChatDocumentIntent.classify(
            "research recent Florida cases on insurance bad faith",
            folderNames: ["Research"]
        )
        XCTAssertEqual(intent, MatterChatDocumentIntent.none)
    }

    func testDraftingRequestIsNotGrounded() {
        // "draft a document" mentions "document" but is not about the stored collection.
        let intent = MatterChatDocumentIntent.classify(
            "draft a document preservation letter to opposing counsel",
            folderNames: []
        )
        XCTAssertEqual(intent, MatterChatDocumentIntent.none)
    }

    func testDeadlineInThisMatterIsNotGrounded() {
        // "in this matter" alone must NOT hijack a general procedural question.
        let intent = MatterChatDocumentIntent.classify(
            "what's the deadline to respond to the motion in this matter?",
            folderNames: ["Research"]
        )
        XCTAssertEqual(intent, MatterChatDocumentIntent.none)
    }

    func testWhichDocumentsAreRequiredIsNotGrounded() {
        // A procedural "what documents are required" question is not about stored files.
        let intent = MatterChatDocumentIntent.classify(
            "what documents are required to remove a case to federal court?",
            folderNames: []
        )
        XCTAssertEqual(intent, MatterChatDocumentIntent.none)
    }

    // MARK: - performSend grounding

    func testMatterChatGroundsFolderInventoryInsteadOfFabricating() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        let research = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")
        _ = try insertDocument(store, matter.id, folderID: research.id, name: "Avatar Props. v. Gundel.pdf")
        _ = try insertDocument(store, matter.id, folderID: research.id, name: "Hernandez v. Crespo.pdf")
        // A document filed OUTSIDE the Research folder must not appear in a scoped list.
        _ = try insertDocument(store, matter.id, folderID: nil, name: "Misc note.pdf")

        let capture = RequestCapture()
        let stub = StubRuntimeClient { request in
            capture.record(request)
            return .events([.event(request, 1, .token, token: "ok"), .event(request, 2, .generationCompleted)])
        }
        let controller = GlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "provide a list of all cases located in the research folder of this matter",
            modelID: ModelID(),
            systemPrompt: "ORIGINAL-ROUTE-PROMPT",
            options: GenerationOptions()
        )

        let prompt = try XCTUnwrap(capture.lastPrompt)
        XCTAssertTrue(prompt.contains("DOCUMENT INVENTORY"), "grounded inventory prompt expected")
        XCTAssertTrue(prompt.contains("Avatar Props. v. Gundel.pdf"))
        XCTAssertTrue(prompt.contains("Hernandez v. Crespo.pdf"))
        XCTAssertFalse(prompt.contains("Misc note.pdf"), "a document outside the folder must not be listed")
        // The grounded system prompt (strict source contract) replaces the route prompt.
        let systemPrompt = try XCTUnwrap(capture.lastSystemPrompt)
        XCTAssertNotEqual(systemPrompt, "ORIGINAL-ROUTE-PROMPT")
        XCTAssertTrue(systemPrompt.contains("source-grounded"))
    }

    func testFolderInventoryIncludesSubfolderDocuments() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        let research = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")
        let depositions = try store.documentLibrary.createFolder(
            matterID: matter.id, name: "Depositions", parentFolderID: research.id
        )
        _ = try insertDocument(store, matter.id, folderID: research.id, name: "Top-level memo.pdf")
        _ = try insertDocument(store, matter.id, folderID: depositions.id, name: "Smith deposition.pdf")

        let capture = RequestCapture()
        let stub = StubRuntimeClient { request in
            capture.record(request)
            return .events([.event(request, 1, .generationCompleted)])
        }
        let controller = GlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "list all documents in the research folder",
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions()
        )

        let prompt = try XCTUnwrap(capture.lastPrompt)
        XCTAssertTrue(prompt.contains("Top-level memo.pdf"))
        XCTAssertTrue(prompt.contains("Smith deposition.pdf"), "documents in a sub-folder must be included")
    }

    func testEmptyResearchFolderReportsNoDocuments() async throws {
        // The reported scenario: the user's documents are at the matter root, the
        // Research folder is actually empty. The chat must say so, not invent a list.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        _ = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")
        _ = try insertDocument(store, matter.id, folderID: nil, name: "Avatar Props. v. Gundel.pdf")

        let capture = RequestCapture()
        let stub = StubRuntimeClient { request in
            capture.record(request)
            return .events([.event(request, 1, .generationCompleted)])
        }
        let controller = GlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "list all cases in the research folder",
            modelID: ModelID(),
            systemPrompt: nil,
            options: GenerationOptions()
        )

        let prompt = try XCTUnwrap(capture.lastPrompt)
        XCTAssertTrue(prompt.contains("(no documents)"), "empty folder must be reported as empty")
        XCTAssertTrue(prompt.contains("Research"))
    }

    func testGeneralQuestionInMatterChatIsNotGrounded() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        _ = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")

        let capture = RequestCapture()
        let stub = StubRuntimeClient { request in
            capture.record(request)
            return .events([.event(request, 1, .generationCompleted)])
        }
        let controller = GlobalChatController(
            store: store, runtimeClient: stub, scope: .matter(id: matter.id), embedder: nil
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What is the standard for summary judgment in Florida?",
            modelID: ModelID(),
            systemPrompt: "BASE",
            options: GenerationOptions()
        )

        let prompt = try XCTUnwrap(capture.lastPrompt)
        XCTAssertFalse(prompt.contains("DOCUMENT INVENTORY"), "a general legal question must not be document-grounded")
        XCTAssertEqual(prompt, "What is the standard for summary judgment in Florida?")
    }

    // MARK: - Helpers

    @discardableResult
    private func insertDocument(
        _ store: SupraStore, _ matterID: String, folderID: String?, name: String
    ) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: name, byteSize: 1, originalExtension: "pdf",
                managedRelativePath: "blobs/\(UUID().uuidString).pdf"
            )
        ).blob
        return try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: folderID, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroundingStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
