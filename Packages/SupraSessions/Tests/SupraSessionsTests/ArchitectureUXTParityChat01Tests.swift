import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

/// T-PARITY-CHAT-01 — the extracted grounded-chat terminal use case must retain
/// the exact packet the controller previously formed: source order, citations,
/// assurance, content-free completion identity, cancellation, and Store effects.
///
/// Expected RED: `GroundedChatTerminalPublicationUseCase` and its request/result
/// contract do not exist; `GlobalChatController` still privately constructs the
/// complete terminal publication command.
@MainActor
final class ArchitectureUXTParityChat01Tests: XCTestCase {
    func testTPARITYCHAT01ExtractedUseCasePreservesSevenSourceAggregateAndDurableDigest() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "parity-seven")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owners = try makeOwners(
            store: fixture.store,
            matterID: fixture.matter.id,
            version: Wire.version
        )
        let context = try makeContext(
            store: fixture.store,
            fixture: fixture,
            labels: Wire.sevenSourceOrder,
            version: Wire.version
        )
        let request = GroundedChatTerminalPublicationRequest(
            matterID: fixture.matter.id,
            question: Wire.question,
            answerText: Wire.answer,
            terminalContent: Wire.terminalContent,
            context: context,
            verification: nil,
            chatID: owners.chat.id,
            assistant: owners.message,
            variant: owners.variant,
            session: owners.generation,
            metrics: Wire.metrics
        )
        let useCase = GroundedChatTerminalPublicationUseCase(store: fixture.store)

        let first = try useCase.publish(request)

        XCTAssertEqual(first.receipt.messageID, Wire.recordID)
        XCTAssertEqual(first.receipt.assuranceState, .preliminary)
        XCTAssertEqual(first.receipt.aggregateDigestSHA256.count, 64)
        XCTAssertFalse(first.receipt.aggregateDigestSHA256.contains(Wire.forbiddenDefault))
        XCTAssertFalse(first.receipt.idempotencyKey.contains(Wire.terminalContent))
        XCTAssertFalse(first.receipt.idempotencyKey.contains(Wire.forbiddenDefault))
        XCTAssertEqual(first.citations.map(\.label), ["S7", "S4"])
        XCTAssertEqual(first.citations.map(\.kind), [.source, .source])
        XCTAssertTrue(first.receipt.verificationDimensions.isComplete)

        let sourceSet = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(id: first.receipt.sourceSetID)
        )
        XCTAssertEqual(sourceSet.retrievalQuery, Wire.question)
        XCTAssertEqual(sourceSet.retrievalDepth, RetrievalDepth.fast.rawValue)
        XCTAssertFalse(sourceSet.scopeJSON.contains(Wire.forbiddenDefault))
        let rows = try fixture.store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(rows.map(\.citationLabel), Wire.sevenSourceOrder)
        XCTAssertEqual(rows.map(\.rank), Array(0..<Wire.version))
        XCTAssertEqual(rows.count, Wire.version)
        XCTAssertTrue(rows.allSatisfy { $0.documentID == fixture.document.id })
        XCTAssertTrue(rows.allSatisfy { !$0.id.contains(Wire.forbiddenDefault) })
        XCTAssertEqual(
            try fixture.store.chats.fetchCitations(messageID: Wire.recordID).map(\.label),
            ["S7", "S4"]
        )

        let durableReceipt = try XCTUnwrap(
            fixture.store.groundedChatPublications.fetchReceipt(
                idempotencyKey: first.receipt.idempotencyKey
            )
        )
        XCTAssertEqual(durableReceipt, first.receipt)
        XCTAssertEqual(
            try fixture.store.documentSources.fetchSources(sourceSetID: sourceSet.id)
                .map(\.citationLabel),
            Wire.sevenSourceOrder,
            "the durable aggregate must retain the use case's exact source order"
        )
        let receiptCount = try await fixture.store.database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grounded_chat_publications WHERE message_id = ?",
                arguments: [Wire.recordID]
            ) ?? 0
        }
        XCTAssertEqual(receiptCount, 1)

        let durable = try ownerSnapshot(store: fixture.store, owners: owners)
        XCTAssertEqual(durable.messageStatus, MessageStatus.completed.rawValue)
        XCTAssertEqual(durable.variantStatus, MessageStatus.completed.rawValue)
        XCTAssertEqual(durable.generationStatus, MessageStatus.completed.rawValue)
        XCTAssertEqual(durable.messageContent, Wire.terminalContent)
        XCTAssertEqual(durable.variantContent, Wire.terminalContent)
        XCTAssertEqual(durable.sourceSetCount, 1)
        XCTAssertEqual(durable.sourceCount, Wire.version)
        XCTAssertEqual(durable.citationCount, 2)
        XCTAssertEqual(durable.receiptCount, 1)
        XCTAssertEqual(durable.auditCount, 1)
        XCTAssertFalse(durable.messageContent.contains(Wire.forbiddenDefault))
        XCTAssertEqual(Wire.nextVersion, Wire.version + 1)
    }

    func testTPARITYCHAT01EighthSourceCancellationLeavesEveryOwnerPending() async throws {
        let fixture = try await makeArchitectureUXPubChatFixture(prefix: "parity-eight-cancel")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owners = try makeOwners(
            store: fixture.store,
            matterID: fixture.matter.id,
            version: Wire.nextVersion
        )
        let context = try makeContext(
            store: fixture.store,
            fixture: fixture,
            labels: Wire.sevenSourceOrder + ["S8"],
            version: Wire.nextVersion
        )
        let request = GroundedChatTerminalPublicationRequest(
            matterID: fixture.matter.id,
            question: Wire.question,
            answerText: Wire.answer,
            terminalContent: Wire.terminalContent,
            context: context,
            verification: nil,
            chatID: owners.chat.id,
            assistant: owners.message,
            variant: owners.variant,
            session: owners.generation,
            metrics: Wire.metrics
        )
        let useCase = GroundedChatTerminalPublicationUseCase(store: fixture.store)

        XCTAssertThrowsError(try useCase.publish(request, cancellationCheck: { true })) { error in
            XCTAssertEqual(error as? GroundedChatTerminalPublicationError, .cancelled)
        }

        let durable = try ownerSnapshot(store: fixture.store, owners: owners)
        XCTAssertEqual(durable.messageStatus, MessageStatus.pending.rawValue)
        XCTAssertEqual(durable.variantStatus, MessageStatus.pending.rawValue)
        XCTAssertEqual(durable.generationStatus, MessageStatus.pending.rawValue)
        XCTAssertEqual(durable.messageContent, "")
        XCTAssertEqual(durable.variantContent, "")
        XCTAssertEqual(durable.sourceSetCount, 0)
        XCTAssertEqual(durable.sourceCount, 0)
        XCTAssertEqual(durable.citationCount, 0)
        XCTAssertEqual(durable.receiptCount, 0)
        XCTAssertEqual(durable.auditCount, 0)
        XCTAssertEqual(context.sources.count, Wire.nextVersion)
        XCTAssertFalse(context.sources.map(\.sourceID).joined().contains(Wire.forbiddenDefault))
    }
}

