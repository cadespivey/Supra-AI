import CryptoKit
import Foundation
import GRDB
import SupraCore

/// The complete terminal payload for one grounded matter-chat answer. Streaming
/// text remains pending outside this value; this command is the only Store
/// boundary that may make the answer, its evidence, and its audit terminal.
public struct GroundedChatTerminalPublicationCommand: Sendable {
    public let idempotencyKey: String
    public let matterID: String
    public let chatID: String
    public let messageID: String
    public let variantID: String
    public let generationSessionID: String
    public let terminalContent: String
    public let runtimeMetrics: StoredRuntimeMetrics
    public let sourceSet: DocumentSourceSetRecord
    public let orderedSources: [DocumentOutputSourceRecord]
    public let citations: [MessageCitationRecord]
    public let verificationDimensions: VerificationDimensions
    public let assuranceState: OutputAssuranceState
    public let authorizationEvidenceJSON: String
    public let auditEvent: AuditEventRecord

    public init(
        idempotencyKey: String,
        matterID: String,
        chatID: String,
        messageID: String,
        variantID: String,
        generationSessionID: String,
        terminalContent: String,
        runtimeMetrics: StoredRuntimeMetrics,
        sourceSet: DocumentSourceSetRecord,
        orderedSources: [DocumentOutputSourceRecord],
        citations: [MessageCitationRecord],
        verificationDimensions: VerificationDimensions,
        assuranceState: OutputAssuranceState,
        authorizationEvidenceJSON: String,
        auditEvent: AuditEventRecord
    ) {
        self.idempotencyKey = idempotencyKey
        self.matterID = matterID
        self.chatID = chatID
        self.messageID = messageID
        self.variantID = variantID
        self.generationSessionID = generationSessionID
        self.terminalContent = terminalContent
        self.runtimeMetrics = runtimeMetrics
        self.sourceSet = sourceSet
        self.orderedSources = orderedSources
        self.citations = citations
        self.verificationDimensions = verificationDimensions
        self.assuranceState = assuranceState
        self.authorizationEvidenceJSON = authorizationEvidenceJSON
        self.auditEvent = auditEvent
    }
}

/// Content-free durable completion identity. Verification and authorization
/// values are read through the exact source-set owner; the receipt table stores
/// only their digests and stable coordinates, never answer or evidence text.
public struct GroundedChatTerminalPublicationReceipt: Equatable, Sendable {
    public let idempotencyKey: String
    public let aggregateDigestSHA256: String
    public let matterID: String
    public let chatID: String
    public let messageID: String
    public let variantID: String
    public let generationSessionID: String
    public let sourceSetID: String
    public let assuranceState: OutputAssuranceState
    public let verificationDimensions: VerificationDimensions
    public let authorizationEvidenceJSON: String
    public let auditEventID: String
}

public enum GroundedChatTerminalPublicationError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidCommand(String)
    case ownerNotPending(String)
    case idempotencyConflict(String)
    case persistedAggregateMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Grounded-answer publication was cancelled before completion."
        case .invalidCommand(let field):
            "Grounded-answer publication has invalid \(field)."
        case .ownerNotPending(let owner):
            "Grounded-answer publication owner \(owner) is not pending."
        case .idempotencyConflict:
            "This grounded-answer completion key already identifies a different aggregate."
        case .persistedAggregateMismatch:
            "The persisted grounded-answer aggregate no longer matches its completion receipt."
        }
    }
}

