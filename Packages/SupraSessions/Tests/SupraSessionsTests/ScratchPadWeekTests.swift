import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// Gating tests for the ScratchPad week strip (T-WK-03…11): week/day derivation,
/// month labeling, controller week navigation, and the per-day billable-hour
/// indicators sourced from each day's latest billing draft.
@MainActor
final class ScratchPadWeekTests: XCTestCase {

    /// Deterministic US-style calendar (Sunday-first) with a pinned en_US locale so
    /// weekday/month labels don't drift with the machine's locale. The time zone
    /// stays `.current` on purpose — it must agree with the controller's
    /// `dayString` formatter, which also uses the current zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    // MARK: - ScratchPadWeek (pure date math)

    // Expected RED: compile error — type `ScratchPadWeek` does not exist yet
    // ("cannot find 'ScratchPadWeek' in scope").
    func testWeekContainingDateProducesSevenDaysHonoringFirstWeekday() {
        let today = date(2026, 7, 9) // a Thursday
        let week = ScratchPadWeek.containing(today, today: today, calendar: calendar)
        XCTAssertEqual(
            week.days.map(\.id),
            ["2026-07-05", "2026-07-06", "2026-07-07", "2026-07-08", "2026-07-09", "2026-07-10", "2026-07-11"]
        )
        XCTAssertTrue(week.containsToday)
    }

    // Expected RED: compile error — same missing `ScratchPadWeek` type.
    func testWeekDayLabelsNumbersAndFlags() {
        let today = date(2026, 7, 9)
        let week = ScratchPadWeek.containing(today, today: today, calendar: calendar)
        XCTAssertEqual(week.days.map(\.weekdayLabel), ["Sun.", "Mon.", "Tue.", "Wed.", "Thu.", "Fri.", "Sat."])
        XCTAssertEqual(week.days.map(\.dayNumber), ["05", "06", "07", "08", "09", "10", "11"])
        XCTAssertEqual(week.days.map(\.isToday), [false, false, false, false, true, false, false])
        XCTAssertEqual(
            week.days.map(\.isFuture), [false, false, false, false, false, true, true],
            "days after today are unbillable and must be flagged future (disabled in the strip)"
        )
    }

    // Expected RED: compile error — same missing `ScratchPadWeek` type.
    func testMonthLabelUsesMajorityMonthAndAppendsYearOutsideTheCurrentYear() {
        let today = date(2026, 7, 9)
        XCTAssertEqual(ScratchPadWeek.containing(today, today: today, calendar: calendar).monthLabel, "July")
        // Jun 28 – Jul 4, 2026: four of the seven days (middle day Wed Jul 1 onward)
        // are July, so July is the majority month.
        let spanning = ScratchPadWeek.containing(date(2026, 6, 29), today: today, calendar: calendar)
        XCTAssertEqual(spanning.monthLabel, "July")
        XCTAssertFalse(spanning.monthLabel.contains("June"), "the minority month must not be shown")
        // A week outside today's year carries the year for orientation.
        let lastYear = ScratchPadWeek.containing(date(2025, 12, 24), today: today, calendar: calendar)
        XCTAssertEqual(lastYear.monthLabel, "December 2025")
    }

    // Expected RED: compile error — same missing `ScratchPadWeek` type.
    func testAdvancedByWeeksShiftsSevenDaysAndRefreshesFlags() {
        let today = date(2026, 7, 9)
        let week = ScratchPadWeek.containing(today, today: today, calendar: calendar)
        let previous = week.advanced(by: -1, today: today, calendar: calendar)
        XCTAssertEqual(previous.days.first?.id, "2026-06-28")
        XCTAssertEqual(previous.days.last?.id, "2026-07-04")
        XCTAssertFalse(previous.containsToday)
        XCTAssertEqual(previous.days.map(\.isFuture), Array(repeating: false, count: 7))
        let restored = previous.advanced(by: 1, today: today, calendar: calendar)
        XCTAssertEqual(restored.days.map(\.id), week.days.map(\.id))
    }

    // Expected RED: compile error — `ScratchPadWeek.hoursLabel` does not exist yet.
    func testHoursLabelFormatsTenthsAndKeepsRealHundredths() {
        XCTAssertEqual(ScratchPadWeek.hoursLabel(3), "3.0")
        XCTAssertEqual(ScratchPadWeek.hoursLabel(0.5), "0.5")
        XCTAssertEqual(ScratchPadWeek.hoursLabel(1.25), "1.25", "0.25h rounding increments must not be flattened")
        XCTAssertEqual(ScratchPadWeek.hoursLabel(2.4000000000000004), "2.4", "float-sum noise must normalize away")
    }

    // MARK: - Controller week navigation

