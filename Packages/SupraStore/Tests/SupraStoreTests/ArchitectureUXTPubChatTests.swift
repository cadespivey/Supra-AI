import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// T-PUB-CHAT-01 / T-PUB-CHAT-02 — Store owns the only transition from a
/// pending grounded assistant turn to its terminal, assurance-bearing form.
/// The message projection, active variant, generation session, exact ordered
/// source packet, inline citations, verification dimensions, assurance,
/// authorization evidence, publication receipt, and audit must commit together.
///
/// Expected RED: `GroundedChatTerminalPublicationCommand`, its typed receipt
/// and error, `SupraStore.groundedChatPublications`, and the Store-owned atomic
/// finalization/fetch APIs do not exist. The current controller completes the
/// variant and generation before separately creating the source set and rows,
/// then swallows inline-citation persistence failures with `try?`.
final class ArchitectureUXTPubChatTests: XCTestCase {
    private enum Wire {
        static let idempotencyKey = "grounded-terminal-wire-731"
        static let forbiddenDefault = "DEFAULT-000"
        static let terminalContent =
            "The synthetic renewal date is June 17, 2031 [S17], and notice is due May 29, 2031 [S29]."
        static let alteredContent =
            "ALTERED: the synthetic renewal date is July 17, 2031 [S17]."
        static let authorizationEvidenceJSON =
            #"{"basis":"local_matter_documents","policy_version":"grounded-local-wire-739"}"#
        static let tamperedDigest = String(repeating: "b", count: 64)
    }

