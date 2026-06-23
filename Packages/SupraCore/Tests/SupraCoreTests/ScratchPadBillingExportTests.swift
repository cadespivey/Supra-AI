import Foundation
@testable import SupraCore
import XCTest

/// Milestone 4 Phase 4a — deterministic reconciliation + LEDES/CSV exporters.
final class ScratchPadBillingExportTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001",
        name: "C. Spivey",
        classification: "PARTNER",
        defaultRate: 450,
        lawFirmID: "98-7654321"
    )

    private func sampleLines() -> [BillingLine] {
        [
            BillingLine(
                clientID: "VYSTAR", lawFirmMatterID: "12044-0007", clientMatterID: "VS-LIT-2026-031",
                clientDisplay: "VyStar Credit Union", matterDisplay: "VyStar",
                narrative: "Drafted opposition to Defendant's motion to compel.",
                hours: 1.3, workDate: "2026-06-22", taskCode: "L350", activityCode: "A103", confidence: .high
            ),
            BillingLine(
                clientID: "VYSTAR", lawFirmMatterID: "12044-0007", clientMatterID: "VS-LIT-2026-031",
                clientDisplay: "VyStar Credit Union", matterDisplay: "VyStar",
                narrative: "Telephone conference re custodian list.",
                hours: 0.4, workDate: "2026-06-22", taskCode: "L350", activityCode: "A106", confidence: .medium
            ),
            BillingLine(
                clientID: "MERIDIAN", lawFirmMatterID: "12061-0003",
                clientDisplay: "Meridian Health Systems, Inc.", matterDisplay: "Meridian",
                narrative: "Reviewed MSA redlines, with commas, and \"quotes\".",
                hours: 0.8, workDate: "2026-06-22", activityCode: "A104", confidence: .medium
            )
        ]
    }

    func testReconcileTotalsAndSubtotals() throws {
        let result = BillingReconciliationEngine.reconcile(lines: sampleLines(), timekeeper: timekeeper)
        XCTAssertEqual(result.billableTotalHours, 2.5, accuracy: 0.001)
        XCTAssertEqual(result.totalAmount, 1125, accuracy: 0.001)
        XCTAssertEqual(result.byMatter.count, 2)
        let vystar = try XCTUnwrap(result.byMatter.first { $0.matterKey == "VyStar" })
        XCTAssertEqual(vystar.hours, 1.7, accuracy: 0.001)
        XCTAssertEqual(vystar.amount, 765, accuracy: 0.001)
        let meridian = try XCTUnwrap(result.byMatter.first { $0.matterKey == "Meridian" })
        XCTAssertEqual(meridian.hours, 0.8, accuracy: 0.001)
        XCTAssertEqual(meridian.amount, 360, accuracy: 0.001)
    }

    func testReconcileFlagsNonMultipleLowConfidenceAndUnassigned() {
        let lines = [
            BillingLine(lawFirmMatterID: "12044-0007", narrative: "odd", hours: 0.15, workDate: "2026-06-22", confidence: .high),
            BillingLine(lawFirmMatterID: "12044-0007", narrative: "guess", hours: 0.3, workDate: "2026-06-22", confidence: .low),
            BillingLine(narrative: "no matter", hours: 0.2, workDate: "2026-06-22", confidence: .medium)
        ]
        let result = BillingReconciliationEngine.reconcile(lines: lines, timekeeper: timekeeper, increment: 0.1)
        XCTAssertTrue(result.flags.contains { $0.contains("Line 1") && $0.contains("multiple") })
        XCTAssertTrue(result.flags.contains { $0.contains("Line 2") && $0.contains("low confidence") })
        XCTAssertTrue(result.flags.contains { $0.contains("Line 3") && $0.contains("no matter") })
    }

    func testLEDESStructureAndArithmetic() {
        let text = BillingExporter.ledes1998B(lines: sampleLines(), timekeeper: timekeeper, invoice: BillingInvoiceInfo(invoiceDate: "2026-06-22"))
        let rows = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.first, "LEDES1998B[]")

        let header = rows[1]
        XCTAssertTrue(header.hasSuffix("[]"))
        XCTAssertEqual(String(header.dropLast(2)).components(separatedBy: "|").count, 24)

        let dataRows = Array(rows.dropFirst(2))
        XCTAssertEqual(dataRows.count, 3)
        for row in dataRows {
            XCTAssertTrue(row.hasSuffix("[]"))
            let fields = String(row.dropLast(2)).components(separatedBy: "|")
            XCTAssertEqual(fields.count, 24)
            XCTAssertEqual(fields[9], "F", "fee type")
            XCTAssertEqual(fields[15], "", "expense code blank for fees")
            let units = Double(fields[10])!
            let unitCost = Double(fields[20])!
            let lineTotal = Double(fields[12])!
            XCTAssertEqual(units * unitCost, lineTotal, accuracy: 0.01)
        }
    }

    func testLEDESInvoiceGroupingAndLineNumbering() {
        let text = BillingExporter.ledes1998B(lines: sampleLines(), timekeeper: timekeeper, invoice: BillingInvoiceInfo(invoiceDate: "2026-06-22"))
        let dataRows = Array(text.split(separator: "\n").map(String.init).dropFirst(2))
        func field(_ row: String, _ index: Int) -> String {
            String(row.dropLast(2)).components(separatedBy: "|")[index]
        }
        // Two VyStar lines: invoice total 765.00, line numbers 1 and 2.
        XCTAssertEqual(field(dataRows[0], 4), "765.00")
        XCTAssertEqual(field(dataRows[1], 4), "765.00")
        XCTAssertEqual(field(dataRows[0], 8), "1")
        XCTAssertEqual(field(dataRows[1], 8), "2")
        // One Meridian line: its own invoice, total 360.00, line number restarts at 1.
        XCTAssertEqual(field(dataRows[2], 4), "360.00")
        XCTAssertEqual(field(dataRows[2], 8), "1")
        // Dates are YYYYMMDD; task code blank on the transactional Meridian line.
        XCTAssertEqual(field(dataRows[2], 13), "20260622")
        XCTAssertEqual(field(dataRows[2], 14), "")
    }

    func testCSVHasHeaderRowsAndTotal() {
        let csv = BillingExporter.csv(lines: sampleLines(), timekeeper: timekeeper)
        let rows = csv.split(separator: "\n").map(String.init)
        XCTAssertTrue(rows[0].hasPrefix("Date,Client,Matter,Timekeeper,Task Code,Activity Code,Narrative,Hours,Rate,Amount"))
        XCTAssertEqual(rows.count, 5) // header + 3 lines + total
        XCTAssertTrue(rows.last!.contains("TOTAL"))
        XCTAssertTrue(rows.last!.hasSuffix("2.5,,1125.00"))
        // The narrative with commas/quotes is escaped.
        XCTAssertTrue(rows[3].contains("\"Reviewed MSA redlines, with commas, and \"\"quotes\"\".\""))
    }

    func testClipboardTSV() {
        let tsv = BillingExporter.clipboardTSV(lines: sampleLines(), timekeeper: timekeeper)
        let rows = tsv.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "Date\tClient / Matter\tHours\tNarrative")
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[1].contains("\t1.3\t"))
    }

    // MARK: - Narrative terminal punctuation

    func testNarrativeTerminalFormatting() {
        XCTAssertEqual(BillingExporter.formatNarrative("Drafted opposition.", terminal: .asWritten), "Drafted opposition.")
        XCTAssertEqual(BillingExporter.formatNarrative("Drafted opposition.", terminal: .noPeriod), "Drafted opposition")
        XCTAssertEqual(BillingExporter.formatNarrative("Drafted opposition.", terminal: .semicolon), "Drafted opposition;")
        // A "(split)" suffix is preserved; the semicolon lands after it.
        XCTAssertEqual(BillingExporter.formatNarrative("Review discovery (split)", terminal: .semicolon), "Review discovery (split);")
        XCTAssertEqual(BillingExporter.formatNarrative("Review discovery (split).", terminal: .noPeriod), "Review discovery (split)")
        // An existing semicolon is not doubled.
        XCTAssertEqual(BillingExporter.formatNarrative("Confer with client;", terminal: .semicolon), "Confer with client;")
    }

    func testTerminalAppliesInCSVExport() {
        let line = BillingLine(
            clientID: "C", lawFirmMatterID: "F", matterDisplay: "M",
            narrative: "Drafted opposition.", hours: 1.0, workDate: "2026-06-22",
            narrativeTerminal: .semicolon
        )
        let csv = BillingExporter.csv(lines: [line], timekeeper: timekeeper)
        XCTAssertTrue(csv.contains("Drafted opposition;"))
        XCTAssertFalse(csv.contains("Drafted opposition."))
    }

    // MARK: - Weekly table

    func testWeeklyTableExport() {
        let line = BillingLine(
            clientID: "VYSTAR", lawFirmMatterID: "12044-0007", clientMatterID: "VS-031",
            clientDisplay: "VyStar Credit Union", matterDisplay: "VyStar - Celebration Point",
            narrative: "Draft opposition to motion to compel.", hours: 1.0, workDate: "2026-06-22",
            narrativeTerminal: .noPeriod
        )
        let rows = BillingExporter.weeklyTable(lines: [line]).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "| DATE | CLIENT / MATTER | MATTER NO. | NARRATIVE | TIME |")
        XCTAssertEqual(rows[1], "|---|---|---|---|---:|")
        // MM/DD/YYYY date, matter name, firm matter no., punctuation-free narrative, one-decimal time.
        XCTAssertEqual(rows[2], "| 06/22/2026 | VyStar - Celebration Point | 12044-0007 | Draft opposition to motion to compel | 1.0 |")
    }
}
