import Foundation
import GRDB
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// T-PUB-CHAT-02 — the aggregate created by the actual chat controller must be
/// a Store-owned, content-free exact-retry identity. Replaying the controller's
/// persisted aggregate returns the same receipt without another write; changing
/// even the terminal answer rejects without changing the completed public output.
///
/// Expected RED: the current `GlobalChatController` path never calls
/// `groundedChatPublications.finalize`, so it produces no idempotency receipt,
/// terminal verification dimensions, authorization evidence, or atomic audit to
/// reconstruct. The first receipt unwrap therefore fails with the legacy path.
@MainActor
final class ArchitectureUXTPubChat02Tests: XCTestCase {
    func testTPUBCHAT02ControllerAggregateExactRetryIsIdempotentAndAlteredRetryRejects() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "exact-retry")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.alteredAnswerText))
        XCTAssertFalse(assistant.content.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        XCTAssertEqual(assistant.citations.map(\.label), ["S1"])
        XCTAssertEqual(assistant.assuranceState, .preliminary)

        let firstReceipt = try XCTUnwrap(
            try architectureUXPubChatReceipt(store: fixture.store, messageID: assistant.id)
        )
        XCTAssertEqual(firstReceipt.matterID, fixture.matter.id)
        XCTAssertEqual(firstReceipt.chatID, controller.selectedChatID)
        XCTAssertEqual(firstReceipt.messageID, assistant.id)
        XCTAssertEqual(firstReceipt.assuranceState, .preliminary)
        XCTAssertEqual(firstReceipt.aggregateDigestSHA256.count, 64)
        XCTAssertTrue(firstReceipt.verificationDimensions.isComplete)
        XCTAssertEqual(
            firstReceipt.verificationDimensions.result(for: .citationResolution).status,
            .satisfied
        )
        XCTAssertNotEqual(
            firstReceipt.verificationDimensions.result(for: .propositionSupport).status,
            .notRun
        )
        XCTAssertNotEqual(
            firstReceipt.verificationDimensions.result(for: .criticalValueFidelity).status,
            .notRun
        )
        XCTAssertFalse(firstReceipt.idempotencyKey.isEmpty)
        XCTAssertFalse(firstReceipt.idempotencyKey.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(firstReceipt.idempotencyKey.contains(ArchitectureUXPubChatWire.sourceBody))
        XCTAssertFalse(firstReceipt.idempotencyKey.contains(ArchitectureUXPubChatWire.documentName))
        XCTAssertFalse(firstReceipt.idempotencyKey.contains(ArchitectureUXPubChatWire.forbiddenDefault))
        XCTAssertFalse(firstReceipt.aggregateDigestSHA256.contains(ArchitectureUXPubChatWire.forbiddenDefault))

        let authorization = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(firstReceipt.authorizationEvidenceJSON.utf8)
            ) as? [String: String]
        )
        XCTAssertEqual(authorization["basis"], "local_matter_documents")
        XCTAssertNotEqual(authorization["policy_version"], ArchitectureUXPubChatWire.forbiddenDefault)
        XCTAssertFalse((authorization["policy_version"] ?? "").isEmpty)
        XCTAssertFalse(firstReceipt.authorizationEvidenceJSON.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(firstReceipt.authorizationEvidenceJSON.contains(ArchitectureUXPubChatWire.sourceBody))

        let exactCommand = try reconstructArchitectureUXPubChatCommand(
            store: fixture.store,
            receipt: firstReceipt
        )
        XCTAssertEqual(exactCommand.runtimeMetrics.loadTimeMs, 317)
        XCTAssertEqual(exactCommand.runtimeMetrics.firstTokenLatencyMs, 419)
        XCTAssertEqual(exactCommand.runtimeMetrics.tokensPerSecond, 23.75)
        XCTAssertEqual(exactCommand.runtimeMetrics.peakMemoryMb, 1_927)
        XCTAssertEqual(exactCommand.runtimeMetrics.generatedTokenCount, 83)
        XCTAssertEqual(exactCommand.orderedSources.map(\.citationLabel), ["S1"])
        XCTAssertEqual(exactCommand.orderedSources.map(\.rank), [0])
        XCTAssertEqual(exactCommand.citations.map(\.label), ["S1"])
        XCTAssertEqual(exactCommand.citations.map(\.rank), [0])
        XCTAssertEqual(exactCommand.auditEvent.eventType, ArchitectureUXPubChatWire.auditEventType)
        XCTAssertEqual(exactCommand.auditEvent.relatedTable, "messages")
        XCTAssertEqual(exactCommand.auditEvent.relatedID, assistant.id)
        XCTAssertFalse(exactCommand.auditEvent.summary.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(
            (exactCommand.auditEvent.metadataJSON ?? "{}").contains(
                ArchitectureUXPubChatWire.sourceBody
            )
        )

        let completed = try architectureUXPubChatSnapshot(
            store: fixture.store,
            receipt: firstReceipt
        )
        let exactRetry = try fixture.store.groundedChatPublications.finalize(exactCommand)
        XCTAssertEqual(exactRetry, firstReceipt)
        XCTAssertEqual(
            try architectureUXPubChatSnapshot(store: fixture.store, receipt: firstReceipt),
            completed,
            "an exact retry returns the original receipt without touching the aggregate"
        )

        let alteredCommand = architectureUXPubChatCommand(
            copying: exactCommand,
            terminalContent: ArchitectureUXPubChatWire.alteredAnswerText
        )
        XCTAssertThrowsError(
            try fixture.store.groundedChatPublications.finalize(alteredCommand)
        ) { error in
            XCTAssertEqual(
                error as? GroundedChatTerminalPublicationError,
                .idempotencyConflict(firstReceipt.idempotencyKey)
            )
        }
        XCTAssertEqual(
            try architectureUXPubChatSnapshot(store: fixture.store, receipt: firstReceipt),
            completed,
            "an altered retry must not mutate or duplicate the completed aggregate"
        )

        let reopened = makeArchitectureUXPubChatController(
            fixture: fixture,
            runtimeClient: architectureUXPubChatSuccessRuntime()
        )
        let durable = try XCTUnwrap(
            reopened.messages.last(where: { $0.id == assistant.id })
        )
        XCTAssertEqual(durable.status, .completed)
        XCTAssertEqual(durable.content, assistant.content)
        XCTAssertEqual(durable.citations.map(\.label), ["S1"])
        XCTAssertEqual(durable.assuranceState, .preliminary)
        XCTAssertTrue(durable.content.contains(ArchitectureUXPubChatWire.answerText))
        XCTAssertFalse(durable.content.contains(ArchitectureUXPubChatWire.alteredAnswerText))
        XCTAssertFalse(durable.content.contains(ArchitectureUXPubChatWire.forbiddenDefault))
    }
}

