import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Gating tests for the ScratchPad week-strip billable-hour indicators
/// (T-WK-01/02): each day's indicator must read the LATEST billing draft version
/// only, and must exist only for days where a draft has actually been run.
final class BillingWeekHoursTests: XCTestCase {

    // Expected RED: compile error — `BillingRepository.latestDraftHours(days:)`
    // does not exist yet ("value of type 'BillingRepository' has no member
    // 'latestDraftHours'").
    func testLatestDraftHoursSumsOnlyTheLatestDraftVersion() throws {
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-07-09")
        // v1 (superseded): 2.0h. If the query ever reads a non-latest version,
        // the total below would be 2.0 (or 6.5 across both) instead of 4.5.
        try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Superseded draft line.", hours: 2.0, workDate: "2026-07-09")
        ])
        // v2 (latest): 3.0 + 1.5 = 4.5h.
        try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Drafted opposition to motion to compel.", hours: 3.0, workDate: "2026-07-09"),
            BillingLineItemInput(narrative: "Telephone conference re custodian list.", hours: 1.5, workDate: "2026-07-09"),
        ])

        let hours = try store.billing.latestDraftHours(days: ["2026-07-09"])

        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(hours["2026-07-09"]), 4.5, accuracy: 0.0001,
            "the indicator must reflect the latest draft version (4.5), not v1's 2.0 or the 6.5 sum of all versions"
        )
    }

    // Expected RED: compile error — same missing `latestDraftHours(days:)` symbol.
    func testLatestDraftHoursOmitsDraftlessDaysAndCountsAnEmptyDraftAsZero() throws {
        let store = try SupraStore.inMemory()
        let drafted = try store.scratchPad.fetchOrCreateDay("2026-07-06")
        try store.billing.createDraft(dayID: drafted.id, lineItems: [
            BillingLineItemInput(narrative: "Reviewed coverage letter.", hours: 0.5, workDate: "2026-07-06")
        ])
        // Day row exists but no draft was ever generated for it.
        try store.scratchPad.fetchOrCreateDay("2026-07-07")
        // A draft WAS run, but every line has since been deleted: reads 0.0, not absent.
        let emptied = try store.scratchPad.fetchOrCreateDay("2026-07-08")
        try store.billing.createDraft(dayID: emptied.id, lineItems: [])

        let hours = try store.billing.latestDraftHours(
            days: ["2026-07-05", "2026-07-06", "2026-07-07", "2026-07-08"]
        )

        XCTAssertEqual(try XCTUnwrap(hours["2026-07-06"]), 0.5, accuracy: 0.0001)
        XCTAssertNil(hours["2026-07-07"], "no indicator before a billing draft has been run for the day")
        XCTAssertNil(hours["2026-07-05"], "a date with no ScratchPad row at all must have no indicator")
        XCTAssertEqual(
            try XCTUnwrap(hours["2026-07-08"]), 0.0, accuracy: 0.0001,
            "a run draft whose lines were all deleted reads 0.0 — a draft exists for that day"
        )
    }
}