    // Expected RED: compile error — `ScratchPadController` has no `calendar:`
    // initializer parameter and no `visibleWeek` property yet.
    func testLoadAndSelectDateSnapTheVisibleWeek() throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store, now: { self.date(2026, 7, 9) }, calendar: calendar)
        controller.load()
        let week = try XCTUnwrap(controller.visibleWeek)
        XCTAssertEqual(week.days.first?.id, "2026-07-05")
        XCTAssertTrue(week.containsToday)

        // Jumping to an arbitrary date (history popover / search hit) snaps the strip
        // to that date's week — including for a fresh date with no day row yet.
        controller.selectDate(date(2026, 6, 15))
        XCTAssertEqual(controller.displayedDate, "2026-06-15")
        let snapped = try XCTUnwrap(controller.visibleWeek)
        XCTAssertEqual(snapped.days.first?.id, "2026-06-14")
        XCTAssertTrue(snapped.days.contains { $0.id == "2026-06-15" })
    }

    // Expected RED: compile error — `ScratchPadController.stepWeek` does not exist yet.
    func testStepWeekNavigatesBackAndGatesAtTheCurrentWeek() throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store, now: { self.date(2026, 7, 9) }, calendar: calendar)
        controller.load()

        controller.stepWeek(1)
        XCTAssertEqual(
            controller.visibleWeek?.days.first?.id, "2026-07-05",
            "the strip must never navigate past the week containing today"
        )

        controller.stepWeek(-1)
        XCTAssertEqual(controller.visibleWeek?.days.first?.id, "2026-06-28")
        XCTAssertEqual(
            controller.displayedDate, "2026-07-09",
            "browsing weeks alone must not change the open day"
        )

        controller.stepWeek(1)
        XCTAssertEqual(controller.visibleWeek?.days.first?.id, "2026-07-05")
    }

    // Expected RED: compile error — `ScratchPadController.weekBilledHours` does not
    // exist yet. Wire-proof shape: a non-default value (3.0) must appear for the
    // drafted day AND the indicator must be absent (nil) for the sibling day the
    // draft never covered — scoped to the exact per-day dictionary entries.
    func testWeekBilledHoursComeFromTheLatestDraftAndOmitDraftlessDays() throws {
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-07-09")
        try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Drafted opposition.", hours: 2.0, workDate: "2026-07-09"),
            BillingLineItemInput(narrative: "Call with adjuster.", hours: 1.0, workDate: "2026-07-09"),
        ])

        let controller = ScratchPadController(store: store, now: { self.date(2026, 7, 9) }, calendar: calendar)
        controller.load()
        XCTAssertEqual(try XCTUnwrap(controller.weekBilledHours["2026-07-09"]), 3.0, accuracy: 0.0001)
        XCTAssertNil(
            controller.weekBilledHours["2026-07-08"],
            "a day in the same visible week with no draft run must have no indicator"
        )

        // Regenerating (a later draft version) replaces the day's total.
        try store.billing.createDraft(dayID: day.id, lineItems: [
            BillingLineItemInput(narrative: "Consolidated entry.", hours: 0.5, workDate: "2026-07-09")
        ])
        controller.refreshWeekBilledHours()
        XCTAssertEqual(try XCTUnwrap(controller.weekBilledHours["2026-07-09"]), 0.5, accuracy: 0.0001)
    }

    // MARK: - Draft-mutation notification

    // Expected RED: compile error — `BillingDraftController.onDraftMutated` does not
    // exist yet. The counter assertions are outer-level (not inside the closure), so
    // a callback that never fires fails loudly rather than passing vacuously.
    func testDraftMutationsNotifyOnDraftMutated() async throws {
        let store = try SupraStore.inMemory()
        try store.database.writer.write { db in
            try MatterRecord(
                id: "m-mckernon", name: "McKernon Motors v. Liberty Rail", clientNames: "McKernon",
                internalMatterID: "12044-0007", clientID: "MCKERNON", clientMatterID: "VS-LIT-2026-031"
            ).insert(db)
        }
        let day = try store.scratchPad.fetchOrCreateDay("2026-07-09")
        try store.scratchPad.addEntry(dayID: day.id, text: "Working on @McKernon", mentions: ["m-mckernon"])

        let json = """
        {"lineItems":[
          {"matterID":"m-mckernon","narrative":"Drafted opposition to motion to compel.","hours":1.3,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]}
        ]}
        """
        let controller = BillingDraftController(
            store: store,
            service: BillingDraftService(store: store) { _, _ in json },
            timekeeper: BillingTimekeeper(
                id: "TK-1001", name: "Harvey Specter", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
            )
        )
        var notified = 0
        controller.onDraftMutated = { notified += 1 }

        controller.bind(dayID: day.id)
        XCTAssertEqual(notified, 1, "binding to a day reloads the draft and must notify")

        await controller.generate(sensitivity: 0.6)
        XCTAssertNil(controller.statusMessage)
        let afterGenerate = notified
        XCTAssertGreaterThan(afterGenerate, 1, "generation must notify so the week strip's hour indicators refresh")

        let line = try XCTUnwrap(controller.lines.first)
        controller.deleteLine(id: line.id)
        XCTAssertGreaterThan(notified, afterGenerate, "deleting a line changes the day's total and must notify")
    }
}
