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

    public func fetchAuthorities(matterID: String) throws -> [AuthorityRecord] {
        try writer.read { db in
            try AuthorityRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM authorities
                WHERE matter_id = ?
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
