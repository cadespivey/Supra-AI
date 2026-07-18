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

        XCTAssertTrue(markdown.contains("Assurance: Propositions supported — completeness not assessed"))
        XCTAssertTrue(markdown.contains("Verify every citation against the source before relying on or sharing this."))
        XCTAssertTrue(fixture.controller.availableArtifactActions(messageID: fixture.message.id).isEmpty)
    }

    private struct Fixture {
        let store: SupraStore
        let storageRoot: URL
        let matter: MatterRecord
        let chat: ChatRecord
        let message: MessageRecord
        let sourceSet: DocumentSourceSetRecord
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