    func testTPUBCHATSchemaV075AppendsContentFreeReceiptAfterV074() throws {
        // Standing compatibility guard: the finalization tests exercise the
        // receipt, while this assertion owns its durable, content-free shape
        // and proves the new endpoint is appended after immutable v074.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertEqual(migrator.migrations.count, 75)
        XCTAssertEqual(Array(migrator.migrations.suffix(2)), [
            "v074_create_canonical_matter_identity",
            "v075_create_grounded_chat_publications",
        ])

        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v074_create_canonical_matter_identity")
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("grounded_chat_publications"))
            let sourceSetColumns = Set(try db.columns(in: "document_source_sets").map(\.name))
            XCTAssertTrue(sourceSetColumns.isDisjoint(with: [
                "terminal_verification_dimensions_json",
                "terminal_assurance_state",
                "terminal_authorization_evidence_json",
            ]))
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                "v075_create_grounded_chat_publications"
            )
            let receiptColumns = Set(
                try db.columns(in: "grounded_chat_publications").map(\.name)
            )
            XCTAssertEqual(receiptColumns, Set([
                "idempotency_key",
                "aggregate_digest_sha256",
                "terminal_content_sha256",
                "verification_dimensions_sha256",
                "authorization_evidence_sha256",
                "matter_id",
                "chat_id",
                "message_id",
                "variant_id",
                "generation_session_id",
                "source_set_id",
                "assurance_state",
                "audit_event_id",
                "created_at",
            ]))
            XCTAssertTrue(receiptColumns.isDisjoint(with: [
                "terminal_content",
                "verification_dimensions_json",
                "authorization_evidence_json",
                "source_excerpt",
                "citation_quote",
            ]))

            let sourceSetColumns = Set(try db.columns(in: "document_source_sets").map(\.name))
            XCTAssertTrue(sourceSetColumns.isSuperset(of: [
                "terminal_verification_dimensions_json",
                "terminal_assurance_state",
                "terminal_authorization_evidence_json",
            ]))
        }
    }

    func testTPUBCHAT01FaultAtEveryAggregateWriteLeavesPendingTurnAndNoOrphanPacket() throws {
        for boundary in AggregateWriteBoundary.allCases {
            let fixture = try makeFixture()
            let before = try snapshot(fixture)
            try installFailureTrigger(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.groundedChatPublications.finalize(fixture.command),
                "T-PUB-CHAT-01 must observe the injected \(boundary.rawValue) write failure"
            )

            XCTAssertEqual(
                try snapshot(fixture),
                before,
                "an injected \(boundary.rawValue) failure must roll back the entire terminal aggregate"
            )
            try assertPendingWithoutPublication(fixture)
        }
    }

    func testTPUBCHAT02ExactRetryIsIdempotentAndAlteredRetryRejectsWithoutMutation() throws {
        let fixture = try makeFixture()

        let first: GroundedChatTerminalPublicationReceipt = try fixture.store
            .groundedChatPublications.finalize(fixture.command)
        assertReceiptWire(first, fixture: fixture)
        try assertCompletedAggregate(fixture, receipt: first)
        let afterFirst = try snapshot(fixture)

        let exactRetry: GroundedChatTerminalPublicationReceipt = try fixture.store
            .groundedChatPublications.finalize(fixture.command)
        XCTAssertEqual(exactRetry, first)
        XCTAssertEqual(
            try snapshot(fixture),
            afterFirst,
            "an exact retry must return the existing completion without touching timestamps or appending rows"
        )

        let altered = try makeCommand(fixture, terminalContent: Wire.alteredContent)
        XCTAssertThrowsError(
            try fixture.store.groundedChatPublications.finalize(altered)
        ) { error in
            XCTAssertNotNil(
                error as? GroundedChatTerminalPublicationError,
                "an altered retry must fail through the typed publication boundary"
            )
        }
        XCTAssertEqual(
            try snapshot(fixture),
            afterFirst,
            "an altered retry must not replace any member of the completed aggregate"
        )
        XCTAssertFalse(
            try XCTUnwrap(fixture.store.chats.fetchMessages(chatID: fixture.chat.id).last)
                .content.contains("ALTERED:"),
            "the altered nondefault retry text must be absent from the exact terminal message"
        )
    }

    func testTPUBCHAT01CancellationAndSourceIdentityOrOrderMismatchMakeNoMutation() throws {
        do {
            let fixture = try makeFixture()
            let cancellation = SecondCheckCancellationProbe()
            let before = try snapshot(fixture)

            XCTAssertThrowsError(
                try fixture.store.groundedChatPublications.finalize(
                    fixture.command,
                    cancellationCheck: { cancellation.isCancellationRequested() }
                )
            ) { error in
                XCTAssertNotNil(error as? GroundedChatTerminalPublicationError)
            }
            XCTAssertGreaterThanOrEqual(
                cancellation.checkCount,
                2,
                "the Store boundary must recheck cancellation after validation and immediately before terminal commit"
            )
            XCTAssertEqual(
                try snapshot(fixture),
                before,
                "cancellation arriving inside finalization must leave the pending aggregate unchanged"
            )
            try assertPendingWithoutPublication(fixture)
        }

        do {
            let fixture = try makeFixture()
            try fixture.store.chats.markVariantCancelled(fixture.variant.id)
            try fixture.store.generation.cancelGeneration(generationID: fixture.generation.id)
            let cancelled = try snapshot(fixture)

            XCTAssertThrowsError(
                try fixture.store.groundedChatPublications.finalize(fixture.command)
            ) { error in
                XCTAssertNotNil(error as? GroundedChatTerminalPublicationError)
            }
            XCTAssertEqual(try snapshot(fixture), cancelled)
            XCTAssertEqual(
                try XCTUnwrap(fixture.store.chats.fetchVariants(messageID: fixture.message.id).first).status,
                MessageStatus.cancelled.rawValue
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    fixture.store.generation.fetchGenerationSession(
                        generationID: fixture.generation.id
                    )
                ).status,
                MessageStatus.cancelled.rawValue
            )
            try assertNoPublicationRows(fixture)
        }

        do {
            let fixture = try makeFixture()
            var mismatchedSources = fixture.sources
            mismatchedSources[0].sourceSetID = "foreign-source-set-wire-743"
            let mismatched = try makeCommand(fixture, orderedSources: mismatchedSources)
            let before = try snapshot(fixture)

            XCTAssertThrowsError(
                try fixture.store.groundedChatPublications.finalize(mismatched)
            ) { error in
                XCTAssertNotNil(error as? GroundedChatTerminalPublicationError)
            }
            XCTAssertEqual(try snapshot(fixture), before)
            try assertPendingWithoutPublication(fixture)
        }

        do {
            let fixture = try makeFixture()
            let outOfOrder = try makeCommand(
                fixture,
                orderedSources: Array(fixture.sources.reversed())
            )
            let before = try snapshot(fixture)

            XCTAssertThrowsError(
                try fixture.store.groundedChatPublications.finalize(outOfOrder)
            ) { error in
                XCTAssertNotNil(error as? GroundedChatTerminalPublicationError)
            }
            XCTAssertEqual(try snapshot(fixture), before)
            try assertPendingWithoutPublication(fixture)
        }
    }

    func testTPUBCHAT02StoredDigestMismatchRejectsExactPayloadWithoutMutation() throws {
        let fixture = try makeFixture()
        let receipt: GroundedChatTerminalPublicationReceipt = try fixture.store
            .groundedChatPublications.finalize(fixture.command)
        XCTAssertNotEqual(receipt.aggregateDigestSHA256, Wire.tamperedDigest)

        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE grounded_chat_publications
                    SET aggregate_digest_sha256 = ?
                    WHERE idempotency_key = ?
                    """,
                arguments: [Wire.tamperedDigest, Wire.idempotencyKey]
            )
        }
        let afterTamper = try snapshot(fixture)

        XCTAssertThrowsError(
            try fixture.store.groundedChatPublications.finalize(fixture.command)
        ) { error in
            XCTAssertNotNil(error as? GroundedChatTerminalPublicationError)
        }
        XCTAssertEqual(
            try snapshot(fixture),
            afterTamper,
            "a stored digest mismatch must fail closed rather than repair or duplicate the aggregate"
        )
    }

    // MARK: - Exact aggregate assertions

    private func assertReceiptWire(
        _ receipt: GroundedChatTerminalPublicationReceipt,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(receipt.idempotencyKey, Wire.idempotencyKey, file: file, line: line)
        XCTAssertEqual(receipt.matterID, fixture.matter.id, file: file, line: line)
        XCTAssertEqual(receipt.chatID, fixture.chat.id, file: file, line: line)
        XCTAssertEqual(receipt.messageID, fixture.message.id, file: file, line: line)
        XCTAssertEqual(receipt.variantID, fixture.variant.id, file: file, line: line)
        XCTAssertEqual(
            receipt.generationSessionID,
            fixture.generation.id,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.sourceSetID, fixture.sourceSet.id, file: file, line: line)
        XCTAssertEqual(receipt.assuranceState, .propositionSupported, file: file, line: line)
        XCTAssertEqual(
            receipt.verificationDimensions,
            fixture.verificationDimensions,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.authorizationEvidenceJSON,
            Wire.authorizationEvidenceJSON,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.auditEventID, fixture.auditEvent.id, file: file, line: line)
        XCTAssertEqual(receipt.aggregateDigestSHA256.count, 64, file: file, line: line)
        XCTAssertNotEqual(
            receipt.aggregateDigestSHA256,
            String(repeating: "0", count: 64),
            file: file,
            line: line
        )
        XCTAssertFalse(
            receipt.aggregateDigestSHA256.contains(Wire.forbiddenDefault),
            file: file,
            line: line
        )
        XCTAssertFalse(
            receipt.idempotencyKey.contains(Wire.forbiddenDefault),
            file: file,
            line: line
        )
    }

    private func assertCompletedAggregate(
        _ fixture: Fixture,
        receipt: GroundedChatTerminalPublicationReceipt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let persistedReceipt = try XCTUnwrap(
            fixture.store.groundedChatPublications.fetchReceipt(
                idempotencyKey: Wire.idempotencyKey
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(persistedReceipt, receipt, file: file, line: line)

        let message = try XCTUnwrap(
            fixture.store.chats.fetchMessages(chatID: fixture.chat.id).last,
            file: file,
            line: line
        )
        XCTAssertEqual(message.status, MessageStatus.completed.rawValue, file: file, line: line)
        XCTAssertEqual(message.content, Wire.terminalContent, file: file, line: line)
        XCTAssertFalse(
            message.content.contains(Wire.forbiddenDefault),
            file: file,
            line: line
        )

        let variant = try XCTUnwrap(
            fixture.store.chats.fetchVariants(messageID: fixture.message.id).first,
            file: file,
            line: line
        )
        XCTAssertEqual(variant.status, MessageStatus.completed.rawValue, file: file, line: line)
        XCTAssertEqual(variant.content, Wire.terminalContent, file: file, line: line)

        let generation = try XCTUnwrap(
            fixture.store.generation.fetchGenerationSession(generationID: fixture.generation.id),
            file: file,
            line: line
        )
        XCTAssertEqual(generation.status, MessageStatus.completed.rawValue, file: file, line: line)
        XCTAssertEqual(generation.loadTimeMs, 317, file: file, line: line)
        XCTAssertEqual(generation.firstTokenLatencyMs, 419, file: file, line: line)
        XCTAssertEqual(generation.tokensPerSecond, 23.75, file: file, line: line)
        XCTAssertEqual(generation.peakMemoryMb, 1_927, file: file, line: line)
        XCTAssertEqual(generation.generatedTokenCount, 83, file: file, line: line)

        let sourceSet = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(messageID: fixture.message.id),
            file: file,
            line: line
        )
        XCTAssertEqual(sourceSet.id, fixture.sourceSet.id, file: file, line: line)
        XCTAssertEqual(sourceSet.matterID, fixture.matter.id, file: file, line: line)
        XCTAssertEqual(sourceSet.messageID, fixture.message.id, file: file, line: line)
        XCTAssertEqual(sourceSet.retrievalDepth, "deep-wire-751", file: file, line: line)
        XCTAssertTrue(sourceSet.scopeJSON.contains("wire_scope"), file: file, line: line)
        XCTAssertFalse(sourceSet.scopeJSON.contains("default_scope"), file: file, line: line)

        let sources = try fixture.store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(sources.map(\.id), fixture.sources.map(\.id), file: file, line: line)
        XCTAssertEqual(sources.map(\.rank), [17, 29], file: file, line: line)
        XCTAssertEqual(sources.map(\.citationLabel), ["S17", "S29"], file: file, line: line)

        let citations = try fixture.store.chats.fetchCitations(messageID: fixture.message.id)
        XCTAssertEqual(citations.map(\.id), fixture.citations.map(\.id), file: file, line: line)
        XCTAssertEqual(citations.map(\.rank), [17, 29], file: file, line: line)
        XCTAssertEqual(citations.map(\.label), ["S17", "S29"], file: file, line: line)

        let audits = try fixture.store.auditEvents.fetchEvents(
            relatedTable: "messages",
            relatedID: fixture.message.id,
            eventType: "grounded_chat_terminal_published"
        )
        XCTAssertEqual(audits.map(\.id), [fixture.auditEvent.id], file: file, line: line)
        XCTAssertEqual(audits.first?.metadataJSON, fixture.auditEvent.metadataJSON, file: file, line: line)

        try fixture.store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grounded_chat_publications WHERE idempotency_key = ?",
                    arguments: [Wire.idempotencyKey]
                ),
                1,
                file: file,
                line: line
            )
        }
    }

    private func assertPendingWithoutPublication(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let message = try XCTUnwrap(
            fixture.store.chats.fetchMessages(chatID: fixture.chat.id).last,
            file: file,
            line: line
        )
        let variant = try XCTUnwrap(
            fixture.store.chats.fetchVariants(messageID: fixture.message.id).first,
            file: file,
            line: line
        )
        let generation = try XCTUnwrap(
            fixture.store.generation.fetchGenerationSession(generationID: fixture.generation.id),
            file: file,
            line: line
        )
        XCTAssertEqual(message.status, MessageStatus.pending.rawValue, file: file, line: line)
        XCTAssertEqual(message.content, "", file: file, line: line)
        XCTAssertEqual(variant.status, MessageStatus.pending.rawValue, file: file, line: line)
        XCTAssertEqual(variant.content, "", file: file, line: line)
        XCTAssertEqual(generation.status, MessageStatus.pending.rawValue, file: file, line: line)
        XCTAssertNil(generation.completedAt, file: file, line: line)
        try assertNoPublicationRows(fixture, file: file, line: line)
    }

    private func assertNoPublicationRows(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(
            try fixture.store.documentSources.fetchSourceSet(messageID: fixture.message.id),
            file: file,
            line: line
        )
        XCTAssertTrue(
            try fixture.store.chats.fetchCitations(messageID: fixture.message.id).isEmpty,
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.groundedChatPublications.fetchReceipt(
                idempotencyKey: Wire.idempotencyKey
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "messages",
                relatedID: fixture.message.id,
                eventType: "grounded_chat_terminal_published"
            ).isEmpty,
            file: file,
            line: line
        )
    }

    // MARK: - Fault boundaries and snapshots

    private enum AggregateWriteBoundary: String, CaseIterable {
        case activeVariant = "active-variant"
        case messageProjection = "message-projection"
        case generationSession = "generation-session"
        case sourceSet = "source-set"
        case firstSource = "first-source"
        case secondSource = "second-source"
        case firstCitation = "first-citation"
        case secondCitation = "second-citation"
        case publicationReceipt = "publication-receipt"
        case auditEvent = "audit-event"
    }

    private func installFailureTrigger(
        _ boundary: AggregateWriteBoundary,
        fixture: Fixture
    ) throws {
        let predicate: (table: String, timing: String, condition: String)
        switch boundary {
        case .activeVariant:
            predicate = (
                "message_variants",
                "UPDATE",
                "OLD.id = '\(fixture.variant.id)' AND NEW.status = 'completed'"
            )
        case .messageProjection:
            predicate = (
                "messages",
                "UPDATE",
                "OLD.id = '\(fixture.message.id)' AND NEW.status = 'completed'"
            )
        case .generationSession:
            predicate = (
                "generation_sessions",
                "UPDATE",
                "OLD.id = '\(fixture.generation.id)' AND NEW.status = 'completed'"
            )
        case .sourceSet:
            predicate = ("document_source_sets", "INSERT", "NEW.id = '\(fixture.sourceSet.id)'")
        case .firstSource:
            predicate = ("document_output_sources", "INSERT", "NEW.id = '\(fixture.sources[0].id)'")
        case .secondSource:
            predicate = ("document_output_sources", "INSERT", "NEW.id = '\(fixture.sources[1].id)'")
        case .firstCitation:
            predicate = ("message_citations", "INSERT", "NEW.id = '\(fixture.citations[0].id)'")
        case .secondCitation:
            predicate = ("message_citations", "INSERT", "NEW.id = '\(fixture.citations[1].id)'")
        case .publicationReceipt:
            predicate = (
                "grounded_chat_publications",
                "INSERT",
                "NEW.idempotency_key = '\(Wire.idempotencyKey)'"
            )
        case .auditEvent:
            predicate = ("audit_events", "INSERT", "NEW.id = '\(fixture.auditEvent.id)'")
        }
        let triggerName = "t_pub_chat_01_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))"
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER \(triggerName)
                    BEFORE \(predicate.timing) ON \(predicate.table)
                    WHEN \(predicate.condition)
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic T-PUB-CHAT-01 \(boundary.rawValue) failure');
                    END
                    """
            )
        }
    }

    private struct AggregateSnapshot: Equatable {
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
        var publicationCount: Int
        var publicationDigest: String?
        var auditCount: Int
    }

    private final class SecondCheckCancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0

        var checkCount: Int {
            lock.withLock { checks }
        }

        func isCancellationRequested() -> Bool {
            lock.withLock {
                checks += 1
                return checks >= 2
            }
        }
    }

    private func snapshot(_ fixture: Fixture) throws -> AggregateSnapshot {
        try fixture.store.database.writer.read { db in
            let message = try XCTUnwrap(MessageRecord.fetchOne(db, key: fixture.message.id))
            let variant = try XCTUnwrap(MessageVariantRecord.fetchOne(db, key: fixture.variant.id))
            let generation = try XCTUnwrap(
                GenerationSessionRecord.fetchOne(db, key: fixture.generation.id)
            )
            return AggregateSnapshot(
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
                    arguments: [fixture.message.id]
                ) ?? -1,
                sourceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM document_output_sources WHERE source_set_id = ?",
                    arguments: [fixture.sourceSet.id]
                ) ?? -1,
                citationCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM message_citations WHERE message_id = ?",
                    arguments: [fixture.message.id]
                ) ?? -1,
                publicationCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grounded_chat_publications WHERE idempotency_key = ?",
                    arguments: [Wire.idempotencyKey]
                ) ?? -1,
                publicationDigest: try String.fetchOne(
                    db,
                    sql: "SELECT aggregate_digest_sha256 FROM grounded_chat_publications WHERE idempotency_key = ?",
                    arguments: [Wire.idempotencyKey]
                ),
                auditCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM audit_events WHERE id = ?",
                    arguments: [fixture.auditEvent.id]
                ) ?? -1
            )
        }
    }

    // MARK: - Synthetic fixture

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let chat: ChatRecord
        let message: MessageRecord
        let variant: MessageVariantRecord
        let generation: GenerationSessionRecord
        let sourceSet: DocumentSourceSetRecord
        let sources: [DocumentOutputSourceRecord]
        let citations: [MessageCitationRecord]
        let verificationDimensions: VerificationDimensions
        let auditEvent: AuditEventRecord
        let command: GroundedChatTerminalPublicationCommand
    }

    private struct SourceFixture {
        let document: MatterDocumentRecord
        let revision: DocumentPartRevisionRecord
        let chunk: DocumentChunkRecord
        let locatorJSON: String
        let excerpt: String
    }

    private func makeFixture() throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Synthetic terminal publication matter 727",
            jurisdiction: "Delaware",
            partyPerspective: .defendant
        )
        let chat = try store.chats.createMatterChat(
            matterID: matter.id,
            title: "Synthetic grounded terminal chat 729"
        )
        let message = try store.chats.createAssistantMessageShell(chatID: chat.id)
        let generation = try store.generation.createGenerationSession(
            chatID: chat.id,
            messageID: message.id,
            modelID: "nondefault-model-wire-733",
            prompt: "Find the synthetic renewal and notice dates.",
            systemPrompt: "Use only the retained synthetic packet.",
            options: GenerationOptions(preset: .legalReasoning)
        )
        let variant = try store.chats.createVariant(
            messageID: message.id,
            generationSessionID: generation.id
        )
        try store.generation.linkVariant(generationID: generation.id, variantID: variant.id)

        let renewal = try makeSourceDocument(
            store: store,
            matterID: matter.id,
            stem: "renewal-17",
            partIndex: 7,
            charStart: 37,
            excerpt: "The synthetic agreement renews on June 17, 2031."
        )
        let notice = try makeSourceDocument(
            store: store,
            matterID: matter.id,
            stem: "notice-29",
            partIndex: 11,
            charStart: 53,
            excerpt: "Synthetic notice must be delivered by May 29, 2031."
        )

        let sourceSet = DocumentSourceSetRecord(
            id: "grounded-source-set-wire-743",
            matterID: matter.id,
            status: DocumentSourceSetStatus.pending.rawValue,
            mode: DocumentSourceSetMode.autoSource.rawValue,
            scopeJSON: #"{"schema_version":731,"wire_scope":["renewal-17","notice-29"]}"#,
            retrievalQuery: "synthetic renewal notice wire 747",
            retrievalDepth: "deep-wire-751",
            packingReportJSON: #"{"packed_item_count":2,"wire_budget":757}"#,
            embeddingModelID: "embedding-model-wire-761",
            embeddingModelRevision: "embedding-revision-wire-769",
            chunkerVersion: 17,
            retrievalConfigJSON: #"{"rrf_k":29,"wire_floor":0.731}"#,
            corpusSnapshotHash: String(repeating: "7", count: 64),
            messageID: message.id,
            createdAt: Date(timeIntervalSince1970: 1_786_700_743)
        )
        var sources = [
            DocumentOutputSourceRecord(
                id: "grounded-source-row-wire-17",
                sourceSetID: sourceSet.id,
                documentID: renewal.document.id,
                chunkID: renewal.chunk.id,
                revisionID: renewal.revision.id,
                citationLabel: "S17",
                locatorJSON: renewal.locatorJSON,
                excerpt: renewal.excerpt,
                rank: 17,
                createdAt: Date(timeIntervalSince1970: 1_786_700_751)
            ),
            DocumentOutputSourceRecord(
                id: "grounded-source-row-wire-29",
                sourceSetID: sourceSet.id,
                documentID: notice.document.id,
                chunkID: notice.chunk.id,
                revisionID: notice.revision.id,
                citationLabel: "S29",
                locatorJSON: notice.locatorJSON,
                excerpt: notice.excerpt,
                rank: 29,
                createdAt: Date(timeIntervalSince1970: 1_786_700_757)
            ),
        ]
        let verificationResults = [
            try supportedResult(
                propositionID: "renewal-date-wire-773",
                source: sources[0]
            ),
            try supportedResult(
                propositionID: "notice-date-wire-787",
                source: sources[1]
            ),
        ]
        let verificationJSON = try JSONCoding.encode(verificationResults)
        sources[0].warningsJSON = verificationJSON
        sources[1].warningsJSON = verificationJSON

        let citations = [
            MessageCitationRecord(
                id: "grounded-citation-wire-17",
                messageID: message.id,
                label: "S17",
                kind: "source",
                documentID: renewal.document.id,
                locatorJSON: renewal.locatorJSON,
                displayName: renewal.document.displayName,
                matchText: renewal.excerpt,
                rank: 17,
                createdAt: Date(timeIntervalSince1970: 1_786_700_761)
            ),
            MessageCitationRecord(
                id: "grounded-citation-wire-29",
                messageID: message.id,
                label: "S29",
                kind: "source",
                documentID: notice.document.id,
                locatorJSON: notice.locatorJSON,
                displayName: notice.document.displayName,
                matchText: notice.excerpt,
                rank: 29,
                createdAt: Date(timeIntervalSince1970: 1_786_700_769)
            ),
        ]
        let dimensionEvidence = sources.map {
            VerificationDimensionEvidence(
                sourceID: $0.id,
                sourceLabel: $0.citationLabel,
                locator: $0.locatorJSON,
                excerpt: $0.excerpt
            )
        }
        let dimensions = VerificationDimensions.complete(overrides: [
            VerificationDimensionResult(
                dimension: .propositionSupport,
                status: .satisfied,
                reason: "Both nondefault propositions retain exact evidence.",
                evidence: dimensionEvidence
            ),
            VerificationDimensionResult(
                dimension: .citationResolution,
                status: .satisfied,
                reason: "Both nondefault labels resolve to retained rows.",
                evidence: dimensionEvidence
            ),
            VerificationDimensionResult(
                dimension: .criticalValueFidelity,
                status: .satisfied,
                reason: "The two synthetic dates match their retained excerpts.",
                evidence: dimensionEvidence
            ),
        ])
        let audit = AuditEventRecord(
            id: "grounded-publication-audit-wire-797",
            matterID: matter.id,
            timestamp: Date(timeIntervalSince1970: 1_786_700_797),
            eventType: "grounded_chat_terminal_published",
            actor: "synthetic-attorney-wire-809",
            summary: "Published one exact grounded terminal aggregate.",
            relatedTable: "messages",
            relatedID: message.id,
            metadataJSON: #"{"authorization_basis":"local_matter_documents","policy_version":"grounded-local-wire-739"}"#
        )

        let partial = Fixture(
            store: store,
            matter: matter,
            chat: chat,
            message: message,
            variant: variant,
            generation: generation,
            sourceSet: sourceSet,
            sources: sources,
            citations: citations,
            verificationDimensions: dimensions,
            auditEvent: audit,
            command: GroundedChatTerminalPublicationCommand(
                idempotencyKey: Wire.idempotencyKey,
                matterID: matter.id,
                chatID: chat.id,
                messageID: message.id,
                variantID: variant.id,
                generationSessionID: generation.id,
                terminalContent: Wire.terminalContent,
                runtimeMetrics: StoredRuntimeMetrics(
                    loadTimeMs: 317,
                    firstTokenLatencyMs: 419,
                    tokensPerSecond: 23.75,
                    peakMemoryMb: 1_927,
                    generatedTokenCount: 83
                ),
                sourceSet: sourceSet,
                orderedSources: sources,
                citations: citations,
                verificationDimensions: dimensions,
                assuranceState: .propositionSupported,
                authorizationEvidenceJSON: Wire.authorizationEvidenceJSON,
                auditEvent: audit
            )
        )
        return partial
    }

    private func makeCommand(
        _ fixture: Fixture,
        terminalContent: String = Wire.terminalContent,
        orderedSources: [DocumentOutputSourceRecord]? = nil
    ) throws -> GroundedChatTerminalPublicationCommand {
        GroundedChatTerminalPublicationCommand(
            idempotencyKey: Wire.idempotencyKey,
            matterID: fixture.matter.id,
            chatID: fixture.chat.id,
            messageID: fixture.message.id,
            variantID: fixture.variant.id,
            generationSessionID: fixture.generation.id,
            terminalContent: terminalContent,
            runtimeMetrics: StoredRuntimeMetrics(
                loadTimeMs: 317,
                firstTokenLatencyMs: 419,
                tokensPerSecond: 23.75,
                peakMemoryMb: 1_927,
                generatedTokenCount: 83
            ),
            sourceSet: fixture.sourceSet,
            orderedSources: orderedSources ?? fixture.sources,
            citations: fixture.citations,
            verificationDimensions: fixture.verificationDimensions,
            assuranceState: .propositionSupported,
            authorizationEvidenceJSON: Wire.authorizationEvidenceJSON,
            auditEvent: fixture.auditEvent
        )
    }

    private func makeSourceDocument(
        store: SupraStore,
        matterID: String,
        stem: String,
        partIndex: Int,
        charStart: Int,
        excerpt: String
    ) throws -> SourceFixture {
        let text = String(repeating: "p", count: charStart) + excerpt + String(repeating: "s", count: 37)
        let charEnd = charStart + excerpt.count
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "blob-\(stem)",
                sha256: stem.contains("17") ? String(repeating: "1", count: 64) : String(repeating: "2", count: 64),
                byteSize: 8_000 + partIndex,
                originalExtension: "txt",
                managedRelativePath: "blobs/\(stem).txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Date(timeIntervalSince1970: 1_786_700_701 + Double(partIndex))
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: "document-\(stem)",
                matterID: matterID,
                blobID: blob.id,
                displayName: "Synthetic-\(stem).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractedTextChecksum: "checksum-wire-\(stem)",
                pagePartCount: partIndex + 1,
                importedAt: Date(timeIntervalSince1970: 1_786_700_711 + Double(partIndex))
            )
        )
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "revision-\(stem)",
                documentID: document.id,
                partIndex: partIndex,
                derivationKey: "derivation-wire-\(stem)",
                origin: "parser",
                method: "synthetic_terminal_publication",
                text: text,
                charCount: text.count,
                toolchainVersion: "synthetic-parser/wire-731",
                reason: "T-PUB-CHAT exact source fixture",
                createdAt: Date(timeIntervalSince1970: 1_786_700_719 + Double(partIndex))
            )
        )
        let chunk = DocumentChunkRecord(
            id: "chunk-\(stem)",
            documentID: document.id,
            revisionID: revision.id,
            chunkerVersion: 17,
            chunkIndex: partIndex,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: charStart,
            charEnd: charEnd,
            normalizedText: excerpt,
            displayExcerpt: excerpt,
            tokenCount: 31 + partIndex,
            createdAt: Date(timeIntervalSince1970: 1_786_700_727 + Double(partIndex)),
            updatedAt: Date(timeIntervalSince1970: 1_786_700_727 + Double(partIndex))
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        let locatorJSON =
            "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":\(charStart),\"char_end\":\(charEnd)}"
        return SourceFixture(
            document: document,
            revision: revision,
            chunk: chunk,
            locatorJSON: locatorJSON,
            excerpt: excerpt
        )
    }

    private func supportedResult(
        propositionID: String,
        source: DocumentOutputSourceRecord
    ) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: propositionID,
            status: .supported,
            reasons: ["synthetic_exact_grounded_chat_wire"],
            evidence: [
                SupportEvidence(
                    sourceID: source.id,
                    sourceLabel: source.citationLabel,
                    locator: source.locatorJSON,
                    retainedExcerpt: source.excerpt,
                    verifierName: "GroundedTerminalWireVerifier",
                    verifierVersion: "grounded-terminal-wire/731"
                )
            ],
            timestamp: Date(timeIntervalSince1970: 1_786_700_787)
        )
    }
}
