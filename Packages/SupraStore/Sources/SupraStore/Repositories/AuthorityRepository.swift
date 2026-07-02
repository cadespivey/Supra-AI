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
            try authority.insert(db, onConflict: .ignore)
            return authority
        }
    }

    public func updateUseStatus(
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
            try db.execute(
                sql: """
                UPDATE authorities
                SET preferred_citation = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [Self.trimOptional(preferredCitation), Date(), authorityID]
            )
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
            try db.execute(
                sql: "UPDATE authorities SET opinion_text = ?, updated_at = ? WHERE id = ?",
                arguments: [text, Date(), authorityID]
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

    private static func trimOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
