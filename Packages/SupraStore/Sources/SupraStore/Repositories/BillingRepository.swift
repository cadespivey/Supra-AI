import Foundation
import GRDB
import SupraCore

/// Input for one billing line item when creating a draft.
public struct BillingLineItemInput: Sendable {
    public var clientID: String?
    public var matterID: String?
    public var narrative: String
    public var hours: Double
    public var workDate: String
    public var utbmsTaskCode: String?
    public var utbmsActivityCode: String?
    public var timekeeperID: String?
    public var rate: Double?
    public var confidence: BillingConfidence
    public var evidenceJSON: String?
    public var codeNote: String?
    public var sourceEntryIDs: [String]
    public var userEdited: Bool

    public init(
        clientID: String? = nil,
        matterID: String? = nil,
        narrative: String,
        hours: Double,
        workDate: String,
        utbmsTaskCode: String? = nil,
        utbmsActivityCode: String? = nil,
        timekeeperID: String? = nil,
        rate: Double? = nil,
        confidence: BillingConfidence = .medium,
        evidenceJSON: String? = nil,
        codeNote: String? = nil,
        sourceEntryIDs: [String] = [],
        userEdited: Bool = false
    ) {
        self.clientID = clientID
        self.matterID = matterID
        self.narrative = narrative
        self.hours = hours
        self.workDate = workDate
        self.utbmsTaskCode = utbmsTaskCode
        self.utbmsActivityCode = utbmsActivityCode
        self.timekeeperID = timekeeperID
        self.rate = rate
        self.confidence = confidence
        self.evidenceJSON = evidenceJSON
        self.codeNote = codeNote
        self.sourceEntryIDs = sourceEntryIDs
        self.userEdited = userEdited
    }
}

/// Persistence for generated billing drafts, line items, and per-matter billing
/// profiles (Milestone 4). See Docs/ScratchPad-SPEC.md §2.
public final class BillingRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Drafts

    /// Creates a new draft version for a day with its line items, in one transaction.
    /// `version` auto-increments per day so prior drafts are preserved.
    @discardableResult
    public func createDraft(
        dayID: String,
        modelID: String? = nil,
        sensitivity: Double = BillingSensitivity.defaultValue,
        status: BillingDraftStatus = .draft,
        reconciliationJSON: String? = nil,
        lineItems: [BillingLineItemInput]
    ) throws -> BillingDraftRecord {
        try writer.write { db in
            let nextVersion = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(version), 0) + 1 FROM billing_drafts WHERE day_id = ?",
                arguments: [dayID]
            ) ?? 1
            let draft = BillingDraftRecord(
                dayID: dayID,
                version: nextVersion,
                modelID: modelID,
                sensitivity: BillingSensitivity.clamp(sensitivity),
                status: status,
                reconciliationJSON: reconciliationJSON
            )
            try draft.insert(db)
            for (index, item) in lineItems.enumerated() {
                let record = BillingLineItemRecord(
                    draftID: draft.id,
                    seq: index + 1,
                    clientID: item.clientID,
                    matterID: item.matterID,
                    narrative: item.narrative,
                    hours: item.hours,
                    workDate: item.workDate,
                    utbmsTaskCode: item.utbmsTaskCode,
                    utbmsActivityCode: item.utbmsActivityCode,
                    timekeeperID: item.timekeeperID,
                    rate: item.rate,
                    confidence: item.confidence,
                    evidenceJSON: item.evidenceJSON,
                    codeNote: item.codeNote,
                    userEdited: item.userEdited,
                    sourceEntryIDsJSON: ScratchPadJSON.encodeStrings(item.sourceEntryIDs)
                )
                try record.insert(db)
            }
            return draft
        }
    }

    public func drafts(dayID: String) throws -> [BillingDraftRecord] {
        try writer.read { db in
            try BillingDraftRecord.fetchAll(
                db, sql: "SELECT * FROM billing_drafts WHERE day_id = ? ORDER BY version DESC", arguments: [dayID]
            )
        }
    }

    public func latestDraft(dayID: String) throws -> BillingDraftRecord? {
        try writer.read { db in
            try BillingDraftRecord.fetchOne(
                db, sql: "SELECT * FROM billing_drafts WHERE day_id = ? ORDER BY version DESC LIMIT 1", arguments: [dayID]
            )
        }
    }

    public func setDraftStatus(id: String, status: BillingDraftStatus) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE billing_drafts SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), id]
            )
        }
    }

    /// Replaces the draft's reconciliation (recomputed after a manual edit).
    public func updateReconciliation(draftID: String, reconciliationJSON: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE billing_drafts SET reconciliation_json = ?, updated_at = ? WHERE id = ?",
                arguments: [reconciliationJSON, Date(), draftID]
            )
        }
    }

    // MARK: - Line items

    public func lineItems(draftID: String) throws -> [BillingLineItemRecord] {
        try writer.read { db in
            try BillingLineItemRecord.fetchAll(
                db, sql: "SELECT * FROM billing_line_items WHERE draft_id = ? ORDER BY seq ASC", arguments: [draftID]
            )
        }
    }

    /// Applies a manual edit to a line and marks it `user_edited` so regeneration preserves it.
    public func updateLineItem(
        id: String,
        narrative: String,
        hours: Double,
        utbmsTaskCode: String?,
        utbmsActivityCode: String?,
        rate: Double?
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE billing_line_items
                SET narrative = ?, hours = ?, utbms_task_code = ?, utbms_activity_code = ?, rate = ?,
                    user_edited = 1, updated_at = ?
                WHERE id = ?
                """,
                arguments: [narrative, hours, utbmsTaskCode, utbmsActivityCode, rate, Date(), id]
            )
        }
    }

    /// Reassigns a line to a different matter (or to none), denormalizing the
    /// client id, and marks it `user_edited` so regeneration preserves the choice.
    public func reassignLineItemMatter(id: String, matterID: String?, clientID: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE billing_line_items SET matter_id = ?, client_id = ?, user_edited = 1, updated_at = ? WHERE id = ?",
                arguments: [matterID, clientID, Date(), id]
            )
        }
    }

    /// Removes a line from a draft (review-table delete).
    public func deleteLineItem(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM billing_line_items WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Matter billing profiles

    public func billingProfile(matterID: String) throws -> MatterBillingProfileRecord? {
        try writer.read { db in
            try MatterBillingProfileRecord.fetchOne(
                db, sql: "SELECT * FROM matter_billing_profiles WHERE matter_id = ?", arguments: [matterID]
            )
        }
    }

    /// Inserts or updates the matter's billing profile (one row per matter).
    @discardableResult
    public func upsertBillingProfile(
        matterID: String,
        overrideInstructions: String?,
        billingCodeSet: BillingCodeSet
    ) throws -> MatterBillingProfileRecord {
        try writer.write { db in
            if var existing = try MatterBillingProfileRecord.fetchOne(
                db, sql: "SELECT * FROM matter_billing_profiles WHERE matter_id = ?", arguments: [matterID]
            ) {
                existing.overrideInstructions = overrideInstructions
                existing.billingCodeSet = billingCodeSet.rawValue
                existing.updatedAt = Date()
                try existing.update(db)
                return existing
            }
            let record = MatterBillingProfileRecord(
                matterID: matterID,
                overrideInstructions: overrideInstructions,
                billingCodeSet: billingCodeSet
            )
            try record.insert(db)
            return record
        }
    }
}