private enum Wire {
    static let recordID = "record-713"
    static let version = 7
    static let nextVersion = 8
    static let forbiddenDefault = "DEFAULT-000"
    static let wire = "T_PARITY_CHAT_01_WIRE_731"
    static let question = "What does the exact T_PARITY_CHAT_01_WIRE_731 packet establish?"
    static let answer = "The exact packet is retained in its original order [S7] [S4]."
    static let terminalContent = answer + "\n\nT_PARITY_CHAT_01_TERMINAL_739"
    static let sevenSourceOrder = ["S7", "S1", "S6", "S2", "S5", "S3", "S4"]
    static let timestamp = Date(timeIntervalSince1970: 1_946_254_731)
    static let metrics = StoredRuntimeMetrics(
        loadTimeMs: 317,
        firstTokenLatencyMs: 419,
        tokensPerSecond: 23.75,
        cancellationLatencyMs: 29,
        peakMemoryMb: 1_927,
        generatedTokenCount: 83
    )
}

private struct Owners {
    var chat: ChatRecord
    var message: MessageRecord
    var variant: MessageVariantRecord
    var generation: GenerationSessionRecord
}

private struct OwnerSnapshot {
    var messageStatus: String
    var messageContent: String
    var variantStatus: String
    var variantContent: String
    var generationStatus: String
    var sourceSetCount: Int
    var sourceCount: Int
    var citationCount: Int
    var receiptCount: Int
    var auditCount: Int
}

private func makeOwners(store: SupraStore, matterID: String, version: Int) throws -> Owners {
    let chat = try store.chats.createMatterChat(
        matterID: matterID,
        title: "\(Wire.wire) v\(version)"
    )
    let message = MessageRecord(
        id: Wire.recordID,
        chatID: chat.id,
        role: MessageRole.assistant.rawValue,
        status: MessageStatus.pending.rawValue,
        createdAt: Wire.timestamp,
        updatedAt: Wire.timestamp
    )
    try store.database.writer.write { db in
        try message.insert(db)
    }
    let generation = try store.generation.createGenerationSession(
        chatID: chat.id,
        messageID: message.id,
        modelID: "t-parity-chat-model-719-v\(version)",
        prompt: Wire.question,
        systemPrompt: "Use only \(Wire.wire).",
        options: GenerationOptions(maxContextTokens: 2_047, maxOutputTokens: version)
    )
    let variant = try store.chats.createVariant(
        messageID: message.id,
        generationSessionID: generation.id
    )
    try store.generation.linkVariant(generationID: generation.id, variantID: variant.id)
    return Owners(chat: chat, message: message, variant: variant, generation: generation)
}