private struct ArchitectureUXPubChatAggregateSnapshot: Equatable {
    var messageStatus: String
    var messageContent: String
    var messageUpdatedAt: Date
    var variantStatus: String
    var variantContent: String
    var variantUpdatedAt: Date
    var generationStatus: String
    var generationCompletedAt: Date?
    var generationUpdatedAt: Date
    var sourceSetCount: Int
    var sourceCount: Int
    var citationCount: Int
    var receiptCount: Int
    var receiptDigest: String?
    var auditCount: Int
}

private func reconstructArchitectureUXPubChatCommand(
    store: SupraStore,
    receipt: GroundedChatTerminalPublicationReceipt
) throws -> GroundedChatTerminalPublicationCommand {
    let message = try store.database.writer.read { db in
        try MessageRecord.fetchOne(db, key: receipt.messageID)
    }
    let exactMessage = try XCTUnwrap(message)
    let variant = try store.database.writer.read { db in
        try MessageVariantRecord.fetchOne(db, key: receipt.variantID)
    }
    let exactVariant = try XCTUnwrap(variant)
    let generation = try XCTUnwrap(
        store.generation.fetchGenerationSession(
            generationID: receipt.generationSessionID
        )
    )
    let sourceSet = try XCTUnwrap(
        store.documentSources.fetchSourceSet(id: receipt.sourceSetID)
    )
    let sources = try store.documentSources.fetchSources(sourceSetID: sourceSet.id)
    let citations = try store.chats.fetchCitations(messageID: exactMessage.id)
    let audit = try store.database.writer.read { db in
        try AuditEventRecord.fetchOne(db, key: receipt.auditEventID)
    }

    XCTAssertEqual(exactMessage.chatID, receipt.chatID)
    XCTAssertEqual(exactMessage.activeVariantID, exactVariant.id)
    XCTAssertEqual(exactVariant.messageID, exactMessage.id)
    XCTAssertEqual(exactVariant.generationSessionID, generation.id)
    XCTAssertEqual(generation.chatID, receipt.chatID)
    XCTAssertEqual(generation.messageID, exactMessage.id)
    XCTAssertEqual(generation.variantID, exactVariant.id)
    XCTAssertEqual(sourceSet.messageID, exactMessage.id)
    XCTAssertEqual(sourceSet.matterID, receipt.matterID)

    return GroundedChatTerminalPublicationCommand(
        idempotencyKey: receipt.idempotencyKey,
        matterID: receipt.matterID,
        chatID: receipt.chatID,
        messageID: receipt.messageID,
        variantID: receipt.variantID,
        generationSessionID: receipt.generationSessionID,
        terminalContent: exactMessage.content,
        runtimeMetrics: StoredRuntimeMetrics(
            loadTimeMs: generation.loadTimeMs,
            firstTokenLatencyMs: generation.firstTokenLatencyMs,
            tokensPerSecond: generation.tokensPerSecond,
            cancellationLatencyMs: generation.cancellationLatencyMs,
            peakMemoryMb: generation.peakMemoryMb,
            generatedTokenCount: generation.generatedTokenCount
        ),
        sourceSet: sourceSet,
        orderedSources: sources,
        citations: citations,
        verificationDimensions: receipt.verificationDimensions,
        assuranceState: receipt.assuranceState,
        authorizationEvidenceJSON: receipt.authorizationEvidenceJSON,
        auditEvent: try XCTUnwrap(audit)
    )
}

