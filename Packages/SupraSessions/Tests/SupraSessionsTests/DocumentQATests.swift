import Foundation
import SupraCore
import SupraDocuments
import SupraResearch
@testable import SupraSessions
import SupraStore
import XCTest

private final class SequencedDocumentAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]

    init(_ answers: [String]) { self.answers = answers }

    func next() -> String {
        lock.withLock {
            if answers.count > 1 { return answers.removeFirst() }
            return answers.first ?? ""
        }
    }
}

@MainActor
final class DocumentQATests: XCTestCase {

    func testRerankOrderPrefersModelLabelsThenBackfillsInRetrievalOrder() {
        let retrieval = (1...5).map { "S\($0)" } // S1…S5
        // Model prefers S3 then S1; the unknown S9 is ignored; the remaining slot is
        // backfilled in retrieval order (S2).
        XCTAssertEqual(
            DocumentQAController.rerankOrder(retrievalLabels: retrieval, preferred: ["S3", "S9", "S1"], limit: 3),
            ["S3", "S1", "S2"]
        )
    }

    func testRerankOrderFallsBackToRetrievalOrderWhenNoValidPreferred() {
        XCTAssertEqual(
            DocumentQAController.rerankOrder(retrievalLabels: ["S1", "S2", "S3"], preferred: [], limit: 2),
            ["S1", "S2"]
        )
    }

    func testParsePacketLabelsExtractsSLabels() {
        XCTAssertEqual(DocumentQAController.parsePacketLabels("Most relevant: S3, s1, S12."), ["S3", "S1", "S12"])
        XCTAssertTrue(DocumentQAController.parsePacketLabels("no labels here").isEmpty)
        // Digit-bearing words echoed from the question/excerpts must not yield labels.
        XCTAssertTrue(DocumentQAController.parsePacketLabels("Windows10 and class3 and FAS123").isEmpty)
    }

    func testAutoSourceQAGeneratesCitedAnswerSavedWithSourceSet() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024 by both parties.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "The agreement was signed on March 3, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was the agreement signed?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(result.citationLabels, ["S1"])
        XCTAssertFalse(result.unsupported)
        XCTAssertTrue(result.markdown.contains("## Sources"))

