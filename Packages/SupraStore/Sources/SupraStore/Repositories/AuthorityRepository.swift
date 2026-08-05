import CryptoKit
import Foundation
import GRDB
import SupraCore

public final class AuthorityRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func insertAuthority(_ authority: AuthorityRecord) throws -> AuthorityRecord {
        try writer.write { db in
            guard authority.reviewedPropositionJSON == nil else {
                throw AuthorityRepositoryError.untrustedPropositionEvidenceOnInsert
            }
            try Self.validateResearchProvenance(authority: authority, db: db)

            if let persisted = try AuthorityRecord.fetchOne(db, key: authority.id) {
                guard Self.hasSameSourceIdentity(persisted, authority) else {
                    throw AuthorityRepositoryError.authorityConflict
                }
                return persisted
            }
            if try AuthorityRecord.fetchOne(
                db,
                sql: "SELECT * FROM authorities WHERE matter_id = ? AND research_result_id = ?",
                arguments: [authority.matterID, authority.researchResultID]
            ) != nil {
                throw AuthorityRepositoryError.authorityConflict
            }

            try authority.insert(db)
            guard let persisted = try AuthorityRecord.fetchOne(db, key: authority.id) else {
                throw AuthorityRepositoryError.authorityConflict
            }
            return persisted
        }
    }

    /// Low-level package-scoped mutation used by Store lifecycle tests that
    /// deliberately simulate eligibility drift. User-facing transitions must
    /// use `transitionUseStatus`, which enforces the graph and audit atomically.
    package func updateUseStatus(
        authorityID: String,
        useStatus: AuthorityUseStatus
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE authorities
                SET use_status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [useStatus.rawValue, Date(), authorityID]
            )
        }
    }

    /// Applies one user-directed use-status transition to the exact live,
    /// matter-scoped authority and records its audit in the same transaction.
    /// The current state is read inside the write transaction so a stale UI or
    /// research snapshot can neither authorize an illegal edge nor duplicate an
    /// edge another writer already completed.
    @discardableResult
    public func transitionUseStatus(
        authorityID: String,
        matterID: String,
        to target: AuthorityUseStatus,
        actor: String,
        changedAt: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID),
                  authority.matterID == matterID else {
                throw AuthorityRepositoryError.authorityNotFound
            }
            guard authority.deletedAt == nil else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            guard let current = AuthorityUseStatus(rawValue: authority.useStatus),
                  current != target,
                  current.canTransition(to: target) else {
                return false
            }
            let normalizedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedActor.isEmpty else {
                throw AuthorityRepositoryError.reviewerRequired
            }

            try db.execute(
                sql: """
                    UPDATE authorities
                    SET use_status = ?, updated_at = ?
                    WHERE id = ?
                      AND matter_id = ?
                      AND deleted_at IS NULL
                      AND use_status = ?
                    """,
                arguments: [target.rawValue, changedAt, authorityID, matterID, current.rawValue]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            try AuditEventRecord(
                matterID: matterID,
                timestamp: changedAt,
                eventType: "authority_status_changed",
                actor: normalizedActor,
                summary: "“\(authority.caseName)”: \(current.displayName) → \(target.displayName)",
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: authority.id
            ).insert(db)
            return true
        }
    }

    public func updateReviewState(
        authorityID: String,
        reviewState: ResearchResultReviewState
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE authorities
                SET review_state = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [reviewState.rawValue, Date(), authorityID]
            )
        }
    }

    /// Marks a saved authority and its originating result not adverse and records
    /// the review-state audit in one transaction. Any provenance, result, or audit
    /// failure rolls the entire state transition back.
    @discardableResult
    public func markNotAdverse(
        authorityID: String,
        matterID: String,
        actor: String,
        markedAt: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID),
                  authority.matterID == matterID else {
                throw AuthorityRepositoryError.authorityNotFound
            }
            guard authority.deletedAt == nil else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            try Self.validateResearchProvenance(authority: authority, db: db)
            guard let result = try ResearchResultRecord.fetchOne(db, key: authority.researchResultID) else {
                throw AuthorityRepositoryError.authorityProvenanceMismatch
            }
            let normalizedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedActor.isEmpty else {
                throw AuthorityRepositoryError.reviewerRequired
            }

            let target = ResearchResultReviewState.notAdverse.rawValue
            guard authority.reviewState != target || result.reviewState != target else {
                return false
            }
            try db.execute(
                sql: "UPDATE authorities SET review_state = ?, updated_at = ? WHERE id = ? AND matter_id = ? AND deleted_at IS NULL",
                arguments: [target, markedAt, authorityID, matterID]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            try db.execute(
                sql: "UPDATE research_results SET review_state = ?, updated_at = ? WHERE id = ?",
                arguments: [target, markedAt, authority.researchResultID]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.authorityProvenanceMismatch
            }
            try AuditEventRecord(
                matterID: matterID,
                timestamp: markedAt,
                eventType: "authority_review_state_changed",
                actor: normalizedActor,
                summary: "Marked authority not adverse: “\(authority.caseName)”",
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: authority.id
            ).insert(db)
            return true
        }
    }

    /// Marks a research result not adverse, updates its saved authority when one
    /// exists, and records the review audit in one transaction. The result must
    /// belong to the exact open research session and matter supplied by the
    /// caller; a stale or foreign result ID cannot mutate either matter.
    public func markResearchResultNotAdverse(
        resultID: String,
        researchSessionID: String,
        matterID: String,
        actor: String,
        markedAt: Date = Date()
    ) throws {
        try writer.write { db in
            guard let result = try ResearchResultRecord.fetchOne(
                db,
                sql: """
                    SELECT result.*
                    FROM research_results AS result
                    JOIN research_queries AS query
                      ON query.id = result.research_query_id
                    JOIN research_sessions AS session
                      ON session.id = query.research_session_id
                    WHERE result.id = ?
                      AND session.id = ?
                      AND session.matter_id = ?
                    LIMIT 1
                    """,
                arguments: [resultID, researchSessionID, matterID]
            ) else {
                throw AuthorityRepositoryError.authorityProvenanceMismatch
            }
            let normalizedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedActor.isEmpty else {
                throw AuthorityRepositoryError.reviewerRequired
            }

            let authority = try AuthorityRecord.fetchOne(
                db,
                sql: "SELECT * FROM authorities WHERE research_result_id = ?",
                arguments: [resultID]
            )
            if let authority {
                guard authority.researchSessionID == researchSessionID,
                      authority.matterID == matterID else {
                    throw AuthorityRepositoryError.authorityProvenanceMismatch
                }
                try Self.validateResearchProvenance(authority: authority, db: db)
                try db.execute(
                    sql: "UPDATE authorities SET review_state = ?, updated_at = ? WHERE id = ?",
                    arguments: [ResearchResultReviewState.notAdverse.rawValue, markedAt, authority.id]
                )
                guard db.changesCount == 1 else {
                    throw AuthorityRepositoryError.authorityProvenanceMismatch
                }
            }

            try db.execute(
                sql: "UPDATE research_results SET review_state = ?, updated_at = ? WHERE id = ?",
                arguments: [ResearchResultReviewState.notAdverse.rawValue, markedAt, resultID]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.authorityProvenanceMismatch
            }
            try AuditEventRecord(
                matterID: matterID,
                timestamp: markedAt,
                eventType: "research_result_reviewed",
                actor: normalizedActor,
                summary: "Marked not adverse: “\(result.caseName)”",
                relatedTable: ResearchResultRecord.databaseTableName,
                relatedID: result.id
            ).insert(db)
        }
    }

    /// Soft-deletes a saved authority. Returns false if no live authority with that
    /// id exists. The row stays (the `(matter_id, research_result_id)` unique index
    /// still holds its slot), so re-saving the same result revives it via
    /// `reviveAuthority` rather than inserting a duplicate.
    @discardableResult
    public func softDeleteAuthority(id: String, deletedAt: Date = Date()) throws -> Bool {
        try writer.write { db in
            guard try AuthorityRecord.fetchOne(
                db,
                sql: "SELECT * FROM authorities WHERE id = ? AND deleted_at IS NULL",
                arguments: [id]
            ) != nil else { return false }
            try db.execute(
                sql: "UPDATE authorities SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [deletedAt, deletedAt, id]
            )
            return true
        }
    }

    /// Clears a soft-delete, bringing a previously-removed authority back into the
    /// library (used when the same research result is saved again).
    public func reviveAuthority(id: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE authorities SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// Finds the authority for a research result, including soft-deleted ones, so
    /// the save path can detect and revive a previously-removed authority.
    public func fetchAuthority(researchResultID: String) throws -> AuthorityRecord? {
        try writer.read { db in
            try AuthorityRecord.fetchOne(
                db,
                sql: "SELECT * FROM authorities WHERE research_result_id = ?",
                arguments: [researchResultID]
            )
        }
    }

    public func updatePreferredCitation(
        authorityID: String,
        preferredCitation: String?
    ) throws {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID) else {
                return
            }
            let preferredCitation = Self.trimOptional(preferredCitation)
            var updated = authority
            updated.preferredCitation = preferredCitation
            let invalidatesReview = authority.reviewedPropositionJSON != nil
                && Self.effectiveCitation(authority) != Self.effectiveCitation(updated)
            let updatedAt = Date()
            try db.execute(
                sql: """
                UPDATE authorities
                SET preferred_citation = ?,
                    reviewed_proposition_json = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    preferredCitation,
                    invalidatesReview ? nil : authority.reviewedPropositionJSON,
                    updatedAt,
                    authorityID,
                ]
            )
            if invalidatesReview, let rawEvidence = authority.reviewedPropositionJSON {
                try Self.recordInvalidationAudit(
                    authority: authority,
                    rawEvidence: rawEvidence,
                    reason: "effective_citation_changed",
                    timestamp: updatedAt,
                    db: db
                )
            }
        }
    }

    public func updateUserNotes(
        authorityID: String,
        userNotes: String?
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE authorities
                SET user_notes = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [Self.trimOptional(userNotes), Date(), authorityID]
            )
        }
    }

    /// The matter's saved-authority count — the local-first research gate (spec
    /// §4.1/§8.5: any saved authority makes the matter eligible to answer locally).
    public func countAuthorities(matterID: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM authorities WHERE matter_id = ? AND deleted_at IS NULL",
                arguments: [matterID]
            ) ?? 0
        }
    }

    /// Persists hydrated opinion text on a saved authority (spec §4.3): grounds
    /// local-first research and the offline [A#] reader.
    public func updateOpinionText(authorityID: String, text: String) throws {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID) else {
                return
            }
            let opinionBytesChanged = authority.opinionText.map { Data($0.utf8) } != Data(text.utf8)
            let invalidatesReview = authority.reviewedPropositionJSON != nil && opinionBytesChanged
            let updatedAt = Date()
            try db.execute(
                sql: """
                UPDATE authorities
                SET opinion_text = ?,
                    reviewed_proposition_json = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    text,
                    invalidatesReview ? nil : authority.reviewedPropositionJSON,
                    updatedAt,
                    authorityID,
                ]
            )
            if invalidatesReview, let rawEvidence = authority.reviewedPropositionJSON {
                try Self.recordInvalidationAudit(
                    authority: authority,
                    rawEvidence: rawEvidence,
                    reason: "opinion_bytes_changed",
                    timestamp: updatedAt,
                    db: db
                )
            }
        }
    }

    /// Persists an asynchronously fetched opinion only while the authority is
    /// still a live member of the expected matter and has no opinion bytes. The
    /// write/check/re-read share one transaction, so a concurrent local opinion
    /// always wins and its proposition evidence is never invalidated.
    public func storeFetchedOpinionTextIfAbsent(
        authorityID: String,
        matterID: String,
        fetchedText: String
    ) throws -> String {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID),
                  authority.matterID == matterID else {
                throw AuthorityRepositoryError.authorityNotFound
            }
            guard authority.deletedAt == nil else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            if let currentText = authority.opinionText, !currentText.isEmpty {
                return currentText
            }
            guard !fetchedText.isEmpty else {
                throw AuthorityRepositoryError.opinionTextUnavailable
            }

            try db.execute(
                sql: """
                UPDATE authorities
                SET opinion_text = ?, updated_at = ?
                WHERE id = ?
                  AND matter_id = ?
                  AND deleted_at IS NULL
                  AND (opinion_text IS NULL OR opinion_text = '')
                """,
                arguments: [fetchedText, Date(), authorityID, matterID]
            )
            guard db.changesCount == 1,
                  let persistedText = try AuthorityRecord.fetchOne(db, key: authorityID)?.opinionText else {
                throw AuthorityRepositoryError.opinionTextUnavailable
            }
            return persistedText
        }
    }

    public func updateCaseSummary(authorityID: String, summary: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE authorities SET case_summary = ?, updated_at = ? WHERE id = ?",
                arguments: [summary, Date(), authorityID]
            )
        }
    }

    public func fetchAuthorities(matterID: String) throws -> [AuthorityRecord] {
        try writer.read { db in
            try AuthorityRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM authorities
                WHERE matter_id = ? AND deleted_at IS NULL
                ORDER BY updated_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    /// Fetches an authority by durable identifier. This raw record may contain a
    /// proposition envelope, but callers must use `reviewedPropositionState` to
    /// establish whether the envelope is currently usable.
    public func fetchAuthority(id: String) throws -> AuthorityRecord? {
        try writer.read { db in
            try AuthorityRecord.fetchOne(db, key: id)
        }
    }

    /// Records a human-reviewed proposition against one exact, unique byte range
    /// in the currently persisted full opinion. Evidence and its content-free
    /// audit event commit in the same writer transaction.
    @discardableResult
    public func reviewProposition(
        authorityID: String,
        groundKey: AuthorityReviewedPropositionGround,
        excerpt: String,
        reviewedBy: String,
        reviewedAt: Date = Date()
    ) throws -> AuthorityReviewedProposition {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID) else {
                throw AuthorityRepositoryError.authorityNotFound
            }
            try Self.validateResearchProvenance(authority: authority, db: db)
            guard authority.deletedAt == nil else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            guard authority.reviewState == ResearchResultReviewState.notAdverse.rawValue else {
                throw AuthorityRepositoryError.reviewRequiresNotAdverse
            }
            guard authority.useStatus == AuthorityUseStatus.userMarkedVerified.rawValue else {
                throw AuthorityRepositoryError.reviewRequiresUserMarkedVerified
            }
            guard let opinion = authority.opinionText, !opinion.isEmpty else {
                throw AuthorityRepositoryError.opinionTextUnavailable
            }
            guard let effectiveCitation = Self.effectiveCitation(authority) else {
                throw AuthorityRepositoryError.effectiveCitationUnavailable
            }
            let reviewer = reviewedBy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reviewer.isEmpty else {
                throw AuthorityRepositoryError.reviewerRequired
            }

            let excerptBytes = Data(excerpt.utf8)
            guard !excerptBytes.isEmpty,
                  !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AuthorityRepositoryError.excerptEmpty
            }
            guard excerptBytes.count <= AuthorityReviewedProposition.maximumExcerptUTF8Bytes else {
                throw AuthorityRepositoryError.excerptTooLong(
                    maximumUTF8Bytes: AuthorityReviewedProposition.maximumExcerptUTF8Bytes
                )
            }
            let excerptByteStart = try Self.uniqueExcerptByteStart(
                opinionBytes: Data(opinion.utf8),
                excerptBytes: excerptBytes
            )
            let opinionSHA256 = Self.sha256(Data(opinion.utf8))
            let excerptSHA256 = Self.sha256(excerptBytes)
            let effectiveCitationSHA256 = Self.sha256(Data(effectiveCitation.utf8))
            let courtSHA256 = Self.sha256(Data(Self.courtBinding(authority).utf8))

            let unsigned = AuthorityReviewedProposition(
                authorityID: authority.id,
                groundKey: groundKey,
                excerpt: excerpt,
                excerptByteStart: excerptByteStart,
                excerptByteLength: excerptBytes.count,
                opinionSHA256: opinionSHA256,
                excerptSHA256: excerptSHA256,
                effectiveCitationSHA256: effectiveCitationSHA256,
                courtSHA256: courtSHA256,
                bindingSHA256: "",
                reviewedBy: reviewer,
                reviewedAt: reviewedAt
            )
            let reviewed = AuthorityReviewedProposition(
                authorityID: unsigned.authorityID,
                groundKey: unsigned.groundKey,
                sourceKind: unsigned.sourceKind,
                excerpt: unsigned.excerpt,
                excerptByteStart: unsigned.excerptByteStart,
                excerptByteLength: unsigned.excerptByteLength,
                opinionSHA256: unsigned.opinionSHA256,
                excerptSHA256: unsigned.excerptSHA256,
                effectiveCitationSHA256: unsigned.effectiveCitationSHA256,
                courtSHA256: unsigned.courtSHA256,
                bindingSHA256: try Self.bindingSHA256(unsigned),
                reviewedBy: unsigned.reviewedBy,
                reviewedAt: unsigned.reviewedAt
            )
            let rawEvidence = try Self.encodeEvidence(reviewed)
            try db.execute(
                sql: """
                UPDATE authorities
                SET reviewed_proposition_json = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [rawEvidence, reviewedAt, authorityID]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            try AuditEventRecord(
                matterID: authority.matterID,
                timestamp: reviewedAt,
                eventType: "authority_proposition_reviewed",
                actor: reviewer,
                summary: "Reviewed authority proposition",
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: authority.id,
                metadataJSON: try Self.reviewAuditMetadata(reviewed)
            ).insert(db)
            return reviewed
        }
    }

    /// Clears an explicit review and records the revocation without copying any
    /// opinion, excerpt, citation, or court content into the audit ledger.
    public func revokePropositionReview(
        authorityID: String,
        matterID: String,
        revokedBy: String,
        revokedAt: Date = Date()
    ) throws {
        try writer.write { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID),
                  authority.matterID == matterID else {
                throw AuthorityRepositoryError.authorityNotFound
            }
            try Self.validateResearchProvenance(authority: authority, db: db)
            guard authority.deletedAt == nil else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            guard let rawEvidence = authority.reviewedPropositionJSON else {
                throw AuthorityRepositoryError.propositionReviewNotFound
            }
            let actor = revokedBy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actor.isEmpty else {
                throw AuthorityRepositoryError.reviewerRequired
            }
            try db.execute(
                sql: """
                UPDATE authorities
                SET reviewed_proposition_json = NULL, updated_at = ?
                WHERE id = ? AND matter_id = ? AND deleted_at IS NULL
                """,
                arguments: [revokedAt, authorityID, matterID]
            )
            guard db.changesCount == 1 else {
                throw AuthorityRepositoryError.reviewRequiresLiveAuthority
            }
            try AuditEventRecord(
                matterID: authority.matterID,
                timestamp: revokedAt,
                eventType: "authority_proposition_review_revoked",
                actor: actor,
                summary: "Revoked authority proposition review",
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: authority.id,
                metadataJSON: try Self.priorEvidenceAuditMetadata(rawEvidence)
            ).insert(db)
        }
    }

    /// Returns only recomputed, currently eligible evidence as `.ready`. Raw JSON
    /// is never trusted: version, domain, binding, live bytes, citation, court,
    /// status, and unique byte range all fail closed to a typed state.
    public func reviewedPropositionState(
        authorityID: String,
        groundKey: AuthorityReviewedPropositionGround
    ) throws -> AuthorityReviewedPropositionState {
        try writer.read { db in
            guard let authority = try AuthorityRecord.fetchOne(db, key: authorityID) else {
                return .blocked(.authorityNotFound)
            }
            do {
                try Self.validateResearchProvenance(authority: authority, db: db)
            } catch {
                return .blocked(.authorityProvenanceInvalid)
            }
            return Self.reviewedPropositionState(authority: authority, groundKey: groundKey)
        }
    }

    /// Pure validation shared by repository consumers that already own a GRDB
    /// read/write transaction. Keeping the evidence contract here prevents an
    /// atomic drafting snapshot from opening a second, inconsistent read.
    static func reviewedPropositionState(
        authority: AuthorityRecord,
        groundKey: AuthorityReviewedPropositionGround
    ) -> AuthorityReviewedPropositionState {
        guard authority.deletedAt == nil else {
            return .blocked(.authorityNotLive)
        }
        guard let rawEvidence = authority.reviewedPropositionJSON else {
            return .notReviewed
        }

        let reviewed: AuthorityReviewedProposition
        do {
            reviewed = try Self.decodeEvidence(rawEvidence)
        } catch EvidenceDecodeError.unsupported {
            return .blocked(.unsupportedEvidence)
        } catch {
            return .blocked(.malformedEvidence)
        }
        guard Self.isSHA256(reviewed.bindingSHA256),
              reviewed.bindingSHA256 == (try? Self.bindingSHA256(reviewed)) else {
            return .blocked(.forgedEvidence)
        }
        guard reviewed.authorityID == authority.id,
              reviewed.groundKey == groundKey,
              reviewed.sourceKind == .storedOpinionText else {
            return .blocked(.forgedEvidence)
        }
        guard authority.reviewState == ResearchResultReviewState.notAdverse.rawValue,
              authority.useStatus == AuthorityUseStatus.userMarkedVerified.rawValue else {
            return .blocked(.authorityEligibilityChanged)
        }
        guard let opinion = authority.opinionText,
              let effectiveCitation = Self.effectiveCitation(authority) else {
            return .blocked(.staleEvidence)
        }
        let opinionBytes = Data(opinion.utf8)
        let excerptBytes = Data(reviewed.excerpt.utf8)
        guard !excerptBytes.isEmpty,
              excerptBytes.count <= AuthorityReviewedProposition.maximumExcerptUTF8Bytes,
              reviewed.excerptByteStart >= 0,
              reviewed.excerptByteLength == excerptBytes.count,
              reviewed.excerptByteStart <= opinionBytes.count - min(opinionBytes.count, excerptBytes.count),
              reviewed.excerptByteStart + excerptBytes.count <= opinionBytes.count,
              opinionBytes.subdata(
                in: reviewed.excerptByteStart..<(reviewed.excerptByteStart + excerptBytes.count)
              ) == excerptBytes,
              Self.excerptByteStarts(opinionBytes: opinionBytes, excerptBytes: excerptBytes)
                == [reviewed.excerptByteStart],
              reviewed.opinionSHA256 == Self.sha256(opinionBytes),
              reviewed.excerptSHA256 == Self.sha256(excerptBytes),
              reviewed.effectiveCitationSHA256 == Self.sha256(Data(effectiveCitation.utf8)),
              reviewed.courtSHA256 == Self.sha256(Data(Self.courtBinding(authority).utf8)) else {
            return .blocked(.staleEvidence)
        }
        return .ready(reviewed)
    }

    /// Validates the complete result -> query -> session -> matter chain for a
    /// saved authority inside the caller's existing database snapshot.
    static func validateResearchProvenance(
        authority: AuthorityRecord,
        db: Database
    ) throws {
        let matches = try Int.fetchOne(
            db,
            sql: """
                SELECT 1
                FROM research_results AS result
                JOIN research_queries AS query
                  ON query.id = result.research_query_id
                JOIN research_sessions AS session
                  ON session.id = query.research_session_id
                WHERE result.id = ?
                  AND session.id = ?
                  AND session.matter_id = ?
                LIMIT 1
                """,
            arguments: [
                authority.researchResultID,
                authority.researchSessionID,
                authority.matterID,
            ]
        )
        guard matches == 1 else {
            throw AuthorityRepositoryError.authorityProvenanceMismatch
        }
    }

    private static func hasSameSourceIdentity(
        _ lhs: AuthorityRecord,
        _ rhs: AuthorityRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.matterID == rhs.matterID
            && lhs.researchSessionID == rhs.researchSessionID
            && lhs.researchResultID == rhs.researchResultID
    }

    private static func trimOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func effectiveCitation(_ authority: AuthorityRecord) -> String? {
        if let preferred = trimOptional(authority.preferredCitation) {
            return preferred
        }
        guard let data = authority.citationJSON.data(using: .utf8),
              let citations = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return citations.lazy.compactMap(trimOptional).first
    }

    private static func courtBinding(_ authority: AuthorityRecord) -> String {
        "\(trimOptional(authority.courtID) ?? "")\u{0}\(trimOptional(authority.court) ?? "")"
    }

    private static func uniqueExcerptByteStart(
        opinionBytes: Data,
        excerptBytes: Data
    ) throws -> Int {
        let starts = excerptByteStarts(opinionBytes: opinionBytes, excerptBytes: excerptBytes)
        guard let start = starts.first else {
            throw AuthorityRepositoryError.excerptNotFound
        }
        guard starts.count == 1 else {
            throw AuthorityRepositoryError.excerptNotUnique
        }
        return start
    }

    private static func excerptByteStarts(opinionBytes: Data, excerptBytes: Data) -> [Int] {
        guard !excerptBytes.isEmpty, excerptBytes.count <= opinionBytes.count else {
            return []
        }
        let opinion = [UInt8](opinionBytes)
        let excerpt = [UInt8](excerptBytes)
        var starts: [Int] = []
        for start in 0...(opinion.count - excerpt.count) {
            if opinion[start..<(start + excerpt.count)].elementsEqual(excerpt) {
                starts.append(start)
                if starts.count > 1 { break }
            }
        }
        return starts
    }

    private static let evidenceKeys: Set<String> = [
        "schema_version", "authority_id", "ground_key", "source_kind", "excerpt",
        "excerpt_byte_start", "excerpt_byte_length", "opinion_sha256", "excerpt_sha256",
        "effective_citation_sha256", "court_sha256", "binding_sha256", "reviewed_by",
        "reviewed_at",
    ]

    private enum EvidenceDecodeError: Error {
        case malformed
        case unsupported
    }

    private static func encodeEvidence(_ reviewed: AuthorityReviewedProposition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(reviewed), as: UTF8.self)
    }

    private static func decodeEvidence(_ raw: String) throws -> AuthorityReviewedProposition {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let dictionary = object as? [String: Any] else {
            throw EvidenceDecodeError.malformed
        }
        let keys = Set(dictionary.keys)
        guard keys.isSuperset(of: evidenceKeys) else {
            throw EvidenceDecodeError.malformed
        }
        guard keys == evidenceKeys else {
            throw EvidenceDecodeError.unsupported
        }
        guard let schemaVersion = dictionary["schema_version"] as? Int else {
            throw EvidenceDecodeError.malformed
        }
        guard schemaVersion == AuthorityReviewedProposition.currentSchemaVersion else {
            throw EvidenceDecodeError.unsupported
        }
        guard let ground = dictionary["ground_key"] as? String,
              let source = dictionary["source_kind"] as? String else {
            throw EvidenceDecodeError.malformed
        }
        guard AuthorityReviewedPropositionGround(rawValue: ground) != nil,
              AuthorityReviewedPropositionSourceKind(rawValue: source) != nil else {
            throw EvidenceDecodeError.unsupported
        }
        guard let reviewed = try? JSONDecoder().decode(
            AuthorityReviewedProposition.self,
            from: Data(raw.utf8)
        ), reviewed.schemaVersion == AuthorityReviewedProposition.currentSchemaVersion,
           !reviewed.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           reviewed.reviewedBy == reviewed.reviewedBy.trimmingCharacters(in: .whitespacesAndNewlines),
           !reviewed.reviewedBy.isEmpty,
           reviewed.excerptByteStart >= 0,
           reviewed.excerptByteLength >= 0,
           isSHA256(reviewed.opinionSHA256),
           isSHA256(reviewed.excerptSHA256),
           isSHA256(reviewed.effectiveCitationSHA256),
           isSHA256(reviewed.courtSHA256),
           isSHA256(reviewed.bindingSHA256) else {
            throw EvidenceDecodeError.malformed
        }
        return reviewed
    }

    private struct BindingPayload: Encodable {
        let schemaVersion: Int
        let authorityID: String
        let groundKey: String
        let sourceKind: String
        let excerpt: String
        let excerptByteStart: Int
        let excerptByteLength: Int
        let opinionSHA256: String
        let excerptSHA256: String
        let effectiveCitationSHA256: String
        let courtSHA256: String
        let reviewedBy: String
        let reviewedAtBitPattern: UInt64
    }

    private static func bindingSHA256(_ reviewed: AuthorityReviewedProposition) throws -> String {
        let payload = BindingPayload(
            schemaVersion: reviewed.schemaVersion,
            authorityID: reviewed.authorityID,
            groundKey: reviewed.groundKey.rawValue,
            sourceKind: reviewed.sourceKind.rawValue,
            excerpt: reviewed.excerpt,
            excerptByteStart: reviewed.excerptByteStart,
            excerptByteLength: reviewed.excerptByteLength,
            opinionSHA256: reviewed.opinionSHA256,
            excerptSHA256: reviewed.excerptSHA256,
            effectiveCitationSHA256: reviewed.effectiveCitationSHA256,
            courtSHA256: reviewed.courtSHA256,
            reviewedBy: reviewed.reviewedBy,
            reviewedAtBitPattern: reviewed.reviewedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(payload))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            switch $0 {
            case 48...57, 97...102: true
            default: false
            }
        }
    }

    private static func reviewAuditMetadata(_ reviewed: AuthorityReviewedProposition) throws -> String {
        try auditMetadata([
            "schema_version": reviewed.schemaVersion,
            "ground_key": reviewed.groundKey.rawValue,
            "source_kind": reviewed.sourceKind.rawValue,
            "excerpt_byte_start": reviewed.excerptByteStart,
            "excerpt_byte_length": reviewed.excerptByteLength,
            "opinion_sha256": reviewed.opinionSHA256,
            "excerpt_sha256": reviewed.excerptSHA256,
            "effective_citation_sha256": reviewed.effectiveCitationSHA256,
            "court_sha256": reviewed.courtSHA256,
            "binding_sha256": reviewed.bindingSHA256,
        ])
    }

    private static func priorEvidenceAuditMetadata(_ rawEvidence: String) throws -> String {
        var metadata: [String: Any] = ["schema_version": 1]
        if let reviewed = try? decodeEvidence(rawEvidence),
           reviewed.bindingSHA256 == (try? bindingSHA256(reviewed)) {
            metadata["ground_key"] = reviewed.groundKey.rawValue
            metadata["previous_binding_sha256"] = reviewed.bindingSHA256
        } else {
            metadata["ground_key"] = "unknown"
            metadata["previous_evidence_sha256"] = sha256(Data(rawEvidence.utf8))
        }
        return try auditMetadata(metadata)
    }

    private static func recordInvalidationAudit(
        authority: AuthorityRecord,
        rawEvidence: String,
        reason: String,
        timestamp: Date,
        db: Database
    ) throws {
        var metadata = try JSONSerialization.jsonObject(
            with: Data(priorEvidenceAuditMetadata(rawEvidence).utf8)
        ) as? [String: Any] ?? ["schema_version": 1]
        metadata["reason"] = reason
        try AuditEventRecord(
            matterID: authority.matterID,
            timestamp: timestamp,
            eventType: "authority_proposition_review_invalidated",
            actor: "system",
            summary: "Invalidated authority proposition review",
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: authority.id,
            metadataJSON: try auditMetadata(metadata)
        ).insert(db)
    }

    private static func auditMetadata(_ object: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }
}
