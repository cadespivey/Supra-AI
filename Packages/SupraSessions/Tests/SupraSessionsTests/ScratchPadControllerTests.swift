import Foundation
import GRDB
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class ScratchPadControllerTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        try SupraStore.inMemory()
    }

    private func fixedNow() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 22; components.hour = 12
        return Calendar.current.date(from: components)!
    }

    // MARK: - Token parsing

    func testTokenParserExtractsMentionsAndTags() {
        let parsed = ScratchPadTokenParser.parse("TC w/ @Acme-Roe, re custodian list #call #discovery")
        XCTAssertEqual(parsed.mentions, ["Acme-Roe"])
        XCTAssertEqual(parsed.tags, ["call", "discovery"])
    }

    func testTokenParserDeduplicatesAndIgnoresBareSigils() {
        let parsed = ScratchPadTokenParser.parse("@VyStar @VyStar # @ #drafting plain")
        XCTAssertEqual(parsed.mentions, ["VyStar"])
        XCTAssertEqual(parsed.tags, ["drafting"])
    }

    // MARK: - Resolution

    func testResolveMentionsByExplicitMapAndNamePrefix() {
        let chips = [MatterChip(id: "m1", name: "Reardon v. VyStar"), MatterChip(id: "m2", name: "Meridian MSA")]
        // Best-effort: "VyStar" matches the slug of "Reardon v. VyStar".
        XCTAssertEqual(ScratchPadTagResolver.resolveMentions(["VyStar"], chips: chips), ["m1"])
        // Explicit pick wins regardless of text.
        XCTAssertEqual(ScratchPadTagResolver.resolveMentions(["x"], chips: chips, explicit: ["x": "m2"]), ["m2"])
    }

    func testMatterSuggestionsRankPrefixFirst() {
        let chips = [MatterChip(id: "m1", name: "Reardon v. VyStar"), MatterChip(id: "m2", name: "Meridian MSA")]
        let suggestions = ScratchPadTagResolver.matterSuggestions(prefix: "mer", chips: chips)
        XCTAssertEqual(suggestions.first?.id, "m2")
    }

    // MARK: - Controller

    func testLoadCreatesTodayWithExpectedDayString() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertEqual(controller.currentDay?.day, "2026-06-22")
        XCTAssertEqual(controller.displayedDate, "2026-06-22")
        XCTAssertEqual(controller.recentDays.count, 1)
    }

    func testSelectDateBrowsesWithoutCreatingThenLazyCreatesOnFirstEntry() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load() // seeds today (2026-06-22)
        XCTAssertEqual(controller.recentDays.count, 1)

        // Browsing an earlier, note-less date shows an empty pad and creates no row.
        controller.selectDate(date(2026, 6, 20))
        XCTAssertNil(controller.currentDay, "browsing an empty date must not create a day row")
        XCTAssertEqual(controller.displayedDate, "2026-06-20")
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertEqual(controller.recentDays.count, 1, "no empty day was persisted")

        // The first entry lazily persists the day, which then joins the recent list.
        XCTAssertTrue(controller.addEntry("Backfilled note #intake"))
        XCTAssertEqual(controller.currentDay?.day, "2026-06-20")
        XCTAssertEqual(controller.entries.count, 1)
        XCTAssertEqual(Set(controller.recentDays.map(\.day)), ["2026-06-22", "2026-06-20"])
    }

    func testSelectDateReopensAnExistingDay() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        controller.selectDate(date(2026, 6, 18))
        XCTAssertTrue(controller.addEntry("Earlier work #research"))

        // Jump away, then back via the calendar: the saved note is reloaded.
        controller.selectDate(date(2026, 6, 22))
        XCTAssertTrue(controller.entries.isEmpty)
        controller.selectDate(date(2026, 6, 18))
        XCTAssertEqual(controller.currentDay?.day, "2026-06-18")
        XCTAssertEqual(controller.entries.count, 1)
        XCTAssertEqual(controller.displayedDate, "2026-06-18")
    }

    func testLockAndReopenRecordAuditEvents() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        controller.lockCurrentDay()
        controller.reopenCurrentDay()
        let types = try store.database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT event_type FROM audit_events")
        }
        XCTAssertTrue(types.contains("scratchpad_day_locked"))
        XCTAssertTrue(types.contains("scratchpad_day_reopened"))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = 12
        return Calendar.current.date(from: components)!
    }

    func testAddEntryPersistsResolvedMentionsAndTags() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Reardon v. VyStar")
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertTrue(controller.addEntry("Reviewed motion to compel for @VyStar #discovery #review"))
        XCTAssertEqual(controller.entries.count, 1)
        let entry = controller.entries[0]
        XCTAssertEqual(entry.mentionMatterIDs, [matter.id])
        XCTAssertEqual(entry.tags, ["discovery", "review"])
        XCTAssertEqual(controller.knownTags, ["discovery", "review"])
    }

    func testAddEntryHonorsExplicitMentionBinding() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Meridian Health Systems")
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertTrue(controller.addEntry("Drafted issues memo @mer", explicitMentions: ["mer": matter.id]))
        XCTAssertEqual(controller.entries[0].mentionMatterIDs, [matter.id])
    }

    func testAddEntryBlockedWhenDayLocked() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        controller.lockCurrentDay()
        XCTAssertTrue(controller.isCurrentDayLocked)
        XCTAssertFalse(controller.addEntry("Should not persist"))
        XCTAssertTrue(controller.entries.isEmpty)
        controller.reopenCurrentDay()
        XCTAssertTrue(controller.addEntry("Now allowed"))
        XCTAssertEqual(controller.entries.count, 1)
    }

    func testEntriesPersistAcrossControllerReload() throws {
        let store = try makeStore()
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertTrue(controller.addEntry("First note #drafting"))
        // A fresh controller over the same store sees the same day's entries.
        let reopened = ScratchPadController(store: store, now: fixedNow)
        reopened.load()
        XCTAssertEqual(reopened.entries.map(\.text), ["First note #drafting"])
        XCTAssertEqual(reopened.entries.first?.seq, 1)
    }
}
