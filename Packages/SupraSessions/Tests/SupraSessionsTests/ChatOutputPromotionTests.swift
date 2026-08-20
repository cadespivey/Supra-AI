import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraRuntimeClient
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class ChatOutputPromotionTests: XCTestCase {
    func testTUX04PromotionAtomicallyRetainsMessagePacketVerificationAndAssurance() throws {
        // T-UX-04 expected RED: grounded messages have persisted source packets,
        // but no per-message promotion transaction or message artifact action.
        let fixture = try makeFixture(depth: .deep)

        XCTAssertEqual(
            fixture.controller.availableArtifactActions(messageID: fixture.message.id),
            [.saveToOutputs]
        )
        let outputID = try XCTUnwrap(
            fixture.controller.saveToOutputs(messageID: fixture.message.id)
        )

        let output = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == outputID }
        )
        let version = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchVersion(id: try XCTUnwrap(output.activeVersionID))
        )
        let attached = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(messageID: fixture.message.id)
        )
        let sources = try fixture.store.documentSources.fetchSources(sourceSetID: attached.id)

        XCTAssertEqual(output.chatID, fixture.chat.id)
        XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertEqual(version.contentMarkdown, fixture.message.content)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(version.assuranceState, OutputAssuranceState.propositionSupported.rawValue)
        XCTAssertEqual(attached.id, fixture.sourceSet.id)
        XCTAssertEqual(attached.messageID, fixture.message.id)
        XCTAssertEqual(attached.status, DocumentSourceSetStatus.attached.rawValue)
        XCTAssertEqual(attached.structuredOutputVersionID, version.id)
        XCTAssertEqual(sources.map(\.revisionID), [fixture.revision.id])
        XCTAssertTrue(sources.allSatisfy { $0.structuredOutputVersionID == version.id })
        XCTAssertEqual(sources.map(\.warningsJSON), [fixture.verificationJSON])
        XCTAssertTrue(fixture.controller.availableArtifactActions(messageID: fixture.message.id).isEmpty)
    }

    func testTUX04InjectedFailureAfterVersionInsertRollsBackEveryPromotionRow() throws {
        // T-UX-04 expected RED: creating an output and attaching the existing chat
        // packet are separate writes, so a post-version failure can leave residue.
        let fixture = try makeFixture(depth: .deep)
        try fixture.store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER tux04_fail_packet_attach
                BEFORE UPDATE OF structured_output_version_id ON document_source_sets
                BEGIN
                    SELECT RAISE(ABORT, 'TUX04 injected after-version failure');
                END
                """)
        }

        XCTAssertNil(fixture.controller.saveToOutputs(messageID: fixture.message.id))

        XCTAssertTrue(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id).isEmpty
        )
        let versionCount = try fixture.store.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM structured_output_versions") ?? -1
        }
        XCTAssertEqual(versionCount, 0)
        let packet = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(messageID: fixture.message.id)
        )
        let sources = try fixture.store.documentSources.fetchSources(sourceSetID: packet.id)
        XCTAssertEqual(packet.status, DocumentSourceSetStatus.pending.rawValue)
        XCTAssertNil(packet.structuredOutputVersionID)
        XCTAssertEqual(packet.messageID, fixture.message.id)
        XCTAssertTrue(sources.allSatisfy { $0.structuredOutputVersionID == nil })
        XCTAssertEqual(
            fixture.controller.availableArtifactActions(messageID: fixture.message.id),
            [.saveToOutputs]
        )
    }

    func testTUX05PromotedArtifactUsesOrdinaryExportGateAndUnpromotedMessageHasNoExportAction() throws {
        // T-UX-05 expected RED: chat has no promotion action, so export parity and
        // the exact absence of a per-message export path cannot be established.
        let fixture = try makeFixture(depth: .deep)
        let actionIDs = fixture.controller
            .availableArtifactActions(messageID: fixture.message.id)
            .map(\.rawValue)
        XCTAssertEqual(actionIDs, ["save_to_outputs"])
        XCTAssertFalse(actionIDs.contains("export"), "unpromoted chat messages must not expose export")

        let outputID = try XCTUnwrap(
            fixture.controller.saveToOutputs(messageID: fixture.message.id)
        )
        let exportURL = try DocumentExportService(
            store: fixture.store,
            storage: DocumentStorage(root: fixture.storageRoot)
        ).export(
            matterID: fixture.matter.id,
            structuredOutputID: outputID,
            format: .markdown
        )
        let markdown = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Assurance: Supported by selected sources — not exhaustive"))
        XCTAssertTrue(markdown.contains("Verify every citation against the source before relying on or sharing this."))
        XCTAssertTrue(fixture.controller.availableArtifactActions(messageID: fixture.message.id).isEmpty)
    }

    func testReloadHydratesProvidedSourcesSeparatelyFromInlineCitations() throws {
        let fixture = try makeFixture(depth: .fast)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot.deletingLastPathComponent()) }

        let reloaded = fixture.controller.messages.first { $0.id == fixture.message.id }
        let message = try XCTUnwrap(reloaded)
        XCTAssertEqual(message.providedSources.count, 1)
        let source = try XCTUnwrap(message.providedSources.first)

        XCTAssertFalse(source.id.isEmpty, "the retained source-row ID is stable and view-facing")
        XCTAssertEqual(source.label, "S1")
        XCTAssertEqual(source.documentID, fixture.documentID)
        XCTAssertEqual(source.documentName, "notice-agreement.txt")
        XCTAssertEqual(source.locator?.charStart, 0)
        XCTAssertEqual(source.locator?.charEnd, fixture.revision.text.count)
        XCTAssertEqual(source.excerpt, fixture.revision.text)
        XCTAssertTrue(message.citations.isEmpty, "an uncited retained packet must not synthesize inline citations")
    }

    func testReloadLeavesProvidedSourcesEmptyWithoutAPacketAndFallsBackForDeletedDocument() throws {
        let fixture = try makeFixture(depth: .fast)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot.deletingLastPathComponent()) }
        let uncited = try completedAssistantMessage(store: fixture.store, chatID: fixture.chat.id, content: "No packet.")
        try fixture.store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: fixture.sourceSet.id,
            documentID: nil,
            citationLabel: "S2",
            locatorJSON: "not valid locator JSON",
            excerpt: "Retained fallback excerpt.",
            rank: 1
        ))
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET deleted_at = ? WHERE id = ?",
                arguments: [Date(), fixture.documentID]
            )
        }

        fixture.controller.loadChats()

        let packetMessage = try XCTUnwrap(fixture.controller.messages.first { $0.id == fixture.message.id })
        let missingPacket = try XCTUnwrap(fixture.controller.messages.first { $0.id == uncited.id })
        XCTAssertEqual(packetMessage.providedSources.map(\.label), ["S1", "S2"])
        XCTAssertEqual(packetMessage.providedSources.first?.documentName, "Document unavailable")
        XCTAssertEqual(packetMessage.providedSources.last?.documentName, "Document unavailable")
        XCTAssertNil(packetMessage.providedSources.last?.documentID)
        XCTAssertNil(packetMessage.providedSources.last?.locator)
        XCTAssertEqual(packetMessage.providedSources.last?.excerpt, "Retained fallback excerpt.")
        XCTAssertTrue(missingPacket.providedSources.isEmpty)
        XCTAssertTrue(missingPacket.citations.isEmpty)
    }

    func testProvidedSourcePreviewUsesTheRecordedRevisionRatherThanCurrentDocumentState() throws {
        let fixture = try makeFixture(depth: .fast)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot.deletingLastPathComponent()) }
        try fixture.store.documentIndex.replaceParts(documentID: fixture.documentID, parts: [
            DocumentPagePartRecord(
                documentID: fixture.documentID,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: "CURRENT CORRECTED NOTICE TEXT",
                charCount: 29
            ),
        ])
        let source = try XCTUnwrap(fixture.controller.messages.first?.providedSources.first)

        let preview = fixture.controller.providedSourcePreview(outputSourceID: source.id)

        XCTAssertEqual(preview.revisionID, fixture.revision.id)
        if case let .text(content, _, _) = preview.kind {
            XCTAssertEqual(content, fixture.revision.text)
            XCTAssertFalse(content.contains("CURRENT CORRECTED"))
        } else {
            XCTFail("expected the recorded source revision, got \(preview.kind)")
        }

        let unavailable = fixture.controller.providedSourcePreview(outputSourceID: "missing-source-row")
        if case .unavailable = unavailable.kind {} else {
            XCTFail("missing retained source row should be gracefully unavailable")
        }
    }

    private struct Fixture {
        let store: SupraStore
        let storageRoot: URL
        let matter: MatterRecord
        let chat: ChatRecord
        let message: MessageRecord
        let sourceSet: DocumentSourceSetRecord
        let documentID: String
        let revision: DocumentPartRevisionRecord
        let verificationJSON: String
        let controller: GlobalChatController
    }

    private func makeFixture(depth: RetrievalDepth) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatOutputPromotion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Synthetic promoted answer")
        let chat = try store.chats.createMatterChat(matterID: matter.id, title: "Promotion source chat")
        let message = try completedAssistantMessage(
            store: store,
            chatID: chat.id,
            content: "The synthetic agreement requires notice by May 1, 2025 [S1]."
        )
        let document = try seededDocument(store: store, matterID: matter.id)
        let locator = DocumentSourceLocator(
            sourceKind: .text,
            charStart: 0,
            charEnd: document.revision.text.count
        ).encodedJSON()
        let support = try PropositionSupportResult(
            propositionID: "tux04-proposition",
            status: .supported,
            reasons: [],
            evidence: [SupportEvidence(
                sourceID: "\(matter.id)/synthetic-chunk",
                sourceLabel: "S1",
                locator: locator,
                retainedExcerpt: document.revision.text,
                verifierName: "ChatOutputPromotionTests",
                verifierVersion: "tux04"
            )],
            timestamp: Date(timeIntervalSinceReferenceDate: 404)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let verificationJSON = try XCTUnwrap(
            String(data: encoder.encode([support]), encoding: .utf8)
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            scopeJSON: #"{"documentIDs":["TUX04-NONDEFAULT"]}"#,
            retrievalQuery: "When is notice due?",
            retrievalDepth: depth.rawValue,
            packingReportJSON: #"{"candidates":[],"packedSourceIDs":[]}"#,
            embeddingModelID: "synthetic/promotion-embed",
            embeddingModelRevision: "promotion-revision-v7",
            chunkerVersion: 2,
            retrievalConfigJSON: #"{"depth":"deep","limit":12}"#,
            corpusSnapshotHash: "tux04-corpus-snapshot",
            messageID: message.id
        )
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.record.id,
            revisionID: document.revision.id,
            citationLabel: "S1",
            locatorJSON: locator,
            excerpt: document.revision.text,
            rank: 0,
            warningsJSON: verificationJSON
        ))
        let controller = GlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient(outcome: { _ in
                .reject(NSError(domain: "ChatOutputPromotionTests", code: 1))
            }),
            scope: .matter(id: matter.id)
        )
        controller.loadChats()
        return Fixture(
            store: store,
            storageRoot: root.appendingPathComponent("Managed", isDirectory: true),
            matter: matter,
            chat: chat,
            message: message,
            sourceSet: sourceSet,
            documentID: document.record.id,
            revision: document.revision,
            verificationJSON: verificationJSON,
            controller: controller
        )
    }

    private func completedAssistantMessage(
        store: SupraStore,
        chatID: String,
        content: String
    ) throws -> MessageRecord {
        let shell = try store.chats.createAssistantMessageShell(chatID: chatID)
        let variant = try store.chats.createVariant(messageID: shell.id, generationSessionID: nil)
        try store.chats.appendToken(to: variant.id, token: content)
        try store.chats.completeVariant(variant.id)
        return try XCTUnwrap(
            store.chats.fetchMessages(chatID: chatID).first { $0.id == shell.id }
        )
    }

    private func seededDocument(
        store: SupraStore,
        matterID: String
    ) throws -> (record: MatterDocumentRecord, revision: DocumentPartRevisionRecord) {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "tux04-\(UUID().uuidString)",
            byteSize: 64,
            originalExtension: "txt",
            managedRelativePath: "blobs/tux04.txt"
        )).blob
        let record = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: "notice-agreement.txt"
        ))
        let text = "The synthetic agreement requires notice by May 1, 2025."
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: record.id,
            partIndex: 0,
            derivationKey: "tux04-recorded-revision",
            origin: "parser",
            method: "synthetic",
            text: text,
            charCount: text.count
        ))
        return (record, revision)
    }
}
