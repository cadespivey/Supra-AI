import Foundation
import GRDB
import SupraCore

/// Persistence for ScratchPad daily notes, entries, and day-level attachments
/// (Milestone 4). See Docs/ScratchPad-SPEC.md §2.
public final class ScratchPadRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
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
            try db.execute(
                sql: "UPDATE scratch_pad_attachments SET matter_id = ?, evidence_kind = ?, updated_at = ? WHERE id = ?",
                arguments: [matterID, evidenceKind.rawValue, Date(), id]
            )
        }
    }

    public func deleteAttachment(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM scratch_pad_attachments WHERE id = ?", arguments: [id])
        }
    }
}