private func makeContext(
    store: SupraStore,
    fixture: ArchitectureUXPubChatFixture,
    labels: [String],
    version: Int
) throws -> GroundedChatContext {
    let chunk = try XCTUnwrap(
        store.documentIndex.fetchChunks(documentID: fixture.document.id).first
    )
    let sourceKind = try XCTUnwrap(DocumentSourceKind(rawValue: chunk.sourceKind))
    let locator = DocumentSourceLocator(
        sourceKind: sourceKind,
        pageIndex: chunk.pageIndex,
        pageLabel: chunk.pageLabel,
        sheetName: chunk.sheetName,
        cellRange: chunk.cellRange,
        emailPartPath: chunk.emailPartPath,
        charStart: chunk.charStart,
        charEnd: chunk.charEnd,
        boundingBoxesJSON: chunk.boundingBoxesJSON
    )
    let excerpt = chunk.displayExcerpt ?? chunk.normalizedText
        .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
        .joined(separator: " ")
    let exactExcerpt = excerpt.count <= 220 ? excerpt : String(excerpt.prefix(220)) + "…"
    let sources = labels.map { label in
        GroundedSourceRef(
            label: label,
            sourceID: "\(fixture.matter.id)/\(chunk.id)",
            chunkID: chunk.id,
            revisionID: chunk.revisionID,
            documentID: fixture.document.id,
            documentName: fixture.document.displayName,
            locator: locator,
            excerpt: exactExcerpt,
            supportText: chunk.normalizedText,
            lowConfidence: false
        )
    }
    let candidates = zip(labels.indices, sources).map { index, source in
        DocumentPackingCandidate(
            sourceID: source.sourceID,
            label: source.label,
            rank: index,
            disposition: .packed,
            reason: "t_parity_chat_exact_packet_v\(version)",
            originalTokenCount: 71 + index,
            packedTokenCount: 61 + index
        )
    }
    let packingReport = DocumentPackingReport(
        schemaVersion: version,
        countMethod: .exact,
        availableInputTokens: 2_047,
        selectedInputTokens: candidates.reduce(0) { $0 + $1.packedTokenCount },
        overflowRetryCount: 0,
        candidates: candidates
    )
    return GroundedChatContext(
        modelPrompt: Wire.wire,
        systemPrompt: "T_PARITY_CHAT_SYSTEM_743",
        trailer: nil,
        sourceTexts: sources.map(\.supportText),
        sources: sources,
        scopeFullyIndexed: true,
        depth: .fast,
        sourceSetPackingReport: packingReport,
        sourceScope: RetrievalScope(documentIDs: [fixture.document.id]),
        retrievalConfiguration: DocumentRetrievalConfiguration(
            schemaVersion: version,
            mode: DocumentSourceSetMode.autoSource.rawValue,
            depth: RetrievalDepth.fast.rawValue,
            candidateLimit: version,
            packedLimit: version,
            maxPerDocument: version,
            semanticFloor: 0.731,
            rrfK: 71
        )
    )
}

private func ownerSnapshot(store: SupraStore, owners: Owners) throws -> OwnerSnapshot {
    try store.database.writer.read { db in
        let message = try XCTUnwrap(MessageRecord.fetchOne(db, key: owners.message.id))
        let variant = try XCTUnwrap(MessageVariantRecord.fetchOne(db, key: owners.variant.id))
        let generation = try XCTUnwrap(
            GenerationSessionRecord.fetchOne(db, key: owners.generation.id)
        )
        return OwnerSnapshot(
            messageStatus: message.status,
            messageContent: message.content,
            variantStatus: variant.status,
            variantContent: variant.content,
            generationStatus: generation.status,
            sourceSetCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_source_sets WHERE message_id = ?",
                arguments: [owners.message.id]
            ) ?? 0,
            sourceCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_output_sources WHERE source_set_id LIKE ?",
                arguments: ["%\(owners.message.id)%"]
            ) ?? 0,
            citationCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_citations WHERE message_id = ?",
                arguments: [owners.message.id]
            ) ?? 0,
            receiptCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grounded_chat_publications WHERE message_id = ?",
                arguments: [owners.message.id]
            ) ?? 0,
            auditCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audit_events WHERE related_table = 'messages' AND related_id = ? AND event_type = 'grounded_chat_terminal_published'",
                arguments: [owners.message.id]
            ) ?? 0
        )
    }
}