/// Store-owned all-or-nothing publication for grounded matter-chat answers.
public final class GroundedChatTerminalPublicationRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func finalize(
        _ command: GroundedChatTerminalPublicationCommand,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) throws -> GroundedChatTerminalPublicationReceipt {
        let incomingDigest = try Self.aggregateDigest(for: command)
        return try writer.write { db in
            if let existing = try GroundedChatPublicationReceiptRecord.fetchOne(
                db,
                key: command.idempotencyKey
            ) {
                guard existing.aggregateDigestSHA256 == incomingDigest else {
                    throw GroundedChatTerminalPublicationError.idempotencyConflict(
                        command.idempotencyKey
                    )
                }
                let persisted = try Self.persistedCommand(for: existing, db: db)
                guard try Self.aggregateDigest(for: persisted) == incomingDigest else {
                    throw GroundedChatTerminalPublicationError.persistedAggregateMismatch(
                        command.idempotencyKey
                    )
                }
                return try Self.receipt(for: existing, db: db)
            }

            guard !cancellationCheck() else {
                throw GroundedChatTerminalPublicationError.cancelled
            }
            let prepared = try Self.validate(command, db: db)
            guard !cancellationCheck() else {
                throw GroundedChatTerminalPublicationError.cancelled
            }

            let completedAt = Date()
            try Self.insertSourceSet(
                command.sourceSet,
                verificationDimensionsJSON: prepared.verificationDimensionsJSON,
                assuranceState: command.assuranceState,
                authorizationEvidenceJSON: command.authorizationEvidenceJSON,
                db: db
            )
            for source in prepared.sources {
                try source.insert(db)
            }
            for citation in command.citations {
                try citation.insert(db)
            }
            try command.auditEvent.insert(db)

            try db.execute(
                sql: """
                    UPDATE message_variants
                    SET content = ?, status = ?, interruption_reason = NULL, updated_at = ?
                    WHERE id = ? AND message_id = ? AND status = ? AND deleted_at IS NULL
                    """,
                arguments: [
                    command.terminalContent,
                    MessageStatus.completed.rawValue,
                    completedAt,
                    command.variantID,
                    command.messageID,
                    MessageStatus.pending.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw GroundedChatTerminalPublicationError.ownerNotPending("variant")
            }
            try db.execute(
                sql: """
                    UPDATE messages
                    SET content = ?, status = ?, updated_at = ?
                    WHERE id = ? AND chat_id = ? AND active_variant_id = ?
                        AND status = ? AND deleted_at IS NULL
                    """,
                arguments: [
                    command.terminalContent,
                    MessageStatus.completed.rawValue,
                    completedAt,
                    command.messageID,
                    command.chatID,
                    command.variantID,
                    MessageStatus.pending.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw GroundedChatTerminalPublicationError.ownerNotPending("message")
            }
            try db.execute(
                sql: """
                    UPDATE generation_sessions
                    SET status = ?, completed_at = ?,
                        load_time_ms = ?, first_token_latency_ms = ?,
                        tokens_per_second = ?, cancellation_latency_ms = ?,
                        peak_memory_mb = ?, generated_token_count = ?,
                        error_summary = NULL, interruption_reason = NULL, updated_at = ?
                    WHERE id = ? AND chat_id = ? AND message_id = ? AND variant_id = ?
                        AND status = ? AND completed_at IS NULL
                    """,
                arguments: [
                    MessageStatus.completed.rawValue,
                    completedAt,
                    command.runtimeMetrics.loadTimeMs,
                    command.runtimeMetrics.firstTokenLatencyMs,
                    command.runtimeMetrics.tokensPerSecond,
                    command.runtimeMetrics.cancellationLatencyMs,
                    command.runtimeMetrics.peakMemoryMb,
                    command.runtimeMetrics.generatedTokenCount,
                    completedAt,
                    command.generationSessionID,
                    command.chatID,
                    command.messageID,
                    command.variantID,
                    MessageStatus.pending.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw GroundedChatTerminalPublicationError.ownerNotPending("generation")
            }
            try db.execute(
                sql: "UPDATE chats SET updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [completedAt, command.chatID]
            )
            guard db.changesCount == 1 else {
                throw GroundedChatTerminalPublicationError.invalidCommand("chat")
            }

            let record = GroundedChatPublicationReceiptRecord(
                idempotencyKey: command.idempotencyKey,
                aggregateDigestSHA256: incomingDigest,
                terminalContentSHA256: Self.sha256(command.terminalContent),
                verificationDimensionsSHA256: Self.sha256(
                    prepared.verificationDimensionsJSON
                ),
                authorizationEvidenceSHA256: Self.sha256(
                    command.authorizationEvidenceJSON
                ),
                matterID: command.matterID,
                chatID: command.chatID,
                messageID: command.messageID,
                variantID: command.variantID,
                generationSessionID: command.generationSessionID,
                sourceSetID: command.sourceSet.id,
                assuranceState: command.assuranceState.rawValue,
                auditEventID: command.auditEvent.id,
                createdAt: completedAt
            )
            try record.insert(db)

            // A cancellation that arrives while the transaction is writing
            // aborts the transaction before GRDB commits it.
            guard !cancellationCheck() else {
                throw GroundedChatTerminalPublicationError.cancelled
            }
            return GroundedChatTerminalPublicationReceipt(
                idempotencyKey: record.idempotencyKey,
                aggregateDigestSHA256: record.aggregateDigestSHA256,
                matterID: record.matterID,
                chatID: record.chatID,
                messageID: record.messageID,
                variantID: record.variantID,
                generationSessionID: record.generationSessionID,
                sourceSetID: record.sourceSetID,
                assuranceState: command.assuranceState,
                verificationDimensions: command.verificationDimensions,
                authorizationEvidenceJSON: command.authorizationEvidenceJSON,
                auditEventID: record.auditEventID
            )
        }
    }

    public func fetchReceipt(
        idempotencyKey: String
    ) throws -> GroundedChatTerminalPublicationReceipt? {
        try writer.read { db in
            guard let record = try GroundedChatPublicationReceiptRecord.fetchOne(
                db,
                key: idempotencyKey
            ) else {
                return nil
            }
            let persisted = try Self.persistedCommand(for: record, db: db)
            guard try Self.aggregateDigest(for: persisted) == record.aggregateDigestSHA256 else {
                throw GroundedChatTerminalPublicationError.persistedAggregateMismatch(
                    idempotencyKey
                )
            }
            return try Self.receipt(for: record, db: db)
        }
    }
}

// MARK: - Validation and reconstruction

private extension GroundedChatTerminalPublicationRepository {
    struct PreparedPublication {
        var sources: [DocumentOutputSourceRecord]
        var verificationDimensionsJSON: String
    }

    static func validate(
        _ command: GroundedChatTerminalPublicationCommand,
        db: Database
    ) throws -> PreparedPublication {
        for (name, value) in [
            ("idempotency key", command.idempotencyKey),
            ("matter identity", command.matterID),
            ("chat identity", command.chatID),
            ("message identity", command.messageID),
            ("variant identity", command.variantID),
            ("generation identity", command.generationSessionID),
            ("terminal content", command.terminalContent),
            ("source-set identity", command.sourceSet.id),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GroundedChatTerminalPublicationError.invalidCommand(name)
        }
        guard command.verificationDimensions.isComplete else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "verification dimensions"
            )
        }
        guard [.preliminary, .supportNeedsReview, .propositionSupported].contains(
            command.assuranceState
        ) else {
            throw GroundedChatTerminalPublicationError.invalidCommand("assurance")
        }
        if command.assuranceState == .propositionSupported {
            guard command.verificationDimensions.satisfies(required: [
                .propositionSupport,
                .citationResolution,
                .criticalValueFidelity,
            ]) else {
                throw GroundedChatTerminalPublicationError.invalidCommand(
                    "proposition-supported verification"
                )
            }
        }
        guard validJSONObject(command.authorizationEvidenceJSON) else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "authorization evidence"
            )
        }

        guard let matter = try MatterRecord.fetchOne(db, key: command.matterID),
              matter.deletedAt == nil else {
            throw GroundedChatTerminalPublicationError.invalidCommand("matter")
        }
        guard let chat = try ChatRecord.fetchOne(db, key: command.chatID),
              chat.deletedAt == nil,
              chat.scope == "matter",
              chat.matterID == command.matterID else {
            throw GroundedChatTerminalPublicationError.invalidCommand("chat owner")
        }
        guard let message = try MessageRecord.fetchOne(db, key: command.messageID),
              message.deletedAt == nil,
              message.chatID == command.chatID,
              message.role == MessageRole.assistant.rawValue,
              message.activeVariantID == command.variantID else {
            throw GroundedChatTerminalPublicationError.invalidCommand("message owner")
        }
        guard message.status == MessageStatus.pending.rawValue else {
            throw GroundedChatTerminalPublicationError.ownerNotPending("message")
        }
        guard let variant = try MessageVariantRecord.fetchOne(db, key: command.variantID),
              variant.deletedAt == nil,
              variant.messageID == command.messageID,
              variant.generationSessionID == command.generationSessionID else {
            throw GroundedChatTerminalPublicationError.invalidCommand("variant owner")
        }
        guard variant.status == MessageStatus.pending.rawValue else {
            throw GroundedChatTerminalPublicationError.ownerNotPending("variant")
        }
        guard let generation = try GenerationSessionRecord.fetchOne(
            db,
            key: command.generationSessionID
        ), generation.chatID == command.chatID,
           generation.messageID == command.messageID,
           generation.variantID == command.variantID else {
            throw GroundedChatTerminalPublicationError.invalidCommand("generation owner")
        }
        guard generation.status == MessageStatus.pending.rawValue,
              generation.completedAt == nil else {
            throw GroundedChatTerminalPublicationError.ownerNotPending("generation")
        }

        guard command.sourceSet.matterID == command.matterID,
              command.sourceSet.messageID == command.messageID,
              command.sourceSet.structuredOutputVersionID == nil,
              command.sourceSet.status == DocumentSourceSetStatus.pending.rawValue else {
            throw GroundedChatTerminalPublicationError.invalidCommand("source-set owner")
        }
        guard !command.orderedSources.isEmpty else {
            throw GroundedChatTerminalPublicationError.invalidCommand("ordered sources")
        }
        try requireStrictlyOrdered(
            command.orderedSources.map { ($0.id, $0.citationLabel, $0.rank) },
            field: "ordered sources"
        )
        try requireStrictlyOrdered(
            command.citations.map { ($0.id, $0.label, $0.rank) },
            field: "ordered citations"
        )

        var preparedSources: [DocumentOutputSourceRecord] = []
        for source in command.orderedSources {
            guard source.sourceSetID == command.sourceSet.id,
                  source.structuredOutputVersionID == nil else {
                throw GroundedChatTerminalPublicationError.invalidCommand(
                    "source-set identity"
                )
            }
            let prepared = try DocumentSourceIntegrityValidator.prepare(
                source,
                sourceSet: command.sourceSet,
                preserveUnknownRevision: false,
                db: db
            )
            guard prepared.revisionID == source.revisionID else {
                throw GroundedChatTerminalPublicationError.invalidCommand(
                    "source revision identity"
                )
            }
            preparedSources.append(prepared)
        }

        let sourceByLabel = Dictionary(
            uniqueKeysWithValues: preparedSources.map { ($0.citationLabel, $0) }
        )
        for citation in command.citations {
            guard citation.messageID == command.messageID,
                  citation.kind == "source",
                  let source = sourceByLabel[citation.label],
                  citation.rank == source.rank,
                  citation.documentID == source.documentID,
                  citation.locatorJSON == source.locatorJSON,
                  citation.matchText == source.excerpt else {
                throw GroundedChatTerminalPublicationError.invalidCommand(
                    "citation identity"
                )
            }
        }
        let retainedTerminalLabels = citationLabels(in: command.terminalContent)
            .filter { sourceByLabel[$0] != nil }
        guard retainedTerminalLabels == Set(command.citations.map(\.label)) else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "terminal citation labels"
            )
        }

        for result in command.verificationDimensions.results {
            for evidence in result.evidence {
                let exactMatches = preparedSources.filter {
                    $0.id == evidence.sourceID
                        && $0.citationLabel == evidence.sourceLabel
                        && $0.locatorJSON == evidence.locator
                        && $0.excerpt == evidence.excerpt
                }
                guard exactMatches.count == 1 else {
                    throw GroundedChatTerminalPublicationError.invalidCommand(
                        "verification evidence"
                    )
                }
            }
        }
        if command.assuranceState == .propositionSupported {
            let reports = Set(preparedSources.compactMap(\.warningsJSON))
            guard reports.count == 1,
                  let reportJSON = reports.first,
                  let results = try? JSONCoding.decode(
                    [PropositionSupportResult].self,
                    from: reportJSON
                  ),
                  !results.isEmpty,
                  results.allSatisfy({ $0.status == .supported }) else {
                throw GroundedChatTerminalPublicationError.invalidCommand(
                    "proposition support report"
                )
            }
            try DocumentSourceIntegrityValidator.validateEvidence(
                results,
                against: preparedSources,
                matterID: command.matterID,
                db: db
            )
        }

        guard command.auditEvent.matterID == command.matterID,
              command.auditEvent.eventType == "grounded_chat_terminal_published",
              command.auditEvent.relatedTable == "messages",
              command.auditEvent.relatedID == command.messageID,
              !command.auditEvent.actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.auditEvent.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.auditEvent.metadataJSON.map(validJSONObject) == true else {
            throw GroundedChatTerminalPublicationError.invalidCommand("audit evidence")
        }

        let collisions = try Int.fetchOne(
            db,
            sql: """
                SELECT
                    (SELECT COUNT(*) FROM grounded_chat_publications
                        WHERE message_id = ? OR variant_id = ?
                            OR generation_session_id = ? OR source_set_id = ?)
                  + (SELECT COUNT(*) FROM document_source_sets WHERE id = ? OR message_id = ?)
                  + (SELECT COUNT(*) FROM document_output_sources
                        WHERE id IN (SELECT value FROM json_each(?)))
                  + (SELECT COUNT(*) FROM message_citations
                        WHERE message_id = ? OR id IN (SELECT value FROM json_each(?)))
                  + (SELECT COUNT(*) FROM audit_events WHERE id = ?)
                """,
            arguments: [
                command.messageID,
                command.variantID,
                command.generationSessionID,
                command.sourceSet.id,
                command.sourceSet.id,
                command.messageID,
                try JSONCoding.encode(preparedSources.map(\.id)),
                command.messageID,
                try JSONCoding.encode(command.citations.map(\.id)),
                command.auditEvent.id,
            ]
        ) ?? 0
        guard collisions == 0 else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "preexisting aggregate identity"
            )
        }

        return PreparedPublication(
            sources: preparedSources,
            verificationDimensionsJSON: try canonicalJSON(
                command.verificationDimensions
            )
        )
    }

    static func persistedCommand(
        for record: GroundedChatPublicationReceiptRecord,
        db: Database
    ) throws -> GroundedChatTerminalPublicationCommand {
        guard let message = try MessageRecord.fetchOne(db, key: record.messageID),
              message.chatID == record.chatID,
              message.activeVariantID == record.variantID,
              message.status == MessageStatus.completed.rawValue,
              let variant = try MessageVariantRecord.fetchOne(db, key: record.variantID),
              variant.messageID == record.messageID,
              variant.generationSessionID == record.generationSessionID,
              variant.status == MessageStatus.completed.rawValue,
              variant.content == message.content,
              let generation = try GenerationSessionRecord.fetchOne(
                db,
                key: record.generationSessionID
              ),
              generation.chatID == record.chatID,
              generation.messageID == record.messageID,
              generation.variantID == record.variantID,
              generation.status == MessageStatus.completed.rawValue,
              generation.completedAt != nil,
              let sourceSet = try DocumentSourceSetRecord.fetchOne(
                db,
                key: record.sourceSetID
              ),
              sourceSet.matterID == record.matterID,
              sourceSet.messageID == record.messageID,
              let terminal = try terminalEvidence(sourceSetID: record.sourceSetID, db: db),
              let assurance = OutputAssuranceState(rawValue: record.assuranceState),
              assurance == terminal.assuranceState,
              let audit = try AuditEventRecord.fetchOne(db, key: record.auditEventID),
              audit.matterID == record.matterID,
              audit.relatedTable == "messages",
              audit.relatedID == record.messageID else {
            throw GroundedChatTerminalPublicationError.persistedAggregateMismatch(
                record.idempotencyKey
            )
        }
        var sources = try DocumentOutputSourceRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM document_output_sources
                WHERE source_set_id = ? ORDER BY rank, id
            """,
            arguments: [record.sourceSetID]
        )
        let isPendingPacket = sourceSet.status == DocumentSourceSetStatus.pending.rawValue
            && sourceSet.structuredOutputVersionID == nil
            && sources.allSatisfy { $0.structuredOutputVersionID == nil }
        let isPromotedPacket = sourceSet.status == DocumentSourceSetStatus.attached.rawValue
            && sourceSet.structuredOutputVersionID != nil
            && sources.allSatisfy {
                $0.structuredOutputVersionID == sourceSet.structuredOutputVersionID
            }
        guard isPendingPacket || isPromotedPacket else {
            throw GroundedChatTerminalPublicationError.persistedAggregateMismatch(
                record.idempotencyKey
            )
        }
        var canonicalSourceSet = sourceSet
        // Save to Outputs is an authorized later transition of this exact
        // packet. Reconstruct the chat publication's original pending view so
        // that attaching the set/version does not invalidate its receipt.
        canonicalSourceSet.structuredOutputVersionID = nil
        canonicalSourceSet.status = DocumentSourceSetStatus.pending.rawValue
        for index in sources.indices {
            sources[index].structuredOutputVersionID = nil
        }
        let citations = try MessageCitationRecord.fetchAll(
            db,
            sql: "SELECT * FROM message_citations WHERE message_id = ? ORDER BY rank, id",
            arguments: [record.messageID]
        )
        return GroundedChatTerminalPublicationCommand(
            idempotencyKey: record.idempotencyKey,
            matterID: record.matterID,
            chatID: record.chatID,
            messageID: record.messageID,
            variantID: record.variantID,
            generationSessionID: record.generationSessionID,
            terminalContent: message.content,
            runtimeMetrics: StoredRuntimeMetrics(
                loadTimeMs: generation.loadTimeMs,
                firstTokenLatencyMs: generation.firstTokenLatencyMs,
                tokensPerSecond: generation.tokensPerSecond,
                cancellationLatencyMs: generation.cancellationLatencyMs,
                peakMemoryMb: generation.peakMemoryMb,
                generatedTokenCount: generation.generatedTokenCount
            ),
            sourceSet: canonicalSourceSet,
            orderedSources: sources,
            citations: citations,
            verificationDimensions: terminal.verificationDimensions,
            assuranceState: assurance,
            authorizationEvidenceJSON: terminal.authorizationEvidenceJSON,
            auditEvent: audit
        )
    }

    static func receipt(
        for record: GroundedChatPublicationReceiptRecord,
        db: Database
    ) throws -> GroundedChatTerminalPublicationReceipt {
        guard let terminal = try terminalEvidence(sourceSetID: record.sourceSetID, db: db),
              let assurance = OutputAssuranceState(rawValue: record.assuranceState),
              assurance == terminal.assuranceState,
              sha256(terminal.verificationDimensionsJSON)
                == record.verificationDimensionsSHA256,
              sha256(terminal.authorizationEvidenceJSON)
                == record.authorizationEvidenceSHA256,
              let message = try MessageRecord.fetchOne(db, key: record.messageID),
              sha256(message.content) == record.terminalContentSHA256 else {
            throw GroundedChatTerminalPublicationError.persistedAggregateMismatch(
                record.idempotencyKey
            )
        }
        return GroundedChatTerminalPublicationReceipt(
            idempotencyKey: record.idempotencyKey,
            aggregateDigestSHA256: record.aggregateDigestSHA256,
            matterID: record.matterID,
            chatID: record.chatID,
            messageID: record.messageID,
            variantID: record.variantID,
            generationSessionID: record.generationSessionID,
            sourceSetID: record.sourceSetID,
            assuranceState: assurance,
            verificationDimensions: terminal.verificationDimensions,
            authorizationEvidenceJSON: terminal.authorizationEvidenceJSON,
            auditEventID: record.auditEventID
        )
    }

    struct TerminalEvidence {
        var verificationDimensions: VerificationDimensions
        var verificationDimensionsJSON: String
        var assuranceState: OutputAssuranceState
        var authorizationEvidenceJSON: String
    }

    static func terminalEvidence(
        sourceSetID: String,
        db: Database
    ) throws -> TerminalEvidence? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT terminal_verification_dimensions_json,
                    terminal_assurance_state, terminal_authorization_evidence_json
                FROM document_source_sets WHERE id = ?
                """,
            arguments: [sourceSetID]
        ), let verificationJSON: String = row["terminal_verification_dimensions_json"],
           let assuranceRaw: String = row["terminal_assurance_state"],
           let assurance = OutputAssuranceState(rawValue: assuranceRaw),
           let authorizationJSON: String = row["terminal_authorization_evidence_json"],
           let dimensions = try? JSONCoding.decode(
            VerificationDimensions.self,
            from: verificationJSON
           ), dimensions.isComplete else {
            return nil
        }
        return TerminalEvidence(
            verificationDimensions: dimensions,
            verificationDimensionsJSON: verificationJSON,
            assuranceState: assurance,
            authorizationEvidenceJSON: authorizationJSON
        )
    }

    static func insertSourceSet(
        _ sourceSet: DocumentSourceSetRecord,
        verificationDimensionsJSON: String,
        assuranceState: OutputAssuranceState,
        authorizationEvidenceJSON: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO document_source_sets (
                    id, matter_id, structured_output_version_id, status, mode,
                    scope_json, retrieval_query, retrieval_depth,
                    packing_report_json, embedding_model_id,
                    embedding_model_revision, chunker_version,
                    retrieval_config_json, corpus_snapshot_hash, message_id,
                    created_at, terminal_verification_dimensions_json,
                    terminal_assurance_state, terminal_authorization_evidence_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sourceSet.id,
                sourceSet.matterID,
                sourceSet.structuredOutputVersionID,
                sourceSet.status,
                sourceSet.mode,
                sourceSet.scopeJSON,
                sourceSet.retrievalQuery,
                sourceSet.retrievalDepth,
                sourceSet.packingReportJSON,
                sourceSet.embeddingModelID,
                sourceSet.embeddingModelRevision,
                sourceSet.chunkerVersion,
                sourceSet.retrievalConfigJSON,
                sourceSet.corpusSnapshotHash,
                sourceSet.messageID,
                sourceSet.createdAt,
                verificationDimensionsJSON,
                assuranceState.rawValue,
                authorizationEvidenceJSON,
            ]
        )
    }

    static func requireStrictlyOrdered(
        _ rows: [(id: String, label: String, rank: Int)],
        field: String
    ) throws {
        guard Set(rows.map(\.id)).count == rows.count,
              Set(rows.map(\.label)).count == rows.count,
              zip(rows, rows.dropFirst()).allSatisfy({ $0.rank < $1.rank }) else {
            throw GroundedChatTerminalPublicationError.invalidCommand(field)
        }
    }

    static func citationLabels(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\[([AS]\d{1,3})\]"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    static func validJSONObject(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }
        return !dictionary.isEmpty
    }

    static func aggregateDigest(
        for command: GroundedChatTerminalPublicationCommand
    ) throws -> String {
        try sha256(canonicalData(AggregateDigestPayload(command: command)))
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try canonicalData(value), as: UTF8.self)
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct AggregateDigestPayload: Encodable {
        var schemaVersion = 1
        var idempotencyKey: String
        var matterID: String
        var chatID: String
        var messageID: String
        var variantID: String
        var generationSessionID: String
        var terminalContent: String
        var runtimeMetrics: StoredRuntimeMetrics
        var sourceSet: DocumentSourceSetRecord
        var orderedSources: [DocumentOutputSourceRecord]
        var citations: [MessageCitationRecord]
        var verificationDimensions: VerificationDimensions
        var assuranceState: OutputAssuranceState
        var authorizationEvidenceJSON: String
        var auditEvent: AuditEventRecord

        init(command: GroundedChatTerminalPublicationCommand) {
            idempotencyKey = command.idempotencyKey
            matterID = command.matterID
            chatID = command.chatID
            messageID = command.messageID
            variantID = command.variantID
            generationSessionID = command.generationSessionID
            terminalContent = command.terminalContent
            runtimeMetrics = command.runtimeMetrics
            sourceSet = command.sourceSet
            orderedSources = command.orderedSources
            citations = command.citations
            verificationDimensions = command.verificationDimensions
            assuranceState = command.assuranceState
            authorizationEvidenceJSON = command.authorizationEvidenceJSON
            auditEvent = command.auditEvent
        }
    }
}

private struct GroundedChatPublicationReceiptRecord:
    Codable, FetchableRecord, PersistableRecord, Sendable
{
    static let databaseTableName = "grounded_chat_publications"

    var idempotencyKey: String
    var aggregateDigestSHA256: String
    var terminalContentSHA256: String
    var verificationDimensionsSHA256: String
    var authorizationEvidenceSHA256: String
    var matterID: String
    var chatID: String
    var messageID: String
    var variantID: String
    var generationSessionID: String
    var sourceSetID: String
    var assuranceState: String
    var auditEventID: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case aggregateDigestSHA256 = "aggregate_digest_sha256"
        case terminalContentSHA256 = "terminal_content_sha256"
        case verificationDimensionsSHA256 = "verification_dimensions_sha256"
        case authorizationEvidenceSHA256 = "authorization_evidence_sha256"
        case matterID = "matter_id"
        case chatID = "chat_id"
        case messageID = "message_id"
        case variantID = "variant_id"
        case generationSessionID = "generation_session_id"
        case sourceSetID = "source_set_id"
        case assuranceState = "assurance_state"
        case auditEventID = "audit_event_id"
        case createdAt = "created_at"
    }
}
