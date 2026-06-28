import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Milestone 4 (ScratchPad -> billing) schema and repository tests (Phase 1).
final class ScratchPadSchemaTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        try SupraStore.inMemory()
    }

    private func count(_ store: SupraStore, _ sql: String, _ args: StatementArguments = []) throws -> Int {
        try store.database.writer.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
        }
    }

    func testMigrationsCreateScratchPadAndBillingTables() throws {
        let store = try makeStore()
        let tableNames = try store.database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        for table in [
            "scratch_pad_days",
            "scratch_pad_entries",
            "scratch_pad_attachments",
            "billing_drafts",
            "billing_line_items",
            "matter_billing_profiles"
        ] {
            XCTAssertTrue(tableNames.contains(table), "missing table \(table)")
        }
        // Existing tables remain intact.
        XCTAssertTrue(tableNames.contains("matters"))
        XCTAssertTrue(tableNames.contains("matter_documents"))
    }

    func testMattersHasLEDESColumnsAndRoundTrips() throws {
        let store = try makeStore()
        let matter = MatterRecord(
            name: "McKernon Motors v. Liberty Rail",
            clientID: "MCKERNON",
            clientMatterID: "VS-LIT-2026-031"
        )
        try store.database.writer.write { db in try matter.insert(db) }
        let fetched = try store.matters.fetchMatter(id: matter.id)
        XCTAssertEqual(fetched?.clientID, "MCKERNON")
        XCTAssertEqual(fetched?.clientMatterID, "VS-LIT-2026-031")
    }

    func testDayFetchOrCreateIsIdempotentByDate() throws {
        let store = try makeStore()
        let a = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let b = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try store.scratchPad.recentDays().count, 1)
    }

    func testEntriesSeqOrderingAndTagRoundTrip() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Reviewed motion", mentions: ["m-mckernon"], tags: ["review", "discovery"])
        try store.scratchPad.addEntry(dayID: day.id, text: "Drafted opposition", mentions: [], tags: ["drafting"])
        let entries = try store.scratchPad.entries(dayID: day.id)
        XCTAssertEqual(entries.map(\.seq), [1, 2])
        XCTAssertEqual(entries[0].mentions, ["m-mckernon"])
        XCTAssertEqual(entries[0].tags, ["review", "discovery"])
        XCTAssertEqual(entries[1].mentions, [])
    }

    func testEntryUpdateAndDelete() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let entry = try store.scratchPad.addEntry(dayID: day.id, text: "x")
        try store.scratchPad.updateEntry(id: entry.id, text: "updated", mentions: ["m1"], tags: ["t1"])
        let updated = try store.scratchPad.entries(dayID: day.id)
        XCTAssertEqual(updated.first?.text, "updated")
        XCTAssertEqual(updated.first?.tags, ["t1"])
        try store.scratchPad.deleteEntry(id: entry.id)
        XCTAssertTrue(try store.scratchPad.entries(dayID: day.id).isEmpty)
    }

    func testDeletingDayCascadesChildren() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "x")
        try store.scratchPad.addAttachment(dayID: day.id, evidenceKind: .filing)
        try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Reviewed motion to compel", hours: 0.6, workDate: "2026-06-22")
        ])
        // Foreign-key cascade: deleting the day removes all children.
        try store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM scratch_pad_days WHERE id = ?", arguments: [day.id])
        }
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM scratch_pad_entries"), 0)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM scratch_pad_attachments"), 0)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM billing_drafts"), 0)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM billing_line_items"), 0)
    }

    func testBillingDraftVersioningAndLineItems() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let d1 = try store.billing.createDraft(dayID: day.id, sensitivity: 0.6, lineItems: [
            BillingLineItemInput(
                matterID: "m-mckernon",
                narrative: "Drafted opposition to motion to compel",
                hours: 1.3,
                workDate: "2026-06-22",
                utbmsTaskCode: "L350",
                utbmsActivityCode: "A103",
                confidence: .high,
                sourceEntryIDs: ["e1", "e2"]
            )
        ])
        let d2 = try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Reviewed filing", hours: 0.6, workDate: "2026-06-22")
        ])
        XCTAssertEqual(d1.version, 1)
        XCTAssertEqual(d2.version, 2)
        XCTAssertEqual(try store.billing.latestDraft(dayID: day.id)?.id, d2.id)

        let items = try store.billing.lineItems(draftID: d1.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].utbmsTaskCode, "L350")
        XCTAssertEqual(items[0].confidence, BillingConfidence.high.rawValue)
        XCTAssertEqual(items[0].sourceEntryIDs, ["e1", "e2"])
        XCTAssertEqual(d1.sensitivity, 0.6, accuracy: 0.0001)
    }

    func testLineItemEditMarksUserEdited() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let draft = try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "x", hours: 0.5, workDate: "2026-06-22")
        ])
        let item = try store.billing.lineItems(draftID: draft.id)[0]
        XCTAssertFalse(item.userEdited)
        try store.billing.updateLineItem(
            id: item.id,
            narrative: "Corrected narrative",
            hours: 0.4,
            utbmsTaskCode: "L350",
            utbmsActivityCode: "A104",
            rate: 450
        )
        let updated = try store.billing.lineItems(draftID: draft.id)[0]
        XCTAssertTrue(updated.userEdited)
        XCTAssertEqual(updated.hours, 0.4, accuracy: 0.0001)
        XCTAssertEqual(updated.narrative, "Corrected narrative")
    }

    func testMatterBillingProfileUpsertIsSingleRow() throws {
        let store = try makeStore()
        let matter = MatterRecord(name: "Hessington MSA")
        try store.database.writer.write { db in try matter.insert(db) }
        _ = try store.billing.upsertBillingProfile(matterID: matter.id, overrideInstructions: "No block billing.", billingCodeSet: .transactional)
        _ = try store.billing.upsertBillingProfile(matterID: matter.id, overrideInstructions: "Require UTBMS codes.", billingCodeSet: .transactional)
        let profile = try store.billing.billingProfile(matterID: matter.id)
        XCTAssertEqual(profile?.overrideInstructions, "Require UTBMS codes.")
        XCTAssertEqual(profile?.billingCodeSet, BillingCodeSet.transactional.rawValue)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM matter_billing_profiles WHERE matter_id = ?", [matter.id]), 1)
    }

    func testLockAndReopenDay() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        XCTAssertNil(day.lockedAt)
        try store.scratchPad.lockDay(id: day.id)
        XCTAssertNotNil(try store.scratchPad.fetchDay(id: day.id)?.lockedAt)
        try store.scratchPad.reopenDay(id: day.id)
        XCTAssertNil(try store.scratchPad.fetchDay(id: day.id)?.lockedAt)
    }
}
