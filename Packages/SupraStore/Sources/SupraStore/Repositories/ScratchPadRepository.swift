import Foundation
import GRDB
import SupraCore

public enum ScratchPadRepositoryError: Error, Equatable, Sendable {
    /// A mutation was attempted against a locked day. Lock is enforced here at the
    /// store boundary (not only in the UI), so a stale view or a direct repository
    /// call can never edit a finalized day (spec §0.2d, §7).
    case dayLocked
}

/// Persistence for ScratchPad daily notes, entries, and day-level attachments
/// (Milestone 4). See Docs/ScratchPad-SPEC.md §2.
public final class ScratchPadRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Lock guards

    /// Throws `dayLocked` if the day is finalized. Run inside the mutating write so
    /// the check and the mutation share one transaction.
    private static func requireUnlocked(_ db: Database, dayID: String) throws {
        let locked = (try Int.fetchOne(
            db, sql: "SELECT locked_at IS NOT NULL FROM scratch_pad_days WHERE id = ?", arguments: [dayID]
        ) ?? 0) != 0
        if locked { throw ScratchPadRepositoryError.dayLocked }
    }

    private static func requireUnlocked(_ db: Database, forEntryID entryID: String) throws {
        let locked = (try Int.fetchOne(
            db,
            sql: "SELECT d.locked_at IS NOT NULL FROM scratch_pad_entries e JOIN scratch_pad_days d ON d.id = e.day_id WHERE e.id = ?",
            arguments: [entryID]
        ) ?? 0) != 0
        if locked { throw ScratchPadRepositoryError.dayLocked }
    }

    private static func requireUnlocked(_ db: Database, forAttachmentID attachmentID: String) throws {
        let locked = (try Int.fetchOne(
            db,
            sql: "SELECT d.locked_at IS NOT NULL FROM scratch_pad_attachments a JOIN scratch_pad_days d ON d.id = a.day_id WHERE a.id = ?",
            arguments: [attachmentID]
        ) ?? 0) != 0
        if locked { throw ScratchPadRepositoryError.dayLocked }
    }

    // MARK: - Days

    /// Returns the day for `day` (ISO `YYYY-MM-DD`), creating it if absent. Exactly
    /// one row per date (enforced by a unique index).
    @discardableResult
    public func fetchOrCreateDay(_ day: String) throws -> ScratchPadDayRecord {
        let key = day.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            if let existing = try ScratchPadDayRecord.fetchOne(
                db, sql: "SELECT * FROM scratch_pad_days WHERE day = ?", arguments: [key]
            ) {
                return existing
            }
            let record = ScratchPadDayRecord(day: key)
            try record.insert(db)
            return record
        }
    }

    public func fetchDay(day: String) throws -> ScratchPadDayRecord? {
        try writer.read { db in
            try ScratchPadDayRecord.fetchOne(
                db, sql: "SELECT * FROM scratch_pad_days WHERE day = ?", arguments: [day]
            )
        }
    }

    public func fetchDay(id: String) throws -> ScratchPadDayRecord? {
        try writer.read { db in
            try ScratchPadDayRecord.fetchOne(
                db, sql: "SELECT * FROM scratch_pad_days WHERE id = ?", arguments: [id]
            )
        }
    }

    public func recentDays(limit: Int = 60) throws -> [ScratchPadDayRecord] {
        try writer.read { db in
            try ScratchPadDayRecord.fetchAll(
                db, sql: "SELECT * FROM scratch_pad_days ORDER BY day DESC LIMIT ?", arguments: [limit]
            )
        }
    }

    public func lockDay(id: String, lockedAt: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE scratch_pad_days SET locked_at = ?, updated_at = ? WHERE id = ?",
                arguments: [lockedAt, Date(), id]
            )
        }
    }

    public func reopenDay(id: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE scratch_pad_days SET locked_at = NULL, updated_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    // MARK: - Entries

    public func entries(dayID: String) throws -> [ScratchPadEntryRecord] {
        try writer.read { db in
            try ScratchPadEntryRecord.fetchAll(
                db, sql: "SELECT * FROM scratch_pad_entries WHERE day_id = ? ORDER BY seq ASC", arguments: [dayID]
            )
        }
    }

    /// Distinct `#tags` across every day (first-seen casing preserved), for the
    /// `#` autocomplete — so tags from earlier days are suggested too, not just
    /// today's (spec §3).
    public func distinctTags() throws -> [String] {
        try writer.read { db in
            let records = try ScratchPadEntryRecord.fetchAll(db, sql: "SELECT * FROM scratch_pad_entries")
            var seen = Set<String>()
            var result: [String] = []
            for tag in records.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
            return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    /// Appends a new entry, assigning the next sequence number for the day.
    @discardableResult
    public func addEntry(
        dayID: String,
        text: String,
        mentions: [String] = [],
        tags: [String] = [],
        createdAt: Date = Date()
    ) throws -> ScratchPadEntryRecord {
        try writer.write { db in
            try Self.requireUnlocked(db, dayID: dayID)
            let nextSeq = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM scratch_pad_entries WHERE day_id = ?",
                arguments: [dayID]
            ) ?? 1
            let record = ScratchPadEntryRecord(
                dayID: dayID,
                seq: nextSeq,
                text: text,
                mentionsJSON: ScratchPadJSON.encodeStrings(mentions),
                tagsJSON: ScratchPadJSON.encodeStrings(tags),
                createdAt: createdAt,
                updatedAt: createdAt
            )
            try record.insert(db)
            return record
        }
    }

    public func updateEntry(id: String, text: String, mentions: [String], tags: [String]) throws {
        try writer.write { db in
            try Self.requireUnlocked(db, forEntryID: id)
            try db.execute(
                sql: """
                UPDATE scratch_pad_entries
                SET text = ?, mentions_json = ?, tags_json = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [text, ScratchPadJSON.encodeStrings(mentions), ScratchPadJSON.encodeStrings(tags), Date(), id]
            )
        }
    }

    public func deleteEntry(id: String) throws {
        try writer.write { db in
            try Self.requireUnlocked(db, forEntryID: id)
            try db.execute(sql: "DELETE FROM scratch_pad_entries WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Attachments

    public func attachments(dayID: String) throws -> [ScratchPadAttachmentRecord] {
        try writer.read { db in
            try ScratchPadAttachmentRecord.fetchAll(
                db, sql: "SELECT * FROM scratch_pad_attachments WHERE day_id = ? ORDER BY created_at ASC", arguments: [dayID]
            )
        }
    }

    @discardableResult
    public func addAttachment(
        dayID: String,
        entryID: String? = nil,
        matterDocumentID: String? = nil,
        matterID: String? = nil,
        evidenceKind: BillingEvidenceKind = .other,
        evidenceSignalsJSON: String? = nil
    ) throws -> ScratchPadAttachmentRecord {
        try writer.write { db in
            try Self.requireUnlocked(db, dayID: dayID)
            let record = ScratchPadAttachmentRecord(
                dayID: dayID,
                entryID: entryID,
                matterDocumentID: matterDocumentID,
                matterID: matterID,
                evidenceKind: evidenceKind,
                evidenceSignalsJSON: evidenceSignalsJSON
            )
            try record.insert(db)
            return record
        }
    }

    public func updateAttachmentAssociation(
        id: String,
        matterID: String?,
        evidenceKind: BillingEvidenceKind
    ) throws {
        try writer.write { db in
            try Self.requireUnlocked(db, forAttachmentID: id)
            try db.execute(
                sql: "UPDATE scratch_pad_attachments SET matter_id = ?, evidence_kind = ?, updated_at = ? WHERE id = ?",
                arguments: [matterID, evidenceKind.rawValue, Date(), id]
            )
        }
    }

    public func deleteAttachment(id: String) throws {
        try writer.write { db in
            try Self.requireUnlocked(db, forAttachmentID: id)
            try db.execute(sql: "DELETE FROM scratch_pad_attachments WHERE id = ?", arguments: [id])
        }
    }
}