private func architectureUXPubChatCommand(
    copying command: GroundedChatTerminalPublicationCommand,
    terminalContent: String
) -> GroundedChatTerminalPublicationCommand {
    GroundedChatTerminalPublicationCommand(
        idempotencyKey: command.idempotencyKey,
        matterID: command.matterID,
        chatID: command.chatID,
        messageID: command.messageID,
        variantID: command.variantID,
        generationSessionID: command.generationSessionID,
        terminalContent: terminalContent,
        runtimeMetrics: command.runtimeMetrics,
        sourceSet: command.sourceSet,
        orderedSources: command.orderedSources,
        citations: command.citations,
        verificationDimensions: command.verificationDimensions,
        assuranceState: command.assuranceState,
        authorizationEvidenceJSON: command.authorizationEvidenceJSON,
        auditEvent: command.auditEvent
    )
}

private func architectureUXPubChatSnapshot(
    store: SupraStore,
    receipt: GroundedChatTerminalPublicationReceipt
) throws -> ArchitectureUXPubChatAggregateSnapshot {
    try store.database.writer.read { db in
        let message = try XCTUnwrap(MessageRecord.fetchOne(db, key: receipt.messageID))
        let variant = try XCTUnwrap(MessageVariantRecord.fetchOne(db, key: receipt.variantID))
        let generation = try XCTUnwrap(
            GenerationSessionRecord.fetchOne(db, key: receipt.generationSessionID)
        )
        return ArchitectureUXPubChatAggregateSnapshot(
            messageStatus: message.status,
            messageContent: message.content,
            messageUpdatedAt: message.updatedAt,
            variantStatus: variant.status,
            variantContent: variant.content,
            variantUpdatedAt: variant.updatedAt,
            generationStatus: generation.status,
            generationCompletedAt: generation.completedAt,
            generationUpdatedAt: generation.updatedAt,
            sourceSetCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_source_sets WHERE message_id = ?",
                arguments: [receipt.messageID]
            ) ?? -1,
            sourceCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_output_sources WHERE source_set_id = ?",
                arguments: [receipt.sourceSetID]
            ) ?? -1,
            citationCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_citations WHERE message_id = ?",
                arguments: [receipt.messageID]
            ) ?? -1,
            receiptCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grounded_chat_publications WHERE idempotency_key = ?",
                arguments: [receipt.idempotencyKey]
            ) ?? -1,
            receiptDigest: try String.fetchOne(
                db,
                sql: "SELECT aggregate_digest_sha256 FROM grounded_chat_publications WHERE idempotency_key = ?",
                arguments: [receipt.idempotencyKey]
            ),
            auditCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audit_events WHERE id = ?",
                arguments: [receipt.auditEventID]
            ) ?? -1
        )
    }
}
