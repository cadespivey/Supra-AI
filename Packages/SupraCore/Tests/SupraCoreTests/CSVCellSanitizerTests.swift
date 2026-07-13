import SupraCore
import XCTest

final class CSVCellSanitizerTests: XCTestCase {
    func testACRCSV001NeutralizesEveryFormulaPrefixIncludingEffectiveLeadingCharacters() {
        let dangerous = [
            "=1+1", "+SUM(A1)", "-2", "@cmd", "\t=1+1", "\r=1+1",
            " \t=1+1", "\u{FEFF}=1+1", "\u{0000}@cmd", "\n  +1"
        ]
        for value in dangerous {
            XCTAssertEqual(CSVCellSanitizer.neutralize(value), "'" + value, value.debugDescription)
        }
    }

    func testACRCSV002StrictPolicyNeutralizesNegativeNumbersAndPreservesSafeUnicode() {
        XCTAssertEqual(CSVCellSanitizer.neutralize("-12.50"), "'-12.50")
        XCTAssertEqual(CSVCellSanitizer.neutralize("12.50"), "12.50")
        XCTAssertEqual(CSVCellSanitizer.neutralize("Résumé — 安全"), "Résumé — 安全")
        XCTAssertEqual(CSVCellSanitizer.neutralize(""), "")
    }

    func testACRCSV003EncodingHardensBeforeRFC4180Quoting() {
        XCTAssertEqual(CSVCellSanitizer.encode("=SUM(A1,A2)"), "\"'=SUM(A1,A2)\"")
        XCTAssertEqual(CSVCellSanitizer.encode("say \"hello\"\nnext"), "\"say \"\"hello\"\"\nnext\"")
        XCTAssertEqual(CSVCellSanitizer.encode("ordinary"), "ordinary")
    }

    func testACRCSV004BillingCSVAndClipboardUseSharedPolicy() {
        let line = BillingLine(
            clientID: "C", lawFirmMatterID: "M", clientDisplay: "=Client",
            matterDisplay: " Matter", narrative: "\u{FEFF}@HYPERLINK", hours: 1,
            workDate: "2026-07-13", rate: 100
        )
        let timekeeper = BillingTimekeeper(
            id: "TK", name: "Lawyer", classification: "PARTNER", defaultRate: 100, lawFirmID: "F"
        )

        let csv = BillingExporter.csv(lines: [line], timekeeper: timekeeper)
        let clipboard = BillingExporter.clipboardTSV(lines: [line], timekeeper: timekeeper)

        XCTAssertTrue(csv.contains("'=Client"))
        XCTAssertTrue(csv.contains("'\u{FEFF}@HYPERLINK"))
        XCTAssertTrue(clipboard.contains("'\u{FEFF}@HYPERLINK"))
    }
}