        // Saved as a documentQA structured output with an attached source set.
        let outputs = try store.structuredOutputs.fetchOutputs(matterID: matter.id)
        let output = try XCTUnwrap(outputs.first { $0.id == result.outputID })
        XCTAssertEqual(output.outputType, StructuredOutputType.documentQA.rawValue)
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.versionID)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.citationLabel, "S1")
        XCTAssertNotNil(sources.first?.chunkID)
    }

    func testTieredDepthPersistsOnSourceSetAndKeepsPreliminaryVersion() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024 by both parties.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "Signed March 3, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        // Default pass is the fast tier and records it on the source set.
        let generated = await qa.generate(question: "When was the agreement signed?", modelID: ModelID())
        let preliminary = try XCTUnwrap(generated)
        XCTAssertEqual(preliminary.depth, .fast)
        let fastSet = try store.documentSources.fetchSourceSet(structuredOutputVersionID: preliminary.versionID)
        XCTAssertEqual(fastSet?.retrievalDepth, RetrievalDepth.fast.rawValue)

        // "Search all documents" = regenerate at .deep: a NEW version (the
        // preliminary answer is retained) whose source set records the deep pass.
        let regenerated = await qa.regenerate(outputID: preliminary.outputID, modelID: ModelID())
        let deeper = try XCTUnwrap(regenerated)
        XCTAssertEqual(deeper.depth, .deep)
        XCTAssertNotEqual(deeper.versionID, preliminary.versionID, "the preliminary version is never discarded")
        let deepSet = try store.documentSources.fetchSourceSet(structuredOutputVersionID: deeper.versionID)
        XCTAssertEqual(deepSet?.retrievalDepth, RetrievalDepth.deep.rawValue)
    }

    func testUnsupportedQuestionDoesNotInventAnswer() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "note.txt", "The deposition discussed the wire transfer schedule.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "The provided sources do not support an answer to this question."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)
        let generated = await qa.generate(question: "What is the indemnification cap?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertTrue(result.unsupported)
        // A refusal based on a retrieved subset cannot prove absence across the
        // selected scope, so WP0-05 records it as review-required rather than
        // manufacturing clean support evidence.
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
    }

    func testDocumentQAUsesStructuredOutputRouteOptionsAndPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The agreement required notice by May 1, 2024.")

        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertEqual(request.options.preset, .legalResearch)
            XCTAssertFalse(request.systemPrompt?.contains("legal authorities") ?? true)
            XCTAssertTrue(request.systemPrompt?.contains("legal document analysis assistant") ?? false)
            return .events([
                .event(request, 0, .token, token: "Notice was required by May 1, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was notice required?", modelID: ModelID())

        XCTAssertNotNil(generated)
    }

    func testMissingCitationsMarkNeedsReview() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "a.txt", "Damages were assessed at fifty thousand dollars.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "Damages were fifty thousand dollars."), // no citation
                .event(request, 1, .generationCompleted)
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)
        let generated = await qa.generate(question: "What were the damages?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(result.warnings.contains { $0.contains("no inline citations") })
    }

    func testGeneratingBlockedWhenScopeNotIndexed() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        // Insert a doc but do NOT index it.
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "z", byteSize: 1, originalExtension: "txt", managedRelativePath: "b/z.txt")).blob
        _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "x.txt", status: MatterDocumentStatus.extracting.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue))

        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: StubRuntimeClient(), embedder: nil)
        let result = await qa.generate(question: "anything?", modelID: ModelID())
        XCTAssertNil(result)
        XCTAssertNotNil(qa.message)
    }

    func testFastGroundedChatOffersDeeperSearchAndDeepPassClearsIt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        try await indexDoc(store, matter.id, "agreement.txt", "The service agreement was signed on March 3, 2024 by both parties.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "Signed March 3, 2024 [S1]."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = makeGlobalChatController(store: store, runtimeClient: runtime, scope: .matter(id: matter.id))
        controller.loadChats()
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .generalQA)

        // A fast (default) grounded answer offers the deep pass for the same question.
        await controller.performSend(
            prompt: "What do my documents say about the agreement?",
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route
        )
        let offer = try XCTUnwrap(controller.deeperSearchOffer)
        XCTAssertEqual(offer.question, "What do my documents say about the agreement?")

        // Running the deep pass answers again and retires the offer.
        await controller.performSend(
            prompt: offer.question,
            modelID: ModelID(), systemPrompt: route.systemPrompt, options: route.options, route: route,
            documentDepth: .deep
        )
        XCTAssertNil(controller.deeperSearchOffer)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testUnrelatedResolvedCitationPersistsNeedsReviewProvenance() async throws {
        // ACR-DOCSUP-INT-01 expected RED: the label-only path persists this as complete
        // and leaves the v055 verification columns in legacy_unverified state.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(
            store,
            matter.id,
            "payment-correspondence.txt",
            "Payment correspondence concerned account setup. The deposition occurred July 12, 2025."
        )
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "Payment was due March 3, 2025 [S1]."),
                .event(request, 1, .generationCompleted),
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was payment due?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)

        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first { $0.id == result.outputID })
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).first)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertEqual(version.verificationVersion, DocumentSupportVerifier.version)
        let json = try XCTUnwrap(version.verificationJSON)
        let support = try DateCoding.decoder.decode([PropositionSupportResult].self, from: Data(json.utf8))
        XCTAssertEqual(support.map(\.status), [.unsupported])
        XCTAssertNotNil(try store.documentSources.fetchSourceSet(structuredOutputVersionID: version.id))
    }

    func testRegenerationReverifiesAndPersistsEachVersionsOwnSourceSet() async throws {
        // ACR-DOCSUP-INT-02 expected RED: regeneration updates status separately and
        // stores neither verifier provenance nor transactional source attachment.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(store, matter.id, "agreement.txt", "The agreement was executed March 3, 2025.")
        let answers = SequencedDocumentAnswers([
            "The agreement was executed March 3, 2025 [S1].",
            "The agreement was executed March 9, 2025 [S1].",
        ])
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: answers.next()),
                .event(request, 1, .generationCompleted),
            ])
        })
        let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was the agreement executed?", modelID: ModelID())
        let first = try XCTUnwrap(generated)
        let regenerated = await qa.regenerate(outputID: first.outputID, modelID: ModelID())
        let second = try XCTUnwrap(regenerated)
        XCTAssertEqual(first.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(second.status, StructuredOutputStatus.needsReview.rawValue)

        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: first.outputID)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(Set(versions.map(\.verificationStatus)), Set([
            OutputVerificationStatus.allSupported.rawValue,
            OutputVerificationStatus.needsReview.rawValue,
        ]))
        for version in versions {
            XCTAssertNotNil(version.verificationJSON)
            XCTAssertNotNil(try store.documentSources.fetchSourceSet(structuredOutputVersionID: version.id))
        }
    }

    func testTwoMatterCanariesStayOutOfPromptVerificationAndPersistedSources() async throws {
        // ACR-DOCSUP-INT-03 expected RED: no persisted verifier input/provenance exists
        // to prove that the selected matter alone supported the clean decision.
        let store = try makeStore()
        let selectedMatter = try store.matters.createMatter(name: "Synthetic Matter Alpha")
        let otherMatter = try store.matters.createMatter(name: "Synthetic Matter Omega")
        try await indexDoc(
            store,
            selectedMatter.id,
            "alpha.txt",
            "ALPHA_CANARY. Payment was due March 3, 2025."
        )
        try await indexDoc(
            store,
            otherMatter.id,
            "omega.txt",
            "OMEGA_CANARY. Payment was due December 31, 2099."
        )
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertTrue(request.prompt.contains("ALPHA_CANARY"))
            XCTAssertFalse(request.prompt.contains("OMEGA_CANARY"))
            return .events([
                .event(request, 0, .token, token: "Payment was due March 3, 2025 [S1]."),
                .event(request, 1, .generationCompleted),
            ])
        })
        let qa = DocumentQAController(matterID: selectedMatter.id, store: store, runtimeClient: runtime, embedder: nil)

        let generated = await qa.generate(question: "When was payment due?", modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first)
        let verificationJSON = try XCTUnwrap(version.verificationJSON)
        XCTAssertFalse(verificationJSON.contains("OMEGA_CANARY"))
        let evidence = try DateCoding.decoder.decode([PropositionSupportResult].self, from: Data(verificationJSON.utf8))
            .flatMap(\.evidence)
        XCTAssertTrue(evidence.allSatisfy { $0.sourceID.contains(selectedMatter.id) })
        XCTAssertFalse(evidence.contains { $0.sourceID.contains(otherMatter.id) })

        let selectedDocumentIDs = Set(try store.documentLibrary.fetchDocuments(matterID: selectedMatter.id).map(\.id))
        let persistedSources = try store.documentSources.fetchSources(structuredOutputVersionID: version.id)
        XCTAssertFalse(persistedSources.isEmpty)
        XCTAssertTrue(persistedSources.allSatisfy { row in
            row.documentID.map(selectedDocumentIDs.contains) ?? false
        })
    }

    func testDocumentScopedStructuredOutputCompletesOnlyWithTransactionalSupportProvenance() async throws {
        // ACR-DOCSUP-INT-06 expected RED: document-scoped structured outputs used
        // section presence alone and attached their source set after version commit.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(store, matter.id, "agreement.txt", "Payment was due March 3, 2025.")
        let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: .draftingSkeleton))
        let markdown = contract.requiredHeadings
            .map { "\($0)\n\nPayment was due March 3, 2025 [S1]." }
            .joined(separator: "\n\n")
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertTrue(request.prompt.contains("BEGIN_UNTRUSTED_SOURCE_DATA"))
            return .events([
                .event(request, 0, .token, token: markdown),
                .event(request, 1, .generationCompleted),
            ])
        })
        let controller = StructuredOutputController(
            store: store,
            runtimeClient: runtime,
            matterID: matter.id,
            embedder: nil
        )

        let created = await controller.createOutput(
            type: .draftingSkeleton,
            context: "payment due date",
            scope: .wholeMatter,
            modelID: ModelID()
        )
        XCTAssertTrue(created)
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).first)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(version.verificationVersion, DocumentSupportVerifier.version)
        XCTAssertNotNil(version.verificationJSON)
        XCTAssertNotNil(try store.documentSources.fetchSourceSet(structuredOutputVersionID: version.id))
    }

    func testDocumentScopedStructuredRepairReverifiesAndCannotCleanUnsupportedClaim() async throws {
        // ACR-DOCSUP-INT-07 expected RED: structure repair previously reused section
        // status, did not re-offer a bounded source packet, and could mark unsupported
        // repaired prose complete without provenance.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(store, matter.id, "agreement.txt", "Payment was due March 3, 2025.")
        let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: .draftingSkeleton))
        let partial = contract.requiredHeadings.dropLast()
            .map { "\($0)\n\nPayment was due March 3, 2025 [S1]." }
            .joined(separator: "\n\n")
        let repaired = contract.requiredHeadings.enumerated()
            .map { index, heading in
                index == contract.requiredHeadings.count - 1
                    ? "\(heading)\n\nPayment was due March 9, 2025 [S1]."
                    : "\(heading)\n\nPayment was due March 3, 2025 [S1]."
            }
            .joined(separator: "\n\n")
        let answers = SequencedDocumentAnswers([partial, repaired])
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertTrue(request.prompt.contains("BEGIN_UNTRUSTED_SOURCE_DATA"))
            return .events([
                .event(request, 0, .token, token: answers.next()),
                .event(request, 1, .generationCompleted),
            ])
        })
        let controller = StructuredOutputController(store: store, runtimeClient: runtime, matterID: matter.id)

        let created = await controller.createOutput(
            type: .draftingSkeleton,
            context: "payment due date",
            scope: .wholeMatter,
            modelID: ModelID()
        )
        XCTAssertTrue(created)
        let output = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: output.id)
        XCTAssertEqual(versions.count, 2)
        let active = try XCTUnwrap(versions.first { $0.id == output.activeVersionID })
        XCTAssertEqual(active.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertTrue(active.contentMarkdown.contains("DOCUMENT SUPPORT NEEDS REVIEW"))
        XCTAssertNotNil(try store.documentSources.fetchSourceSet(structuredOutputVersionID: active.id))
    }

    // MARK: - Helpers

    private func indexDoc(_ store: SupraStore, _ matterID: String, _ name: String, _ text: String) async throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name)")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])
        // Index text-only (no embedder) so the scope is ready for FTS retrieval.
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: doc.id)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QAStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
