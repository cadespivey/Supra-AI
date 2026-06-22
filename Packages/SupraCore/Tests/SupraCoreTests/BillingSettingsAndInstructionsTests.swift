import Foundation
import XCTest
@testable import SupraCore

final class BillingSettingsAndInstructionsTests: XCTestCase {

    // MARK: - BillingSettings

    func testDefaultsMatchSpec() {
        let settings = BillingSettings.default
        XCTAssertEqual(settings.globalInstructions, "")
        XCTAssertTrue(settings.autoTimestamp, "auto-timestamp is on by default (locked decision 2)")
        XCTAssertEqual(settings.sensitivity, BillingSensitivity.defaultValue, accuracy: 0.0001)
        XCTAssertEqual(settings.roundingIncrement, 0.1, accuracy: 0.0001)
        XCTAssertTrue(settings.utbmsAutoCoding, "UTBMS auto-coding is on by default (spec §L.b)")
        XCTAssertEqual(settings.timekeeper.defaultRate, 0)
    }

    func testRoundTripEncodeDecode() throws {
        let original = BillingSettings(
            globalInstructions: "Block billing prohibited.",
            autoTimestamp: false,
            sensitivity: 0.8,
            roundingIncrement: 0.25,
            utbmsAutoCoding: false,
            timekeeper: BillingTimekeeper(id: "TK-9", name: "A. Counsel", classification: "PARTNER", defaultRate: 525, lawFirmID: "98-1")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BillingSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTolerantDecodeFillsMissingFieldsWithDefaults() throws {
        // A blob from an earlier app version that only stored two fields.
        let json = #"{"globalInstructions":"Cap research at 2.0h","sensitivity":0.3}"#
        let decoded = try JSONDecoder().decode(BillingSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.globalInstructions, "Cap research at 2.0h")
        XCTAssertEqual(decoded.sensitivity, 0.3, accuracy: 0.0001)
        // Everything else falls back to defaults rather than throwing.
        XCTAssertTrue(decoded.autoTimestamp)
        XCTAssertEqual(decoded.roundingIncrement, 0.1, accuracy: 0.0001)
        XCTAssertTrue(decoded.utbmsAutoCoding)
    }

    func testInitClampsSensitivityAndIncrement() {
        let bad = BillingSettings(sensitivity: 9, roundingIncrement: -1)
        XCTAssertEqual(bad.sensitivity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(bad.roundingIncrement, 0.1, accuracy: 0.0001)
    }

    // MARK: - BillingInstructions merge (Phase 7 gate)

    func testComposedStackSurfacesGlobalOverrideAndGuideline() {
        let rules = [
            MatterBillingRules(
                matterID: "m1",
                matterName: "Reardon v. VyStar",
                clientName: "VyStar",
                codeSet: .litigation,
                overrideInstructions: "Do not bill clerical tasks.",
                guidelineExcerpts: ["Travel is billed at 50%. Block billing is prohibited."]
            )
        ]
        let stack = BillingInstructions.composedStack(global: "Firm minimum increment is 0.1h.", rules: rules)
        // The merged stack must carry all three layers — the Phase-7 audit gate.
        XCTAssertTrue(stack.contains("Firm minimum increment is 0.1h."))
        XCTAssertTrue(stack.contains("Do not bill clerical tasks."))
        XCTAssertTrue(stack.contains("Travel is billed at 50%."))
        XCTAssertTrue(stack.contains("codeSet=litigation"))
        XCTAssertTrue(stack.contains("id=m1"))
    }

    func testComposedStackEmptyGlobalAndNoRules() {
        let stack = BillingInstructions.composedStack(global: "   ", rules: [])
        XCTAssertTrue(stack.contains("Global billing instructions:\n(none)"))
        XCTAssertTrue(stack.contains("no matters on file"))
    }

    func testAutoCodingOffEmitsDirective() {
        let on = BillingInstructions.composedStack(global: "", rules: [], autoCoding: true)
        XCTAssertFalse(on.contains("UTBMS coding is OFF"))
        let off = BillingInstructions.composedStack(global: "", rules: [], autoCoding: false)
        XCTAssertTrue(off.contains("UTBMS coding is OFF"))
    }

    func testGuidelineExcerptIsBudgeted() {
        let long = String(repeating: "word ", count: 1000) // ~5000 chars
        let rule = MatterBillingRules(matterID: "m1", matterName: "X", guidelineExcerpts: [long])
        let block = BillingInstructions.matterRulesBlock([rule])
        XCTAssertLessThan(block.count, long.count)
        XCTAssertTrue(block.contains("…"))
    }

    func testHasControllingRules() {
        XCTAssertFalse(MatterBillingRules(matterID: "m", matterName: "X").hasControllingRules)
        XCTAssertTrue(MatterBillingRules(matterID: "m", matterName: "X", overrideInstructions: "no clerical").hasControllingRules)
        XCTAssertTrue(MatterBillingRules(matterID: "m", matterName: "X", guidelineExcerpts: ["rule"]).hasControllingRules)
        XCTAssertFalse(MatterBillingRules(matterID: "m", matterName: "X", overrideInstructions: "   ", guidelineExcerpts: ["  "]).hasControllingRules)
    }

    // MARK: - BillingExportValidator

    private func validLine(codeSet: BillingCodeSet = .litigation) -> BillingLine {
        BillingLine(
            clientID: "VYSTAR", lawFirmMatterID: "12044-0007", clientMatterID: "VS-1",
            narrative: "Drafted opposition.", hours: 1.3, workDate: "2026-06-22",
            taskCode: codeSet.requiresTaskCode ? "L350" : nil, activityCode: "A103", rate: 450, codeSet: codeSet
        )
    }

    private let timekeeper = BillingTimekeeper(id: "TK-1", name: "C. Spivey", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321")

    func testValidDraftHasNoIssues() {
        XCTAssertTrue(BillingExportValidator.validateForLEDES(lines: [validLine()], timekeeper: timekeeper).isEmpty)
    }

    func testNoLinesBlocks() {
        let issues = BillingExportValidator.validateForLEDES(lines: [], timekeeper: timekeeper)
        XCTAssertEqual(issues.map(\.kind), [.noLines])
    }

    func testMissingTimekeeperFieldsBlock() {
        let bad = BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: "")
        let kinds = Set(BillingExportValidator.validateForLEDES(lines: [validLine()], timekeeper: bad).map(\.kind))
        XCTAssertTrue(kinds.contains(.timekeeperRate))
        XCTAssertTrue(kinds.contains(.timekeeperID))
        XCTAssertTrue(kinds.contains(.firmID))
    }

    func testMissingClientAndFirmMatterIDBlock() {
        let line = BillingLine(clientID: nil, lawFirmMatterID: nil, narrative: "x", hours: 1, workDate: "2026-06-22", activityCode: "A103", codeSet: .none)
        let kinds = Set(BillingExportValidator.validateForLEDES(lines: [line], timekeeper: timekeeper).map(\.kind))
        XCTAssertTrue(kinds.contains(.clientID))
        XCTAssertTrue(kinds.contains(.firmMatterID))
    }

    func testTransactionalLineNeedsTaskCodeButNoneDoesNot() {
        // .none code set: a blank task code is acceptable (spec §8).
        XCTAssertTrue(BillingExportValidator.validateForLEDES(lines: [validLine(codeSet: .none)], timekeeper: timekeeper).isEmpty)
        // transactional: blank task code is a blocking gap (the "set code" chip).
        let transactional = BillingLine(
            clientID: "C", lawFirmMatterID: "F", narrative: "Reviewed APA.", hours: 0.5, workDate: "2026-06-22",
            taskCode: nil, activityCode: "A104", rate: 450, codeSet: .transactional
        )
        let kinds = BillingExportValidator.validateForLEDES(lines: [transactional], timekeeper: timekeeper).map(\.kind)
        XCTAssertEqual(kinds, [.taskCode])
    }

    func testExplicitPerLineZeroRateBlocksEvenWithValidTimekeeper() {
        // A user edit can store rate == 0 on a line; the timekeeper default is fine,
        // so the invoice-level check passes — the per-line check must still block it.
        var line = validLine()
        line.rate = 0
        let kinds = BillingExportValidator.validateForLEDES(lines: [line], timekeeper: timekeeper).map(\.kind)
        XCTAssertEqual(kinds, [.lineRate])
        // A nil line rate falls back to the (valid) timekeeper default and is fine.
        var inherited = validLine()
        inherited.rate = nil
        XCTAssertTrue(BillingExportValidator.validateForLEDES(lines: [inherited], timekeeper: timekeeper).isEmpty)
    }

    func testMissingActivityCodeAndZeroHoursBlock() {
        let line = BillingLine(clientID: "C", lawFirmMatterID: "F", narrative: "x", hours: 0, workDate: "2026-06-22", taskCode: "L350", activityCode: nil, rate: 450, codeSet: .litigation)
        let kinds = Set(BillingExportValidator.validateForLEDES(lines: [line], timekeeper: timekeeper).map(\.kind))
        XCTAssertTrue(kinds.contains(.zeroHours))
        XCTAssertTrue(kinds.contains(.activityCode))
    }
}
