import Combine
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
        let parsed = ScratchPadTokenParser.parse("TC w/ @McKernon-LibertyRail, re custodian list #call #discovery")
        XCTAssertEqual(parsed.mentions, ["McKernon-LibertyRail"])
        XCTAssertEqual(parsed.tags, ["call", "discovery"])
    }

    func testTokenParserDeduplicatesAndIgnoresBareSigils() {
        let parsed = ScratchPadTokenParser.parse("@McKernon @McKernon # @ #drafting plain")
        XCTAssertEqual(parsed.mentions, ["McKernon"])
        XCTAssertEqual(parsed.tags, ["drafting"])
    }

    // MARK: - Tag vocabulary

    func testMergedTagVocabularyKeepsUsedFirstThenCuratedExtras() {
        let merged = ScratchPadTagResolver.mergedTagVocabulary(
            used: ["custodianhold", "discovery"],
            curated: ["call", "discovery", "draft"]
        )
        // Used tags lead (in order); curated extras follow; the shared "discovery"
        // appears once, in its used position.
        XCTAssertEqual(merged, ["custodianhold", "discovery", "call", "draft"])
    }

    func testMergedTagVocabularyDedupesCaseInsensitivelyPreferringUsedSpelling() {
        let merged = ScratchPadTagResolver.mergedTagVocabulary(used: ["Draft"], curated: ["draft", "review"])
        XCTAssertEqual(merged, ["Draft", "review"])
    }

    func testDefaultLitigationTagsIncludeReservedNonBillableTag() {
        // The starter set must offer the reserved non-billable tag so the user can
        // discover it from `#` autocomplete; matching is case-insensitive.
        XCTAssertTrue(
            ScratchPadTagResolver.defaultLitigationTags.contains {
                $0.caseInsensitiveCompare(ScratchPadEntryRecord.nonBillableTag) == .orderedSame
            },
            "defaultLitigationTags should include \(ScratchPadEntryRecord.nonBillableTag)"
        )
    }

    func testTagSuggestionsOverVocabularyFilterByPrefixAndListAllWhenEmpty() {
        let vocab = ScratchPadTagResolver.mergedTagVocabulary(used: [])
        XCTAssertEqual(ScratchPadTagResolver.tagSuggestions(prefix: "", knownTags: vocab, limit: 3).count, 3)
        XCTAssertEqual(ScratchPadTagResolver.tagSuggestions(prefix: "dr", knownTags: vocab), ["draft"])
    }

    // MARK: - Cross-day search

    func testSearchFindsNoteEntriesAcrossDays() throws {
        let store = try makeStore()
        func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
            var c = DateComponents()
            c.year = year; c.month = month; c.day = dayOfMonth; c.hour = 12
            return Calendar.current.date(from: c)!
        }
        let day1 = ScratchPadController(store: store, now: { day(2026, 6, 20) })
        day1.load()
        XCTAssertTrue(day1.addEntry("Deposition prep for @McKernon #deposition"))

        let day2 = ScratchPadController(store: store, now: { day(2026, 6, 22) })
        day2.load()
        XCTAssertTrue(day2.addEntry("Drafted motion to compel #discovery"))

        // Same-day term.
        day2.search("motion")
        XCTAssertEqual(day2.searchResults.map(\.text), ["Drafted motion to compel #discovery"])

        // Cross-day: a term that only appears on day 1 is found while viewing day 2.
        day2.search("deposition")
        XCTAssertTrue(day2.searchResults.contains { $0.day == "2026-06-20" })

        // A one-character term clears results (back to the normal day view).
        day2.search("m")
        XCTAssertTrue(day2.searchResults.isEmpty)
    }

    // MARK: - Resolution

    func testResolveMentionsByExplicitMapAndNamePrefix() {
        let chips = [MatterChip(id: "m1", name: "McKernon Motors v. Liberty Rail"), MatterChip(id: "m2", name: "Hessington MSA")]
        // Best-effort: "McKernon" matches the slug of "McKernon Motors v. Liberty Rail".
        XCTAssertEqual(ScratchPadTagResolver.resolveMentions(["McKernon"], chips: chips), ["m1"])
        // Explicit pick wins regardless of text.
        XCTAssertEqual(ScratchPadTagResolver.resolveMentions(["x"], chips: chips, explicit: ["x": "m2"]), ["m2"])
    }

    func testMatterSuggestionsRankPrefixFirst() {
        let chips = [MatterChip(id: "m1", name: "McKernon Motors v. Liberty Rail"), MatterChip(id: "m2", name: "Hessington MSA")]
        let suggestions = ScratchPadTagResolver.matterSuggestions(prefix: "hes", chips: chips)
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
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertTrue(controller.addEntry("Reviewed motion to compel for @McKernon #discovery #review"))
        XCTAssertEqual(controller.entries.count, 1)
        let entry = controller.entries[0]
        XCTAssertEqual(entry.mentionMatterIDs, [matter.id])
        XCTAssertEqual(entry.tags, ["discovery", "review"])
        XCTAssertEqual(controller.knownTags, ["discovery", "review"])
    }

    func testAddEntryHonorsExplicitMentionBinding() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Hessington Oil v. Gillis Industries")
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.load()
        XCTAssertTrue(controller.addEntry("Drafted issues memo @hes", explicitMentions: ["hes": matter.id]))
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

    // MARK: - Live @matter registry

    /// A matter created while the pad is already open must appear in the `@`
    /// autocomplete registry immediately, without reopening the pad or restarting —
    /// the regression `observeMatters(_:)` fixes.
    func testObserveMattersUpdatesChipsWhenMatterCreatedWhilePadOpen() throws {
        let store = try makeStore()
        let subject = CurrentValueSubject<[MatterSummary], Never>([])
        let controller = ScratchPadController(store: store, now: fixedNow)
        controller.observeMatters(subject.eraseToAnyPublisher())
        controller.load()
        pumpMainRunLoop()
        XCTAssertTrue(controller.matterChips.isEmpty, "No matters yet, so no @ suggestions")

        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        subject.send([MatterSummary(record: matter)])
        pumpMainRunLoop()

        XCTAssertEqual(controller.matterChips.map(\.id), [matter.id])
        XCTAssertEqual(controller.matterChips.map(\.name), ["McKernon Motors v. Liberty Rail"])
    }

    /// Drains blocks scheduled on the main run loop (Combine's `.receive(on:)`)
    /// so an assertion sees the delivered value.
    private func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
