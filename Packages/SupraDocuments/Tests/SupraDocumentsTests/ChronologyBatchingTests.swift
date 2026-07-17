import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

/// Gating tests for the batched-chronology pure types (work order Phase 2).
///
/// Every test in this class is COMPILE-RED today: the production file
/// `Sources/SupraDocuments/ChronologyBatching.swift` does not exist yet, so
/// `ChronologyDate`, `ChronologyEntry`, `ChronologyTableParser`,
/// `ChronologyMerge`, `ChronologyBatchPlanner`, and `ChronologyBatch` are all
/// unresolved. Each test additionally records the behavioral contract it will
/// enforce once the types compile.
///
/// Fixtures are synthetic (McKernon Motors v. Liberty Rail); every date is
/// fictional.
final class ChronologyBatchingTests: XCTestCase {

    // MARK: - ChronologyTableParser

    func testTableParserExtractsRowsAndSkipsHeaderAndDecoration() {
        // Expected RED: compile error — cannot find 'ChronologyTableParser'
        // (and 'ChronologyDate') in scope; ChronologyBatching.swift does not exist.
        let markdown = """
        | Date | Event | Source |
        |---|---|---|
        | 2024-01-05 | Complaint served on McKernon Motors [S1] | [S1] |
        | March 2024 | Liberty Rail produced brake records [S2] [S3] | [S2] [S3] |
        """

        let parsed = ChronologyTableParser.parse(markdown)

        // Header and decoration rows are neither entries nor unparsed rows.
        XCTAssertEqual(parsed.unparsedRowCount, 0)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].dateText, "2024-01-05")
        XCTAssertEqual(parsed.entries[0].date, ChronologyDate(year: 2024, month: 1, day: 5))
        XCTAssertTrue(parsed.entries[0].eventText.contains("Complaint served on McKernon Motors"))
        XCTAssertEqual(parsed.entries[0].labels, ["S1"])
        // Partial date: the raw text must round-trip; the canonical `date`
        // precision for month-name forms is the parser's documented choice and is
        // pinned through the ordering matrix, not here.
        XCTAssertEqual(parsed.entries[1].dateText, "March 2024")
        XCTAssertEqual(parsed.entries[1].labels, ["S2", "S3"])
    }

    func testTableParserCountsMalformedRowAttempts() {
        // Expected RED: compile error — cannot find 'ChronologyTableParser' in scope.
        let markdown = """
        | Date | Event | Source |
        | --- | --- | --- |
        | 2024-01-05 | Complaint served on McKernon Motors [S1] | [S1] |
        | 2024-02-10 | Broken row missing its source column
        | Unknown
        """

        let parsed = ChronologyTableParser.parse(markdown)

        // The two pipe-led lines that fail to parse as | Date | Event | Source |
        // rows are counted, so the controller can force review instead of
        // silently dropping model output. Header/decoration are still exempt.
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].labels, ["S1"])
        XCTAssertEqual(parsed.unparsedRowCount, 2)
    }

    func testRenderTableRoundTripsThroughParser() {
        // Expected RED: compile error — cannot find 'ChronologyMerge' /
        // 'ChronologyEntry' / 'ChronologyDate' in scope.
        let entries = [
            ChronologyEntry(
                dateText: "2024-01-05",
                date: ChronologyDate(year: 2024, month: 1, day: 5),
                eventText: "Complaint served on McKernon Motors",
                labels: ["S1"]
            ),
            ChronologyEntry(
                dateText: "2024-02-14",
                date: ChronologyDate(year: 2024, month: 2, day: 14),
                eventText: "Liberty Rail answered the complaint",
                labels: ["S2", "S10"]
            ),
        ]

        let table = ChronologyMerge.renderTable(entries)

        XCTAssertTrue(table.contains("| Date | Event | Source |"), "renderTable must emit the standard header row")
        let reparsed = ChronologyTableParser.parse(table)
        XCTAssertEqual(reparsed.unparsedRowCount, 0)
        XCTAssertEqual(reparsed.entries, entries, "parse(renderTable(entries)) must round-trip the entries exactly")
    }

    // MARK: - ChronologyDate ordering

    func testChronologyDateOrderingMatrix() {
        // Expected RED: compile error — cannot find 'ChronologyDate' in scope.
        // Contract: order by year, then month (nil first), then day (nil first).
        XCTAssertLessThan(
            ChronologyDate(year: 2023, month: 7, day: 15),
            ChronologyDate(year: 2024, month: 1, day: 1),
            "earlier year sorts first regardless of month/day"
        )
        XCTAssertLessThan(
            ChronologyDate(year: 2024, month: nil, day: nil),
            ChronologyDate(year: 2024, month: 1, day: 1),
            "a year-only date sorts before any dated month in that year (nil month first)"
        )
        XCTAssertLessThan(
            ChronologyDate(year: 2024, month: 1, day: nil),
            ChronologyDate(year: 2024, month: 1, day: 5),
            "a month-only date sorts before any day in that month (nil day first)"
        )
        XCTAssertLessThan(
            ChronologyDate(year: 2024, month: 1, day: 5),
            ChronologyDate(year: 2024, month: 2, day: 1)
        )
        XCTAssertLessThan(
            ChronologyDate(year: 2024, month: 1, day: 5),
            ChronologyDate(year: 2024, month: 1, day: 6)
        )
        XCTAssertEqual(
            ChronologyDate(year: 2024, month: 1, day: 5),
            ChronologyDate(year: 2024, month: 1, day: 5)
        )
        XCTAssertFalse(
            ChronologyDate(year: 2024, month: 1, day: 5) < ChronologyDate(year: 2024, month: 1, day: 5),
            "strict ordering: equal dates are not less-than"
        )

        let unsorted = [
            ChronologyDate(year: 2024, month: 2, day: 1),
            ChronologyDate(year: 2024, month: nil, day: nil),
            ChronologyDate(year: 2023, month: 12, day: 31),
            ChronologyDate(year: 2024, month: 1, day: nil),
            ChronologyDate(year: 2024, month: 1, day: 5),
        ]
        XCTAssertEqual(unsorted.sorted(), [
            ChronologyDate(year: 2023, month: 12, day: 31),
            ChronologyDate(year: 2024, month: nil, day: nil),
            ChronologyDate(year: 2024, month: 1, day: nil),
            ChronologyDate(year: 2024, month: 1, day: 5),
            ChronologyDate(year: 2024, month: 2, day: 1),
        ])
    }

    // MARK: - ChronologyMerge

    func testMergeDeduplicatesAcrossBatchesAndUnionsLabelsNumerically() {
        // Expected RED: compile error — cannot find 'ChronologyMerge' in scope.
        // Contract: dedup key = canonical date + case/whitespace-folded eventText;
        // duplicate entries union their labels in numeric ascending order.
        let batch1 = [
            ChronologyEntry(
                dateText: "2024-01-05",
                date: ChronologyDate(year: 2024, month: 1, day: 5),
                eventText: "Complaint served on McKernon Motors",
                labels: ["S2"]
            ),
            ChronologyEntry(
                dateText: "2024-03-01",
                date: ChronologyDate(year: 2024, month: 3, day: 1),
                eventText: "Brake inspection report produced",
                labels: ["S4"]
            ),
        ]
        let batch2 = [
            // Duplicate of batch1's first entry: same canonical date (despite a
            // different dateText rendering) and an eventText that differs only in
            // case and whitespace.
            ChronologyEntry(
                dateText: "January 5, 2024",
                date: ChronologyDate(year: 2024, month: 1, day: 5),
                eventText: "  complaint SERVED on   McKernon   motors ",
                labels: ["S10"]
            ),
            ChronologyEntry(
                dateText: "2024-02-14",
                date: ChronologyDate(year: 2024, month: 2, day: 14),
                eventText: "Liberty Rail answered the complaint",
                labels: ["S3"]
            ),
        ]

        let merged = ChronologyMerge.merge([batch1, batch2])

        XCTAssertEqual(merged.count, 3, "the case/whitespace-variant duplicate must collapse into one entry")
        XCTAssertEqual(merged.map(\.date), [
            ChronologyDate(year: 2024, month: 1, day: 5),
            ChronologyDate(year: 2024, month: 2, day: 14),
            ChronologyDate(year: 2024, month: 3, day: 1),
        ], "merged entries sort by date ascending")
        XCTAssertEqual(
            merged[0].labels, ["S2", "S10"],
            "duplicate labels union in numeric ascending order (lexicographic sorting would put S10 before S2)"
        )
        XCTAssertEqual(merged[1].labels, ["S3"])
        XCTAssertEqual(merged[2].labels, ["S4"])
    }

    func testMergeSortsStablyAndTrailsUndatedInEncounterOrder() {
        // Expected RED: compile error — cannot find 'ChronologyMerge' in scope.
        let may1 = ChronologyDate(year: 2024, month: 5, day: 1)
        let batch1 = [
            ChronologyEntry(dateText: "2024-05-01", date: may1, eventText: "Deposition of Calloway noticed", labels: ["S1"]),
            ChronologyEntry(dateText: "Undated", date: nil, eventText: "Handwritten inspection margin note", labels: ["S2"]),
            ChronologyEntry(dateText: "2024-05-01", date: may1, eventText: "Second notice served the same day", labels: ["S3"]),
        ]
        let batch2 = [
            ChronologyEntry(dateText: "2024-01-01", date: ChronologyDate(year: 2024, month: 1, day: 1), eventText: "Retainer executed", labels: ["S4"]),
            ChronologyEntry(dateText: "Undated", date: nil, eventText: "Unlabeled photograph of coupler", labels: ["S5"]),
        ]

        let merged = ChronologyMerge.merge([batch1, batch2])

        XCTAssertEqual(merged.map(\.eventText), [
            "Retainer executed",
            "Deposition of Calloway noticed",
            "Second notice served the same day",
            "Handwritten inspection margin note",
            "Unlabeled photograph of coupler",
        ], "date sort is stable (equal dates keep encounter order) and undated entries trail in encounter order")
    }

    // MARK: - ChronologyBatchPlanner

    func testPlannerKeepsDocumentsContiguousWithinBudget() {
        // Expected RED: compile error — cannot find 'ChronologyBatchPlanner' in scope.
        // Contract: greedy fill by character budget; one document's items stay
        // contiguous in a single batch when the document fits the budget.
        let items = [
            ChronologyBatchPlanner.Item(documentKey: "brake-report.pdf", charCount: 3_000, orderDate: nil),
            ChronologyBatchPlanner.Item(documentKey: "brake-report.pdf", charCount: 3_000, orderDate: nil),
            ChronologyBatchPlanner.Item(documentKey: "brake-report.pdf", charCount: 3_000, orderDate: nil),
            ChronologyBatchPlanner.Item(documentKey: "coupler-invoice.pdf", charCount: 3_000, orderDate: nil),
            ChronologyBatchPlanner.Item(documentKey: "coupler-invoice.pdf", charCount: 3_000, orderDate: nil),
        ]

        let batches = ChronologyBatchPlanner.plan(items: items, characterBudget: 10_000)

        // brake-report (9,000) fills batch 1; adding coupler-invoice would burst
        // the 10,000 budget, so the invoice's items move together into batch 2.
        XCTAssertEqual(batches.map(\.sourceIndices), [[0, 1, 2], [3, 4]])
        for batch in batches {
            let total = batch.sourceIndices.reduce(0) { $0 + items[$1].charCount }
            XCTAssertLessThanOrEqual(total, 10_000, "no multi-document batch may exceed the character budget")
        }
    }

    func testPlannerSplitsOversizedDocumentAtItemBoundaries() {
        // Expected RED: compile error — cannot find 'ChronologyBatchPlanner' in scope.
        // A single document larger than the whole budget is the one case where a
        // document may span batches — split at item boundaries, never mid-item.
        let items = (0..<5).map { _ in
            ChronologyBatchPlanner.Item(documentKey: "switching-yard-ledger.pdf", charCount: 4_000, orderDate: nil)
        }

        let batches = ChronologyBatchPlanner.plan(items: items, characterBudget: 10_000)

        XCTAssertEqual(batches.map(\.sourceIndices), [[0, 1], [2, 3], [4]])
    }

    func testPlannerOrdersBatchesByDateNilLastStable() {
        // Expected RED: compile error — cannot find 'ChronologyBatchPlanner' in scope.
        // Batch order follows orderDate ascending; nil order dates go last,
        // keeping their input order (stable). Indices always refer to the input
        // array, not the reordered sequence. Sizes force one document per batch.
        let items = [
            ChronologyBatchPlanner.Item(documentKey: "filing-a.pdf", charCount: 9_000, orderDate: Date(timeIntervalSince1970: 1_717_200_000)),
            ChronologyBatchPlanner.Item(documentKey: "note-b.pdf", charCount: 9_000, orderDate: nil),
            ChronologyBatchPlanner.Item(documentKey: "ledger-c.pdf", charCount: 9_000, orderDate: Date(timeIntervalSince1970: 1_673_740_800)),
            ChronologyBatchPlanner.Item(documentKey: "note-d.pdf", charCount: 9_000, orderDate: nil),
        ]

        let batches = ChronologyBatchPlanner.plan(items: items, characterBudget: 10_000)

        XCTAssertEqual(
            batches.map(\.sourceIndices), [[2], [0], [1], [3]],
            "ledger-c (2023) precedes filing-a (2024); the undated notes trail in input order"
        )
    }

    // MARK: - §3.5 review-finding REDs (adversarial review of the batching diff)

    func testMergeKeepsDistinctEventsWithCollidingPartialDates() {
        // Review finding 1 (citation misattribution). Expected RED: dedupKey uses
        // only the canonical parsed date + folded event text, so "Spring 2024" and
        // "Fall 2024" both canonicalize to year-only 2024 and — with identical
        // folded event text — fuse into ONE row ("| Spring 2024 | Quarterly board
        // meeting held [S1] [S3] |"): merged.count is 1, the Fall event vanishes,
        // and S3 is cited for a Spring meeting it never described.
        let spring = ChronologyEntry(
            dateText: "Spring 2024",
            date: ChronologyDate.parse("Spring 2024"),
            eventText: "Quarterly board meeting held",
            labels: ["S1"]
        )
        let fall = ChronologyEntry(
            dateText: "Fall 2024",
            date: ChronologyDate.parse("Fall 2024"),
            eventText: "Quarterly board meeting held",
            labels: ["S3"]
        )

        let merged = ChronologyMerge.merge([[spring], [fall]])

        XCTAssertEqual(merged.count, 2, "events with distinct partial-date texts must not fuse on their shared canonical year")
        XCTAssertEqual(merged.first { $0.dateText == "Spring 2024" }?.labels, ["S1"], "the Spring row must keep only its own citation")
        XCTAssertEqual(merged.first { $0.dateText == "Fall 2024" }?.labels, ["S3"], "the Fall row must keep only its own citation")

        // The committed full-precision contract is unchanged: rows whose canonical
        // dates are fully specified (year+month+day) still dedup across dateText
        // renderings, unioning labels.
        let iso = ChronologyEntry(
            dateText: "2024-01-05",
            date: ChronologyDate(year: 2024, month: 1, day: 5),
            eventText: "Complaint served on McKernon Motors",
            labels: ["S2"]
        )
        let named = ChronologyEntry(
            dateText: "January 5, 2024",
            date: ChronologyDate(year: 2024, month: 1, day: 5),
            eventText: "complaint SERVED on McKernon Motors",
            labels: ["S10"]
        )
        let dedup = ChronologyMerge.merge([[iso], [named]])
        XCTAssertEqual(dedup.count, 1, "full-precision canonical dates still dedup across renderings")
        XCTAssertEqual(dedup.first?.labels, ["S2", "S10"])
    }

    func testDateParsingHandlesDayFirstFormsAndRejectsImpossibleDays() {
        // Review finding 2. Expected RED (concrete wrong values from the current
        // parser): "15 January 2024" → (2024, 1, nil) — the day is silently
        // dropped by the month-year fallback; "2 May 2024" → (2024, 5, nil);
        // "3rd March 2024" → (2024, 3, nil); "the 15th day of January, 2024" →
        // (2024, nil, nil) — bare-year fallback; "February 30, 2024" /
        // "2024-02-30" / "April 31, 2024" are ACCEPTED as real dates instead of
        // parsing to nil (undated trails — the conservative choice).
        XCTAssertEqual(ChronologyDate.parse("15 January 2024"), ChronologyDate(year: 2024, month: 1, day: 15), "day-first month-name form must keep its day")
        XCTAssertEqual(ChronologyDate.parse("2 May 2024"), ChronologyDate(year: 2024, month: 5, day: 2))
        XCTAssertEqual(ChronologyDate.parse("3rd March 2024"), ChronologyDate(year: 2024, month: 3, day: 3), "ordinal day-first form must keep its day")
        XCTAssertEqual(ChronologyDate.parse("the 15th day of January, 2024"), ChronologyDate(year: 2024, month: 1, day: 15), "formal US day-first form must keep its day")

        // Impossible calendar days fail closed to nil (undated trail) rather than
        // being accepted and sorted as real dates.
        XCTAssertNil(ChronologyDate.parse("February 30, 2024"), "February 30 is not a date")
        XCTAssertNil(ChronologyDate.parse("2024-02-30"), "February 30 is not a date in ISO form either")
        XCTAssertNil(ChronologyDate.parse("April 31, 2024"), "April has 30 days")
        // February 29 is representable (2024 is a leap year) — the impossible-day
        // rejection must not over-tighten to a 28-day February.
        XCTAssertEqual(ChronologyDate.parse("February 29, 2024"), ChronologyDate(year: 2024, month: 2, day: 29))
        // Two-digit years stay unparsed — documented conservative choice: a
        // century pivot guess is worse than an undated trail.
        XCTAssertNil(ChronologyDate.parse("1/5/24"))

        // Ordering consequence of the dropped day: the row the source dates
        // January 15 currently sorts ABOVE January 3 (nil day ranks first)
        // while displaying the 15th. With the day kept, January 3 leads.
        let dayFirst = ChronologyEntry(
            dateText: "15 January 2024",
            date: ChronologyDate.parse("15 January 2024"),
            eventText: "Coupler stress test performed",
            labels: ["S2"]
        )
        let monthFirst = ChronologyEntry(
            dateText: "January 3, 2024",
            date: ChronologyDate.parse("January 3, 2024"),
            eventText: "Complaint served on McKernon Motors",
            labels: ["S1"]
        )
        let merged = ChronologyMerge.merge([[dayFirst], [monthFirst]])
        XCTAssertEqual(
            merged.map(\.eventText),
            ["Complaint served on McKernon Motors", "Coupler stress test performed"],
            "January 3 must precede January 15 — the displayed day governs the sort position"
        )
    }

    func testBuildSynthesisWrapsEntriesInUntrustedBoundary() throws {
        // Review finding 6 (injection surface). Expected RED: buildSynthesis
        // currently inlines entry text bare under "MERGED ENTRIES:" — the prompt
        // contains no SECURITY BOUNDARY preamble, no evidence-not-instructions
        // statement, and no untrusted-entry markers around the entries block.
        let entries = [
            ChronologyEntry(
                dateText: "2024-01-05",
                date: ChronologyDate(year: 2024, month: 1, day: 5),
                eventText: "Complaint served on McKernon Motors",
                labels: ["S1"]
            ),
        ]

        let prompt = DocumentChronologyPromptBuilder.buildSynthesis(entries: entries)

        XCTAssertTrue(prompt.contains("SECURITY BOUNDARY:"), "the synthesis prompt must carry the untrusted-content boundary preamble")
        XCTAssertTrue(prompt.contains("never instructions"), "entry text must be declared evidence, never instructions")
        let begin = try XCTUnwrap(prompt.range(of: "BEGIN_UNTRUSTED_ENTRY_DATA"), "entries block must open with an untrusted-data marker")
        let end = try XCTUnwrap(prompt.range(of: "END_UNTRUSTED_ENTRY_DATA"), "entries block must close with an untrusted-data marker")
        let entryText = try XCTUnwrap(prompt.range(of: "Complaint served on McKernon Motors"))
        XCTAssertTrue(
            begin.lowerBound < entryText.lowerBound && entryText.lowerBound < end.lowerBound,
            "the entry text must sit inside the untrusted-data markers"
        )
        // The raw SOURCE envelope stays absent — the committed controller pin
        // (synthesis consumes merged entries, never raw source data) is unchanged.
        XCTAssertFalse(prompt.contains("BEGIN_UNTRUSTED_SOURCE_DATA"), "the synthesis prompt must not regress to embedding raw source envelopes")
    }
}
