import CryptoKit
import Foundation
import GRDB
import SupraCore

/// Store-owned terminal aggregate for legal research. SupraResearch remains the
/// owner of provider policy and transport; this repository accepts only stable,
/// content-minimized egress identities plus Store-owned research/authority IDs.
public final class ResearchPacketRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func recordExecuted(
        _ command: ResearchPacketExecutionCommand
    ) throws -> ResearchPacketExecutedReceipt {
        let prepared = try Self.prepareExecution(command)
        return try writer.write { db in
            if let existing = try ResearchPacketCandidateRecord.fetchOne(
                db,
                key: prepared.command.executionID
            ) {
                guard existing.executionDigestSHA256 == prepared.executionDigestSHA256,
                      existing.state == .executed else {
                    throw ResearchPacketRepositoryError.conflictingRetry
                }
                let sources = try Self.candidateSources(
                    executionID: existing.executionID,
                    db: db
                )
                return Self.executedReceipt(existing, sources: sources)
            }

            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM matters WHERE id = ? AND deleted_at IS NULL",
                arguments: [prepared.command.matterID]
            ) == 1 else {
                throw ResearchPacketRepositoryError.provenanceMismatch
            }
            guard let session = try ResearchSessionRecord.fetchOne(
                db,
                key: prepared.command.researchSessionID
            ), session.matterID == prepared.command.matterID else {
                throw ResearchPacketRepositoryError.provenanceMismatch
            }
            guard let query = try ResearchQueryRecord.fetchOne(
                db,
                key: prepared.command.researchQueryID
            ), query.researchSessionID == session.id else {
                throw ResearchPacketRepositoryError.provenanceMismatch
            }
            guard query.status == ResearchQueryStatus.completed.rawValue,
                  Data(query.queryText.utf8) == prepared.command.exactQueryBytes else {
                throw ResearchPacketRepositoryError.queryMismatch
            }

            for result in prepared.command.orderedResults {
                guard let stored = try ResearchResultRecord.fetchOne(
                    db,
                    key: result.researchResultID
                ), stored.researchQueryID == query.id,
                   stored.courtlistenerID == result.providerResultID else {
                    throw ResearchPacketRepositoryError.resultMismatch
                }
            }

            let candidate = ResearchPacketCandidateRecord(
                executionID: prepared.command.executionID,
                packetID: prepared.command.packetID,
                matterID: prepared.command.matterID,
                researchSessionID: prepared.command.researchSessionID,
                researchQueryID: prepared.command.researchQueryID,
                state: .executed,
                providerID: prepared.command.providerID,
                egressAuthorityKind: "approved_grant",
                egressGrantID: prepared.grantID,
                egressGrantVersion: prepared.grantVersion,
                exactQuerySHA256: prepared.exactQuerySHA256,
                executionDigestSHA256: prepared.executionDigestSHA256,
                sourceDigestSHA256: nil,
                reviewDigestSHA256: nil,
                reviewerID: nil,
                reviewerAction: nil,
                reviewedAt: nil,
                cancelledBy: nil,
                cancelledAt: nil,
                createdAt: prepared.command.executedAt,
                updatedAt: prepared.command.executedAt
            )
            try candidate.insert(db)
            var candidateSources: [ResearchPacketCandidateSourceRecord] = []
            for (index, result) in prepared.command.orderedResults.enumerated() {
                let source = ResearchPacketCandidateSourceRecord(
                    executionID: candidate.executionID,
                    sourceIndex: index,
                    researchResultID: result.researchResultID,
                    providerResultID: result.providerResultID,
                    authorityID: nil,
                    groundKey: nil,
                    reviewedPropositionBindingSHA256: nil,
                    excerpt: nil,
                    excerptSHA256: nil
                )
                try source.insert(db)
                candidateSources.append(source)
            }
            try AuditEventRecord(
                matterID: candidate.matterID,
                timestamp: prepared.command.executedAt,
                eventType: "research_packet_executed",
                actor: "legal-data-provider",
                summary: "Recorded executed legal research packet",
                relatedTable: ResearchPacketCandidateRecord.databaseTableName,
                relatedID: candidate.executionID,
                metadataJSON: try Self.auditMetadata([
                    "execution_digest_sha256": candidate.executionDigestSHA256,
                    "grant_id": candidate.egressGrantID,
                    "grant_version": candidate.egressGrantVersion,
                    "packet_id": candidate.packetID,
                    "provider_id": candidate.providerID,
                    "query_sha256": candidate.exactQuerySHA256,
                    "result_count": candidateSources.count,
                ])
            ).insert(db)
            return Self.executedReceipt(candidate, sources: candidateSources)
        }
    }

    @discardableResult
    public func recordReviewed(
        _ command: ResearchPacketReviewCommand
    ) throws -> ResearchPacketReviewedReceipt {
        try writer.write { db in
            guard let candidate = try ResearchPacketCandidateRecord.fetchOne(
                db,
                key: command.executionID
            ) else {
                throw ResearchPacketRepositoryError.recordNotFound
            }
            if candidate.state == .cancelled {
                throw ResearchPacketRepositoryError.cancelled
            }
            guard candidate.executionDigestSHA256 == command.expectedExecutionDigestSHA256 else {
                throw ResearchPacketRepositoryError.packetDigestMismatch
            }
            if candidate.state == .reviewed {
                guard candidate.reviewerID == command.reviewerID,
                      candidate.reviewerAction == command.action,
                      candidate.sourceDigestSHA256 == command.expectedSourceDigestSHA256,
                      let reviewDigest = candidate.reviewDigestSHA256 else {
                    throw ResearchPacketRepositoryError.conflictingRetry
                }
                return ResearchPacketReviewedReceipt(
                    packetID: candidate.packetID,
                    executionID: candidate.executionID,
                    state: .reviewed,
                    sourceDigestSHA256: command.expectedSourceDigestSHA256,
                    executionDigestSHA256: candidate.executionDigestSHA256,
                    reviewDigestSHA256: reviewDigest,
                    reviewerID: command.reviewerID,
                    reviewerAction: command.action
                )
            }
            guard candidate.state == .executed else {
                throw ResearchPacketRepositoryError.invalidTransition(
                    expected: .executed,
                    actual: candidate.state
                )
            }
            let reviewer = try Self.requireCanonical(command.reviewerID)
            let storedSources = try Self.candidateSources(
                executionID: candidate.executionID,
                db: db
            )
            guard !storedSources.isEmpty,
                  storedSources.count == command.orderedAuthorities.count else {
                throw ResearchPacketRepositoryError.resultMismatch
            }

            var reviewedSources: [AcceptedResearchPacketSource] = []
            for (index, pair) in zip(storedSources, command.orderedAuthorities).enumerated() {
                let stored = pair.0
                let selection = pair.1
                guard stored.sourceIndex == index,
                      stored.researchResultID == selection.researchResultID,
                      stored.providerResultID == selection.providerResultID,
                      let authority = try AuthorityRecord.fetchOne(db, key: selection.authorityID),
                      authority.matterID == candidate.matterID,
                      authority.researchSessionID == candidate.researchSessionID,
                      authority.researchResultID == selection.researchResultID,
                      authority.courtlistenerID == selection.providerResultID else {
                    throw ResearchPacketRepositoryError.provenanceMismatch
                }
                guard case let .ready(evidence) = AuthorityRepository.reviewedPropositionState(
                    authority: authority,
                    groundKey: selection.groundKey
                ), evidence.bindingSHA256 ==
                    selection.expectedReviewedPropositionBindingSHA256 else {
                    throw ResearchPacketRepositoryError.reviewEvidenceChanged
                }
                reviewedSources.append(AcceptedResearchPacketSource(
                    sourceIndex: index,
                    researchResultID: selection.researchResultID,
                    providerResultID: selection.providerResultID,
                    authorityID: selection.authorityID,
                    groundKey: selection.groundKey,
                    excerpt: evidence.excerpt,
                    excerptSHA256: Self.sha256(Data(evidence.excerpt.utf8)),
                    reviewedPropositionBindingSHA256: evidence.bindingSHA256
                ))
            }
            let sourceDigest = Self.sourceDigest(reviewedSources)
            guard sourceDigest == command.expectedSourceDigestSHA256 else {
                throw ResearchPacketRepositoryError.packetDigestMismatch
            }
            let reviewDigest = Self.reviewDigest(
                candidate: candidate,
                reviewerID: reviewer,
                action: command.action,
                sourceDigestSHA256: sourceDigest,
                reviewedAt: command.reviewedAt
            )

            for source in reviewedSources {
                try db.execute(
                    sql: """
                    UPDATE research_packet_candidate_sources
                    SET authority_id = ?, ground_key = ?,
                        reviewed_proposition_binding_sha256 = ?, excerpt = ?,
                        excerpt_sha256 = ?
                    WHERE execution_id = ? AND source_index = ?
                    """,
                    arguments: [
                        source.authorityID,
                        source.groundKey.rawValue,
                        source.reviewedPropositionBindingSHA256,
                        source.excerpt,
                        source.excerptSHA256,
                        candidate.executionID,
                        source.sourceIndex,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw ResearchPacketRepositoryError.resultMismatch
                }
            }
            try db.execute(
                sql: """
                UPDATE research_packet_candidates
                SET state = ?, source_digest_sha256 = ?, review_digest_sha256 = ?,
                    reviewer_id = ?, reviewer_action = ?, reviewed_at = ?, updated_at = ?
                WHERE id = ? AND state = ?
                """,
                arguments: [
                    ResearchPacketState.reviewed.rawValue,
                    sourceDigest,
                    reviewDigest,
                    reviewer,
                    command.action.rawValue,
                    command.reviewedAt,
                    command.reviewedAt,
                    candidate.executionID,
                    ResearchPacketState.executed.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw ResearchPacketRepositoryError.conflictingRetry
            }
            try AuditEventRecord(
                matterID: candidate.matterID,
                timestamp: command.reviewedAt,
                eventType: "research_packet_reviewed",
                actor: reviewer,
                summary: "Reviewed legal research packet",
                relatedTable: ResearchPacketCandidateRecord.databaseTableName,
                relatedID: candidate.executionID,
                metadataJSON: try Self.auditMetadata([
                    "packet_id": candidate.packetID,
                    "review_digest_sha256": reviewDigest,
                    "reviewer_action": command.action.rawValue,
                    "source_digest_sha256": sourceDigest,
                    "source_count": reviewedSources.count,
                ])
            ).insert(db)
            return ResearchPacketReviewedReceipt(
                packetID: candidate.packetID,
                executionID: candidate.executionID,
                state: .reviewed,
                sourceDigestSHA256: sourceDigest,
                executionDigestSHA256: candidate.executionDigestSHA256,
                reviewDigestSHA256: reviewDigest,
                reviewerID: reviewer,
                reviewerAction: command.action
            )
        }
    }

    @discardableResult
    public func cancel(
        executionID: String,
        expectedExecutionDigestSHA256: String,
        cancelledBy: String,
        cancelledAt: Date
    ) throws -> ResearchPacketCandidateRecord {
        let actor = try Self.requireCanonical(cancelledBy)
        return try writer.write { db in
            guard let candidate = try ResearchPacketCandidateRecord.fetchOne(
                db,
                key: executionID
            ) else {
                throw ResearchPacketRepositoryError.recordNotFound
            }
            guard candidate.executionDigestSHA256 == expectedExecutionDigestSHA256 else {
                throw ResearchPacketRepositoryError.packetDigestMismatch
            }
            if candidate.state == .cancelled {
                return candidate
            }
            guard candidate.state == .executed || candidate.state == .reviewed else {
                throw ResearchPacketRepositoryError.invalidTransition(
                    expected: .cancelled,
                    actual: candidate.state
                )
            }
            try db.execute(
                sql: """
                UPDATE research_packet_candidates
                SET state = ?, cancelled_by = ?, cancelled_at = ?, updated_at = ?
                WHERE id = ? AND state = ?
                """,
                arguments: [
                    ResearchPacketState.cancelled.rawValue,
                    actor,
                    cancelledAt,
                    cancelledAt,
                    executionID,
                    candidate.state.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw ResearchPacketRepositoryError.conflictingRetry
            }
            try AuditEventRecord(
                matterID: candidate.matterID,
                timestamp: cancelledAt,
                eventType: "research_packet_cancelled",
                actor: actor,
                summary: "Cancelled legal research packet",
                relatedTable: ResearchPacketCandidateRecord.databaseTableName,
                relatedID: executionID,
                metadataJSON: try Self.auditMetadata([
                    "execution_digest_sha256": candidate.executionDigestSHA256,
                    "packet_id": candidate.packetID,
                ])
            ).insert(db)
            guard let cancelled = try ResearchPacketCandidateRecord.fetchOne(
                db,
                key: executionID
            ) else {
                throw ResearchPacketRepositoryError.recordNotFound
            }
            return cancelled
        }
    }

    @discardableResult
    public func accept(
        _ command: ResearchPacketAcceptanceCommand
    ) throws -> AcceptedResearchPacketVersion {
        try writer.write { db in
            guard let candidate = try ResearchPacketCandidateRecord.fetchOne(
                db,
                key: command.executionID
            ) else {
                throw ResearchPacketRepositoryError.recordNotFound
            }
            if candidate.state == .cancelled {
                throw ResearchPacketRepositoryError.cancelled
            }
            let requestDigest = Self.acceptanceRequestDigest(
                command: command,
                candidate: candidate
            )
            if let receipt = try ResearchPacketAcceptanceReceiptRecord.fetchOne(
                db,
                key: command.idempotencyKey
            ) {
                guard receipt.requestDigestSHA256 == requestDigest else {
                    throw ResearchPacketRepositoryError.conflictingRetry
                }
                guard let accepted = try Self.acceptedVersion(
                    id: receipt.acceptedVersionID,
                    db: db
                ) else {
                    throw ResearchPacketRepositoryError.versionUnavailable
                }
                return accepted
            }
            guard candidate.state == .reviewed else {
                throw ResearchPacketRepositoryError.invalidTransition(
                    expected: .reviewed,
                    actual: candidate.state
                )
            }
            guard let reviewDigest = candidate.reviewDigestSHA256,
                  reviewDigest == command.expectedReviewDigestSHA256,
                  let sourceDigest = candidate.sourceDigestSHA256,
                  let reviewerID = candidate.reviewerID,
                  let reviewerAction = candidate.reviewerAction else {
                throw ResearchPacketRepositoryError.packetDigestMismatch
            }
            let sources = try Self.reviewedSources(
                candidate: candidate,
                revalidateAuthorityEvidence: true,
                db: db
            )
            guard Self.sourceDigest(sources) == sourceDigest else {
                throw ResearchPacketRepositoryError.reviewEvidenceChanged
            }
            let versionIndex = try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(MAX(version_index), 0) + 1
                FROM accepted_research_packet_versions WHERE packet_id = ?
                """,
                arguments: [candidate.packetID]
            ) ?? 1
            let audit = AuditEventRecord(
                matterID: candidate.matterID,
                timestamp: command.acceptedAt,
                eventType: "research_packet_accepted",
                actor: reviewerID,
                summary: "Accepted legal research packet version",
                relatedTable: AcceptedResearchPacketVersionRecord.databaseTableName,
                relatedID: command.acceptedVersionID
            )
            let aggregateDigest = Self.aggregateDigest(
                versionID: command.acceptedVersionID,
                packetID: candidate.packetID,
                executionID: candidate.executionID,
                versionIndex: versionIndex,
                candidate: candidate,
                sourceDigestSHA256: sourceDigest,
                reviewDigestSHA256: reviewDigest,
                reviewerID: reviewerID,
                reviewerAction: reviewerAction,
                acceptedAt: command.acceptedAt,
                sources: sources
            )
            var acceptanceAudit = audit
            acceptanceAudit.metadataJSON = try Self.auditMetadata([
                "aggregate_digest_sha256": aggregateDigest,
                "execution_id": candidate.executionID,
                "grant_id": candidate.egressGrantID,
                "grant_version": candidate.egressGrantVersion,
                "packet_id": candidate.packetID,
                "packet_version_id": command.acceptedVersionID,
                "packet_version_index": versionIndex,
                "provider_id": candidate.providerID,
                "query_sha256": candidate.exactQuerySHA256,
                "review_digest_sha256": reviewDigest,
                "reviewer_action": reviewerAction.rawValue,
                "source_digest_sha256": sourceDigest,
                "source_count": sources.count,
            ])
            try acceptanceAudit.insert(db)

            let record = AcceptedResearchPacketVersionRecord(
                id: command.acceptedVersionID,
                packetID: candidate.packetID,
                executionID: candidate.executionID,
                versionIndex: versionIndex,
                state: .accepted,
                matterID: candidate.matterID,
                researchSessionID: candidate.researchSessionID,
                researchQueryID: candidate.researchQueryID,
                providerID: candidate.providerID,
                egressGrantID: candidate.egressGrantID,
                egressGrantVersion: candidate.egressGrantVersion,
                exactQuerySHA256: candidate.exactQuerySHA256,
                sourceDigestSHA256: sourceDigest,
                reviewDigestSHA256: reviewDigest,
                reviewerID: reviewerID,
                reviewerAction: reviewerAction,
                aggregateDigestSHA256: aggregateDigest,
                auditEventID: acceptanceAudit.id,
                acceptedAt: command.acceptedAt
            )
            try record.insert(db)
            for source in sources {
                try AcceptedResearchPacketSourceRecord(
                    packetVersionID: record.id,
                    sourceIndex: source.sourceIndex,
                    researchResultID: source.researchResultID,
                    providerResultID: source.providerResultID,
                    authorityID: source.authorityID,
                    groundKey: source.groundKey.rawValue,
                    excerpt: source.excerpt,
                    excerptSHA256: source.excerptSHA256,
                    reviewedPropositionBindingSHA256:
                        source.reviewedPropositionBindingSHA256
                ).insert(db)
            }
            try ResearchPacketAcceptanceReceiptRecord(
                idempotencyKey: command.idempotencyKey,
                requestDigestSHA256: requestDigest,
                acceptedVersionID: record.id,
                createdAt: command.acceptedAt
            ).insert(db)
            try db.execute(
                sql: """
                UPDATE research_packet_candidates
                SET state = ?, updated_at = ?
                WHERE id = ? AND state = ?
                """,
                arguments: [
                    ResearchPacketState.accepted.rawValue,
                    command.acceptedAt,
                    candidate.executionID,
                    ResearchPacketState.reviewed.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw ResearchPacketRepositoryError.conflictingRetry
            }
            return Self.project(record, sources: sources)
        }
    }

    public func candidate(
        executionID: String
    ) throws -> ResearchPacketCandidateRecord? {
        try writer.read { db in
            try ResearchPacketCandidateRecord.fetchOne(db, key: executionID)
        }
    }

    public func acceptedVersion(
        id: String
    ) throws -> AcceptedResearchPacketVersion? {
        try writer.read { db in
            try Self.acceptedVersion(id: id, db: db)
        }
    }

    public func acceptedVersions(
        packetID: String
    ) throws -> [AcceptedResearchPacketVersion] {
        try writer.read { db in
            let records = try AcceptedResearchPacketVersionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM accepted_research_packet_versions
                WHERE packet_id = ? ORDER BY version_index, id
                """,
                arguments: [packetID]
            )
            return try records.map { record in
                Self.project(
                    record,
                    sources: try Self.acceptedSources(versionID: record.id, db: db)
                )
            }
        }
    }

    @discardableResult
    public func bindAcceptedVersion(
        _ command: ResearchPacketWorkProductBindingCommand
    ) throws -> ResearchPacketWorkProductBinding {
        let requestDigest = Self.workProductBindingRequestDigest(command)
        return try writer.write { db in
            if let existing = try ResearchPacketWorkProductBinding.fetchOne(
                db,
                key: command.structuredOutputVersionID
            ) {
                guard existing.requestDigestSHA256 == requestDigest else {
                    throw ResearchPacketRepositoryError.workProductAlreadyBound
                }
                return existing
            }
            guard let version = try AcceptedResearchPacketVersionRecord.fetchOne(
                db,
                key: command.acceptedPacketVersionID
            ) else {
                throw ResearchPacketRepositoryError.versionUnavailable
            }
            guard version.aggregateDigestSHA256 ==
                    command.expectedPacketAggregateDigestSHA256 else {
                throw ResearchPacketRepositoryError.packetDigestMismatch
            }
            guard try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM research_packet_version_dispositions
                WHERE packet_version_id = ? AND kind = 'revoked'
                """,
                arguments: [version.id]
            ) == 0 else {
                throw ResearchPacketRepositoryError.versionUnavailable
            }
            guard let outputMatterID = try String.fetchOne(
                db,
                sql: """
                SELECT output.matter_id
                FROM structured_output_versions AS version
                JOIN structured_outputs AS output
                  ON output.id = version.structured_output_id
                WHERE version.id = ? AND output.deleted_at IS NULL
                """,
                arguments: [command.structuredOutputVersionID]
            ) else {
                throw ResearchPacketRepositoryError.versionUnavailable
            }
            guard outputMatterID == version.matterID else {
                throw ResearchPacketRepositoryError.crossMatter
            }
            let audit = AuditEventRecord(
                matterID: version.matterID,
                timestamp: command.boundAt,
                eventType: "research_packet_work_product_bound",
                actor: "store",
                summary: "Bound work product to accepted research packet version",
                relatedTable: StructuredOutputVersionRecord.databaseTableName,
                relatedID: command.structuredOutputVersionID,
                metadataJSON: try Self.auditMetadata([
                    "packet_aggregate_digest_sha256": version.aggregateDigestSHA256,
                    "packet_version_id": version.id,
                    "structured_output_version_id": command.structuredOutputVersionID,
                ])
            )
            try audit.insert(db)
            let binding = ResearchPacketWorkProductBinding(
                idempotencyKey: try Self.requireCanonical(command.idempotencyKey),
                requestDigestSHA256: requestDigest,
                structuredOutputVersionID: command.structuredOutputVersionID,
                acceptedPacketVersionID: version.id,
                packetAggregateDigestSHA256: version.aggregateDigestSHA256,
                createdAt: command.boundAt,
                auditEventID: audit.id
            )
            do {
                try binding.insert(db)
            } catch {
                if try ResearchPacketWorkProductBinding.fetchOne(
                    db,
                    key: command.structuredOutputVersionID
                ) != nil {
                    throw ResearchPacketRepositoryError.workProductAlreadyBound
                }
                throw error
            }
            return binding
        }
    }

    public func workProductBinding(
        structuredOutputVersionID: String
    ) throws -> ResearchPacketWorkProductBinding? {
        try writer.read { db in
            try ResearchPacketWorkProductBinding.fetchOne(
                db,
                key: structuredOutputVersionID
            )
        }
    }

    @discardableResult
    public func recordDisposition(
        _ command: ResearchPacketVersionDispositionCommand
    ) throws -> ResearchPacketVersionDisposition {
        let actor = try Self.requireCanonical(command.actor)
        let reason = try Self.requireCanonical(command.reason)
        let idempotencyKey = try Self.requireCanonical(command.idempotencyKey)
        let requestDigest = Self.dispositionRequestDigest(command)
        return try writer.write { db in
            if let existing = try ResearchPacketVersionDisposition.fetchOne(
                db,
                key: idempotencyKey
            ) {
                guard existing.requestDigestSHA256 == requestDigest else {
                    throw ResearchPacketRepositoryError.conflictingRetry
                }
                return existing
            }
            guard let version = try AcceptedResearchPacketVersionRecord.fetchOne(
                db,
                key: command.packetVersionID
            ) else {
                throw ResearchPacketRepositoryError.versionUnavailable
            }
            switch command.kind {
            case .superseded:
                guard let replacementID = command.replacementPacketVersionID,
                      replacementID != version.id,
                      let replacement = try AcceptedResearchPacketVersionRecord.fetchOne(
                        db,
                        key: replacementID
                      ), replacement.packetID == version.packetID else {
                    throw ResearchPacketRepositoryError.invalidDisposition
                }
            case .revoked:
                guard command.replacementPacketVersionID == nil else {
                    throw ResearchPacketRepositoryError.invalidDisposition
                }
            }
            var metadata: [String: Any] = [
                "kind": command.kind.rawValue,
                "packet_version_id": version.id,
                "reason_sha256": Self.sha256(Data(reason.utf8)),
            ]
            if let replacementID = command.replacementPacketVersionID {
                metadata["replacement_packet_version_id"] = replacementID
            }
            let audit = AuditEventRecord(
                matterID: version.matterID,
                timestamp: command.occurredAt,
                eventType: "research_packet_version_\(command.kind.rawValue)",
                actor: actor,
                summary: "Recorded accepted research packet disposition",
                relatedTable: AcceptedResearchPacketVersionRecord.databaseTableName,
                relatedID: version.id,
                metadataJSON: try Self.auditMetadata(metadata)
            )
            try audit.insert(db)
            let disposition = ResearchPacketVersionDisposition(
                idempotencyKey: idempotencyKey,
                requestDigestSHA256: requestDigest,
                packetVersionID: version.id,
                kind: command.kind,
                replacementPacketVersionID: command.replacementPacketVersionID,
                actor: actor,
                reason: reason,
                occurredAt: command.occurredAt,
                auditEventID: audit.id
            )
            try disposition.insert(db)
            return disposition
        }
    }

    // MARK: - Validation and projections

    private struct PreparedExecution {
        let command: ResearchPacketExecutionCommand
        let grantID: String
        let grantVersion: Int
        let exactQuerySHA256: String
        let executionDigestSHA256: String
    }

    private static func prepareExecution(
        _ command: ResearchPacketExecutionCommand
    ) throws -> PreparedExecution {
        _ = try requireCanonical(command.packetID)
        _ = try requireCanonical(command.executionID)
        _ = try requireCanonical(command.matterID)
        _ = try requireCanonical(command.researchSessionID)
        _ = try requireCanonical(command.researchQueryID)
        _ = try requireCanonical(command.providerID)
        guard !command.exactQueryBytes.isEmpty,
              let query = String(data: command.exactQueryBytes, encoding: .utf8),
              Data(query.utf8) == command.exactQueryBytes,
              !command.orderedResults.isEmpty,
              Set(command.orderedResults.map(\.researchResultID)).count ==
                command.orderedResults.count,
              Set(command.orderedResults.map(\.providerResultID)).count ==
                command.orderedResults.count else {
            throw ResearchPacketRepositoryError.invalidCommand
        }
        let grantID: String
        let grantVersion: Int
        switch command.egressAuthority {
        case let .approvedGrant(id, version):
            grantID = try requireCanonical(id)
            grantVersion = version
        }
        guard grantVersion > 0 else {
            throw ResearchPacketRepositoryError.invalidCommand
        }
        for result in command.orderedResults {
            _ = try requireCanonical(result.researchResultID)
            _ = try requireCanonical(result.providerResultID)
        }
        let queryDigest = sha256(command.exactQueryBytes)
        var fields = [
            "research-packet-execution-v1",
            command.packetID,
            command.executionID,
            command.matterID,
            command.researchSessionID,
            command.researchQueryID,
            command.providerID,
            "approved_grant",
            grantID,
            String(grantVersion),
            queryDigest,
            dateKey(command.executedAt),
        ]
        for (index, result) in command.orderedResults.enumerated() {
            fields += [
                String(index),
                result.researchResultID,
                result.providerResultID,
            ]
        }
        return PreparedExecution(
            command: command,
            grantID: grantID,
            grantVersion: grantVersion,
            exactQuerySHA256: queryDigest,
            executionDigestSHA256: canonicalDigest(fields)
        )
    }

    private static func executedReceipt(
        _ candidate: ResearchPacketCandidateRecord,
        sources: [ResearchPacketCandidateSourceRecord]
    ) -> ResearchPacketExecutedReceipt {
        ResearchPacketExecutedReceipt(
            packetID: candidate.packetID,
            executionID: candidate.executionID,
            state: candidate.state,
            matterID: candidate.matterID,
            researchSessionID: candidate.researchSessionID,
            researchQueryID: candidate.researchQueryID,
            providerID: candidate.providerID,
            egressGrantID: candidate.egressGrantID,
            egressGrantVersion: candidate.egressGrantVersion,
            exactQuerySHA256: candidate.exactQuerySHA256,
            executionDigestSHA256: candidate.executionDigestSHA256,
            orderedResearchResultIDs: sources.map(\.researchResultID),
            orderedProviderResultIDs: sources.map(\.providerResultID)
        )
    }

    private static func candidateSources(
        executionID: String,
        db: Database
    ) throws -> [ResearchPacketCandidateSourceRecord] {
        try ResearchPacketCandidateSourceRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM research_packet_candidate_sources
            WHERE execution_id = ? ORDER BY source_index
            """,
            arguments: [executionID]
        )
    }

    private static func reviewedSources(
        candidate: ResearchPacketCandidateRecord,
        revalidateAuthorityEvidence: Bool,
        db: Database
    ) throws -> [AcceptedResearchPacketSource] {
        try candidateSources(executionID: candidate.executionID, db: db).map { stored in
            guard let authorityID = stored.authorityID,
                  let groundRaw = stored.groundKey,
                  let ground = AuthorityReviewedPropositionGround(rawValue: groundRaw),
                  let binding = stored.reviewedPropositionBindingSHA256,
                  let excerpt = stored.excerpt,
                  let excerptSHA256 = stored.excerptSHA256,
                  excerptSHA256 == sha256(Data(excerpt.utf8)) else {
                throw ResearchPacketRepositoryError.reviewEvidenceChanged
            }
            if revalidateAuthorityEvidence {
                guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID),
                      authority.matterID == candidate.matterID,
                      authority.researchSessionID == candidate.researchSessionID,
                      authority.researchResultID == stored.researchResultID,
                      authority.courtlistenerID == stored.providerResultID,
                      case let .ready(evidence) =
                        AuthorityRepository.reviewedPropositionState(
                            authority: authority,
                            groundKey: ground
                        ),
                      evidence.bindingSHA256 == binding,
                      evidence.excerpt == excerpt else {
                    throw ResearchPacketRepositoryError.reviewEvidenceChanged
                }
            }
            return AcceptedResearchPacketSource(
                sourceIndex: stored.sourceIndex,
                researchResultID: stored.researchResultID,
                providerResultID: stored.providerResultID,
                authorityID: authorityID,
                groundKey: ground,
                excerpt: excerpt,
                excerptSHA256: excerptSHA256,
                reviewedPropositionBindingSHA256: binding
            )
        }
    }

    private static func acceptedSources(
        versionID: String,
        db: Database
    ) throws -> [AcceptedResearchPacketSource] {
        try AcceptedResearchPacketSourceRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM accepted_research_packet_sources
            WHERE packet_version_id = ? ORDER BY source_index
            """,
            arguments: [versionID]
        ).map { record in
            guard let ground = AuthorityReviewedPropositionGround(rawValue: record.groundKey) else {
                throw ResearchPacketRepositoryError.reviewEvidenceChanged
            }
            return AcceptedResearchPacketSource(
                sourceIndex: record.sourceIndex,
                researchResultID: record.researchResultID,
                providerResultID: record.providerResultID,
                authorityID: record.authorityID,
                groundKey: ground,
                excerpt: record.excerpt,
                excerptSHA256: record.excerptSHA256,
                reviewedPropositionBindingSHA256:
                    record.reviewedPropositionBindingSHA256
            )
        }
    }

    private static func acceptedVersion(
        id: String,
        db: Database
    ) throws -> AcceptedResearchPacketVersion? {
        guard let record = try AcceptedResearchPacketVersionRecord.fetchOne(db, key: id) else {
            return nil
        }
        return try project(record, sources: acceptedSources(versionID: id, db: db))
    }

    private static func project(
        _ record: AcceptedResearchPacketVersionRecord,
        sources: [AcceptedResearchPacketSource]
    ) -> AcceptedResearchPacketVersion {
        AcceptedResearchPacketVersion(
            id: record.id,
            packetID: record.packetID,
            executionID: record.executionID,
            versionIndex: record.versionIndex,
            state: record.state,
            matterID: record.matterID,
            researchSessionID: record.researchSessionID,
            researchQueryID: record.researchQueryID,
            providerID: record.providerID,
            egressGrantID: record.egressGrantID,
            egressGrantVersion: record.egressGrantVersion,
            exactQuerySHA256: record.exactQuerySHA256,
            sourceDigestSHA256: record.sourceDigestSHA256,
            reviewDigestSHA256: record.reviewDigestSHA256,
            reviewerID: record.reviewerID,
            reviewerAction: record.reviewerAction,
            aggregateDigestSHA256: record.aggregateDigestSHA256,
            auditEventID: record.auditEventID,
            acceptedAt: record.acceptedAt,
            sources: sources
        )
    }

    // MARK: - Digests

    private static func sourceDigest(
        _ sources: [AcceptedResearchPacketSource]
    ) -> String {
        var fields = ["accepted-research-packet-sources-v1"]
        for source in sources {
            fields += [
                String(source.sourceIndex),
                source.researchResultID,
                source.providerResultID,
                source.authorityID,
                source.reviewedPropositionBindingSHA256,
                source.excerpt,
            ]
        }
        return canonicalDigest(fields)
    }

    private static func reviewDigest(
        candidate: ResearchPacketCandidateRecord,
        reviewerID: String,
        action: ResearchPacketReviewerAction,
        sourceDigestSHA256: String,
        reviewedAt: Date
    ) -> String {
        canonicalDigest([
            "research-packet-review-v1",
            candidate.executionDigestSHA256,
            reviewerID,
            action.rawValue,
            sourceDigestSHA256,
            dateKey(reviewedAt),
        ])
    }

    private static func acceptanceRequestDigest(
        command: ResearchPacketAcceptanceCommand,
        candidate: ResearchPacketCandidateRecord
    ) -> String {
        canonicalDigest([
            "research-packet-acceptance-request-v1",
            command.idempotencyKey,
            command.acceptedVersionID,
            command.executionID,
            command.expectedReviewDigestSHA256,
            candidate.packetID,
            candidate.executionDigestSHA256,
            candidate.sourceDigestSHA256 ?? "",
            candidate.reviewDigestSHA256 ?? "",
            dateKey(command.acceptedAt),
        ])
    }

    private static func aggregateDigest(
        versionID: String,
        packetID: String,
        executionID: String,
        versionIndex: Int,
        candidate: ResearchPacketCandidateRecord,
        sourceDigestSHA256: String,
        reviewDigestSHA256: String,
        reviewerID: String,
        reviewerAction: ResearchPacketReviewerAction,
        acceptedAt: Date,
        sources: [AcceptedResearchPacketSource]
    ) -> String {
        var fields = [
            "accepted-research-packet-v1",
            versionID,
            packetID,
            executionID,
            String(versionIndex),
            candidate.matterID,
            candidate.researchSessionID,
            candidate.researchQueryID,
            candidate.providerID,
            candidate.egressGrantID,
            String(candidate.egressGrantVersion),
            candidate.exactQuerySHA256,
            sourceDigestSHA256,
            reviewDigestSHA256,
            reviewerID,
            reviewerAction.rawValue,
            dateKey(acceptedAt),
        ]
        for source in sources {
            fields += [
                String(source.sourceIndex),
                source.researchResultID,
                source.providerResultID,
                source.authorityID,
                source.groundKey.rawValue,
                source.reviewedPropositionBindingSHA256,
                source.excerptSHA256,
            ]
        }
        return canonicalDigest(fields)
    }

    private static func workProductBindingRequestDigest(
        _ command: ResearchPacketWorkProductBindingCommand
    ) -> String {
        canonicalDigest([
            "research-packet-work-product-binding-v1",
            command.idempotencyKey,
            command.structuredOutputVersionID,
            command.acceptedPacketVersionID,
            command.expectedPacketAggregateDigestSHA256,
            dateKey(command.boundAt),
        ])
    }

    private static func dispositionRequestDigest(
        _ command: ResearchPacketVersionDispositionCommand
    ) -> String {
        canonicalDigest([
            "research-packet-version-disposition-v1",
            command.idempotencyKey,
            command.packetVersionID,
            command.kind.rawValue,
            command.replacementPacketVersionID ?? "",
            command.actor,
            command.reason,
            dateKey(command.occurredAt),
        ])
    }

    private static func canonicalDigest(_ values: [String]) -> String {
        let canonical = values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return sha256(Data(canonical.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dateKey(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func requireCanonical(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw ResearchPacketRepositoryError.invalidCommand
        }
        return trimmed
    }

    private static func auditMetadata(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
