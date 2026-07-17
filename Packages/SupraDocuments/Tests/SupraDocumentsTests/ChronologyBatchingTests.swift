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
}
