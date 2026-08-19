import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class MatterChatQuoteCheckerTests: XCTestCase {
    private func source(_ label: String = "S1", excerpt: String) -> ProvidedDocumentSource {
        ProvidedDocumentSource(id: "row-\(label)", label: label, documentID: "document-\(label)", documentName: "Synthetic document", locator: DocumentSourceLocator(sourceKind: .text), excerpt: excerpt)
    }

    func testStraightQuotedPassageMatchesRetainedExcerpt() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "The agreement says \"Payment is due May 1\" [S1].", providedSources: [source(excerpt: "Notice: Payment is due May 1 under section 4.")]).isEmpty)
    }

    func testCurlyQuotedPassageMatchesRetainedExcerpt() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "It provides “Written notice is required” [S1].", providedSources: [source(excerpt: "Written notice is required before termination.")]).isEmpty)
    }

    func testCanonicalUnicodeNormalizationMatches() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "The record states \"Café\" [S1].", providedSources: [source(excerpt: "Cafe\u{301} operations are seasonal.")]).isEmpty)
    }

    func testContiguousWhitespaceNormalizationMatches() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "The clause says \"notice   is\nrequired\" [S1].", providedSources: [source(excerpt: "notice\tis required before filing")]).isEmpty)
    }

    func testMismatchUsesExactWarningWording() {
        XCTAssertEqual(MatterChatQuoteChecker.warnings(in: "It says \"Payment is immediate\" [S1].", providedSources: [source(excerpt: "Payment is due May 1.")]).map(\.message), ["This quotation could not be matched in the retained source excerpt."])
    }

    func testUnknownSourceLabelIsUnresolved() {
        XCTAssertEqual(MatterChatQuoteChecker.warnings(in: "It says \"Payment is immediate\" [S9].", providedSources: [source(excerpt: "Payment is due May 1.")]).map(\.message), ["This quotation's source label could not be resolved from the retained source excerpts."])
    }

    func testUncitedAndNonSourceQuoteShapesAreIgnored() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "\"Uncited quote\". \"Authority quote\" [A1]. \"Footnote quote\" [1].", providedSources: [source(excerpt: "Different retained source.")]).isEmpty)
    }

    func testQuotedShapesInsideFencedCodeAreIgnored() {
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: "```swift\nlet sample = \"not a quotation\" [S1]\n```", providedSources: [source(excerpt: "Different retained source.")]).isEmpty)
    }

    func testCodeBlocksCannotSynthesizeAQuotedCitationAcrossTheirRemovedContent() {
        let source = source(excerpt: "Different retained source.")
        for answer in [
            "\"not a quotation\n```swift\nlet ignored = true\n```\n\" [S1]",
            "\"not a quotation\n~~~swift\nlet ignored = true\n~~~\n\" [S1]",
            "\"not a quotation\n    let ignored = true\n\" [S1]",
        ] {
            XCTAssertTrue(
                MatterChatQuoteChecker.warnings(in: answer, providedSources: [source]).isEmpty,
                "code must remain a boundary, not make two surrounding fragments adjacent: \(answer)"
            )
        }
    }

    func testQuoteCannotOpenBeforeAndCloseAfterAFencedCodeBlock() {
        let answer = "\"not a quotation\n```\nignored\n```\nstill not a quotation\" [S1]"
        XCTAssertTrue(MatterChatQuoteChecker.warnings(in: answer, providedSources: [source(excerpt: "Different retained source.")]).isEmpty)
    }

    func testExactlyOneImmediateSourceLabelIsRequired() {
        let source = source(excerpt: "Different retained source.")
        for answer in [
            "\"not a quotation\" [S1] [S2]",
            "\"not a quotation\" [S1][S2]",
            "\"not a quotation\" [S1a]",
        ] {
            XCTAssertTrue(MatterChatQuoteChecker.warnings(in: answer, providedSources: [source]).isEmpty, answer)
        }
    }

    func testWarningIDsAreUniqueAndStableInAnswerOrder() {
        let answer = "\"First mismatch\" [S1]. \"Second mismatch\" [S1]. \"Unknown\" [S9]."
        let sources = [source(excerpt: "Different retained source.")]
        let initial = MatterChatQuoteChecker.warnings(in: answer, providedSources: sources)
        XCTAssertEqual(initial.map(\.id), ["quote-check-S1-1", "quote-check-S1-2", "quote-check-S9-3"])
        XCTAssertEqual(initial, MatterChatQuoteChecker.warnings(in: answer, providedSources: sources))
    }

    func testMatterWarningIsAdvisoryAtCompletionAndReload() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Quote advisory matter")
        try await indexDocument(store, matterID: matter.id, text: "Written notice is due no later than May 1.")
        let answer = "The notice states \"Payment is due immediately.\" [S1]."
        let runtime = StubRuntimeClient { request in .events([.event(request, 1, .token, token: answer), .event(request, 2, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(prompt: "What do my documents say about written notice?", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        let completed = try XCTUnwrap(controller.messages.last)
        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(messageID: completed.id))
        XCTAssertFalse(try store.documentSources.fetchSources(sourceSetID: sourceSet.id).isEmpty, "precondition: retained packet rows must exist before hydration is interpreted")
        XCTAssertEqual(completed.content, answer, "the advisory must not mutate answer bytes")
        XCTAssertEqual(completed.status, .completed, "the advisory must not block completion")
        XCTAssertEqual(completed.quoteWarnings.map(\.message), ["This quotation could not be matched in the retained source excerpt."])

        let reopened = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        reopened.loadChats()
        let reloaded = try XCTUnwrap(reopened.messages.last)
        XCTAssertEqual(reloaded.content, answer, "reload must preserve answer bytes")
        XCTAssertEqual(reloaded.status, .completed)
        XCTAssertEqual(reloaded.quoteWarnings, completed.quoteWarnings, "reload reconstructs the advisory from persisted content and packet rows")
    }

    func testGlobalChatDoesNotProduceQuoteWarnings() async throws {
        let store = try makeStore()
        let answer = "A global answer says \"Payment is immediate\" [S1]."
        let runtime = StubRuntimeClient { request in .events([.event(request, 1, .token, token: answer), .event(request, 2, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .global)
        controller.loadChats()
        await controller.performSend(prompt: "Answer generally", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())
        let completed = try XCTUnwrap(controller.messages.last)
        XCTAssertEqual(completed.content, answer)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertTrue(completed.quoteWarnings.isEmpty, "global chat is outside the matter quote-check scope")
    }

    func testVisibleAnswerAloneDrivesQuoteWarningsAtCompletionAndReload() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Visible quote answer matter")
        try await indexDocument(store, matterID: matter.id, text: "The visible quotation is retained exactly.")
        let answer = "<think>\"Hidden mismatch\" [S1]</think>"
            + "Folded preamble \"Folded mismatch\" [S1]\n"
            + "Answer: \"The visible quotation is retained exactly.\" [S1]\n\n---\n\n"
            + SupportNoticeContent.documentSupportHeading + "\n\"Notice mismatch\" [S1]"
        let runtime = StubRuntimeClient { request in .events([.event(request, 1, .token, token: answer), .event(request, 2, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(prompt: "What do my documents say about the visible quotation?", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        let completed = try XCTUnwrap(controller.messages.last)
        XCTAssertEqual(completed.content, answer, "quote checking must not alter persisted bytes")
        XCTAssertTrue(completed.quoteWarnings.isEmpty, "reasoning, folded preamble, and notice are not displayed answer text")

        let reopened = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        reopened.loadChats()
        XCTAssertEqual(reopened.messages.last?.quoteWarnings, completed.quoteWarnings)
    }

    func testSourceFreeMatterAnswerWarnsForUnresolvedLabelAtCompletionAndReload() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Source-free quote answer matter")
        let answer = "The answer says \"An unresolved quotation\" [S9]."
        let runtime = StubRuntimeClient { request in .events([.event(request, 1, .token, token: answer), .event(request, 2, .generationCompleted)]) }
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        controller.loadChats()

        await controller.performSend(prompt: "Give a general answer", modelID: ModelID(), systemPrompt: nil, options: GenerationOptions())

        let completed = try XCTUnwrap(controller.messages.last)
        XCTAssertEqual(completed.content, answer)
        XCTAssertEqual(completed.quoteWarnings.map(\.message), [MatterChatQuoteChecker.unresolvedSourceMessage])
        let reopened = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id), embedder: nil)
        reopened.loadChats()
        XCTAssertEqual(reopened.messages.last?.quoteWarnings, completed.quoteWarnings)
    }

    private func makeStore() throws -> SupraStore {
        try SupraStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("quote-check-\(UUID().uuidString).sqlite"))
    }

    private func indexDocument(_ store: SupraStore, matterID: String, text: String) async throws {
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matterID, blobID: try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: UUID().uuidString, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/quote-check.txt")).blob.id, displayName: "notice.txt", status: MatterDocumentStatus.indexing.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue, sourceKind: DocumentSourceKind.text.rawValue, extractionMethod: "synthetic", extractedTextChecksum: "quote-check", pagePartCount: 1))
        let revision = DocumentPartRevisionRecord(documentID: document.id, partIndex: 0, derivationKey: "quote-check-\(document.id)", origin: "parser", method: "synthetic", text: text, charCount: text.count, toolchainVersion: "quote-check")
        let selection = DocumentPartSelectionRecord(documentID: document.id, partIndex: 0, selectedRevisionID: revision.id, selectionKey: "quote-check-\(document.id)", selectedBy: "system", policyVersion: 1, decisionJSON: #"{"rule":"synthetic"}"#)
        _ = try store.documentRevisions.replacePartsAndPersistLineage(documentID: document.id, parts: [DocumentPagePartRecord(documentID: document.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)], revisions: [revision], selections: [selection])
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: document.id)
    }
}
