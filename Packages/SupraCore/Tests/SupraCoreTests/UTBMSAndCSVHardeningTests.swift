import Foundation
import XCTest
@testable import SupraCore

final class UTBMSAndCSVHardeningTests: XCTestCase {

    // MARK: - UTBMS validation

    func testActivityCodeValidation() {
        XCTAssertEqual(UTBMSCodes.normalizedActivityCode("a103"), "A103") // normalizes case
        XCTAssertEqual(UTBMSCodes.normalizedActivityCode(" A106 "), "A106")
        XCTAssertNil(UTBMSCodes.normalizedActivityCode("A999"), "unknown activity code is rejected")
        XCTAssertNil(UTBMSCodes.normalizedActivityCode("L350"), "a task code is not an activity code")
        XCTAssertNil(UTBMSCodes.normalizedActivityCode(""))
    }

    func testTaskCodeValidationByCodeSet() {
        // Litigation validates against the L-set.
        XCTAssertEqual(UTBMSCodes.normalizedTaskCode("l350", codeSet: .litigation), "L350")
        XCTAssertNil(UTBMSCodes.normalizedTaskCode("L999", codeSet: .litigation), "unknown L-code rejected")
        XCTAssertNil(UTBMSCodes.normalizedTaskCode("APA-01", codeSet: .litigation), "firm code invalid for litigation")
        // Transactional/advisory task codes are firm-specific → accepted as entered (uppercased).
        XCTAssertEqual(UTBMSCodes.normalizedTaskCode("apa-01", codeSet: .transactional), "APA-01")
        XCTAssertEqual(UTBMSCodes.normalizedTaskCode("c-100", codeSet: .advisory), "C-100")
        // .none carries no task code.
        XCTAssertNil(UTBMSCodes.normalizedTaskCode("L350", codeSet: .none))
    }

    func testTaskCodePickerOptions() {
        XCTAssertFalse(UTBMSCodes.taskCodes(for: .litigation).isEmpty)
        XCTAssertTrue(UTBMSCodes.taskCodes(for: .transactional).isEmpty, "no built-in list for firm-specific sets")
        XCTAssertTrue(UTBMSCodes.taskCodes(for: .none).isEmpty)
        XCTAssertEqual(UTBMSCodes.activity.first?.code, "A101")
        XCTAssertTrue(UTBMSCodes.litigationTask.contains { $0.code == "L350" })
    }

    // MARK: - CSV formula-injection hardening

    func testFormulaHardening() {
        XCTAssertEqual(BillingExporter.formulaHardened("=cmd|' /c calc'!A1"), "'=cmd|' /c calc'!A1")
        XCTAssertEqual(BillingExporter.formulaHardened("+1+1"), "'+1+1")
        XCTAssertEqual(BillingExporter.formulaHardened("-2"), "'-2")
        XCTAssertEqual(BillingExporter.formulaHardened("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(BillingExporter.formulaHardened("Drafted opposition."), "Drafted opposition.", "normal text untouched")
    }

    func testCSVExportHardensFormulaNarrative() {
        let line = BillingLine(
            clientID: "C", lawFirmMatterID: "F", clientDisplay: "Acme", matterDisplay: "Matter",
            narrative: "=HYPERLINK(\"http://evil\")", hours: 1, workDate: "2026-06-22",
            activityCode: "A103", rate: 450
        )
        let tk = BillingTimekeeper(id: "TK", name: "C. Spivey", classification: "PARTNER", defaultRate: 450, lawFirmID: "F")
        let csv = BillingExporter.csv(lines: [line], timekeeper: tk)
        // The dangerous cell is prefixed with an apostrophe and quoted (contains comma/quote).
        XCTAssertTrue(csv.contains("\"'=HYPERLINK"), "formula narrative must be neutralized")
        XCTAssertFalse(csv.contains(",=HYPERLINK"), "raw formula must not appear unescaped")
    }
}
