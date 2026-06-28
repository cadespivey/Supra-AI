import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Store-boundary regression tests for the Codex review fixes: lock enforcement,
/// LEDES matter identifiers, cross-day tag suggestions, and review-table line ops.
final class CodexReviewStoreTests: XCTestCase {

    private func makeStore() throws -> SupraStore { try SupraStore.inMemory() }

    // MARK: - Lock enforcement (P0)

    func testLockedDayRejectsAllMutationsAtTheStoreBoundary() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let entry = try store.scratchPad.addEntry(dayID: day.id, text: "Drafted opposition")
        let attachment = try store.scratchPad.addAttachment(dayID: day.id, evidenceKind: .workProduct)

        try store.scratchPad.lockDay(id: day.id)

        assertDayLocked { try store.scratchPad.addEntry(dayID: day.id, text: "late note") }
        assertDayLocked { try store.scratchPad.updateEntry(id: entry.id, text: "x", mentions: [], tags: []) }
        assertDayLocked { try store.scratchPad.deleteEntry(id: entry.id) }
        assertDayLocked { _ = try store.scratchPad.addAttachment(dayID: day.id, evidenceKind: .filing) }
        assertDayLocked { try store.scratchPad.updateAttachmentAssociation(id: attachment.id, matterID: nil, evidenceKind: .email) }
        assertDayLocked { try store.scratchPad.deleteAttachment(id: attachment.id) }

        // Reopening restores mutability.
        try store.scratchPad.reopenDay(id: day.id)
        XCTAssertNoThrow(try store.scratchPad.addEntry(dayID: day.id, text: "allowed again"))
    }

    private func assertDayLocked(_ expression: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? ScratchPadRepositoryError, .dayLocked, file: file, line: line)
        }
    }

    // MARK: - Cross-day #tag suggestions (P3)

    func testDistinctTagsSpanAllDays() throws {
        let store = try makeStore()
        let d1 = try store.scratchPad.fetchOrCreateDay("2026-06-20")
        let d2 = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: d1.id, text: "x", tags: ["discovery", "review"])
        try store.scratchPad.addEntry(dayID: d2.id, text: "y", tags: ["Drafting", "discovery"])
        XCTAssertEqual(try store.scratchPad.distinctTags(), ["discovery", "Drafting", "review"])
    }

    // MARK: - LEDES identifiers on the matter (P0)

    func testMatterCreateAndUpdatePersistLedesIdentifiers() throws {
        let store = try makeStore()
        let created = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail", jurisdiction: "FL",
            clientID: "MCKERNON", clientMatterID: "VS-LIT-2026-031"
        )
        XCTAssertEqual(created.clientID, "MCKERNON")
        XCTAssertEqual(created.clientMatterID, "VS-LIT-2026-031")

        try store.matters.updateMatter(
            id: created.id, name: created.name, jurisdiction: "FL", partyPerspective: .plaintiff,
            clientID: "MCKERNON-2", clientMatterID: "VS-2027"
        )
        let reloaded = try XCTUnwrap(store.matters.fetchMatter(id: created.id))
        XCTAssertEqual(reloaded.clientID, "MCKERNON-2")
        XCTAssertEqual(reloaded.clientMatterID, "VS-2027")
    }

    // MARK: - Review-table line ops (P1)

    func testDeleteAndReassignLineItem() throws {
        let store = try makeStore()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        let draft = try store.billing.createDraft(
            dayID: day.id,
            lineItems: [
                BillingLineItemInput(matterID: "m1", narrative: "A", hours: 1, workDate: "2026-06-22"),
                BillingLineItemInput(narrative: "B unassigned", hours: 0.5, workDate: "2026-06-22"),
            ]
        )
        var lines = try store.billing.lineItems(draftID: draft.id)
        XCTAssertEqual(lines.count, 2)

        // Reassign the unassigned line to a matter (+ client id), marks user_edited.
        let unassigned = try XCTUnwrap(lines.first { $0.matterID == nil })
        try store.billing.reassignLineItemMatter(id: unassigned.id, matterID: "m2", clientID: "CLIENT2")
        lines = try store.billing.lineItems(draftID: draft.id)
        let reassigned = try XCTUnwrap(lines.first { $0.id == unassigned.id })
        XCTAssertEqual(reassigned.matterID, "m2")
        XCTAssertEqual(reassigned.clientID, "CLIENT2")
        XCTAssertTrue(reassigned.userEdited)

        // Delete the other line.
        let toDelete = try XCTUnwrap(lines.first { $0.matterID == "m1" })
        try store.billing.deleteLineItem(id: toDelete.id)
        let remaining = try store.billing.lineItems(draftID: draft.id)
        XCTAssertEqual(remaining.map(\.id), [reassigned.id])
    }
}
