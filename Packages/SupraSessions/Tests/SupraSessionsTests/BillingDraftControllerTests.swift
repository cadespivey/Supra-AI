import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingDraftControllerTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001", name: "Harvey Specter", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
    )

    private let json = """
    {"lineItems":[
      {"matterID":"m-mckernon","narrative":"Drafted opposition to motion to compel.","hours":1.3,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]},
      {"matterID":"m-mckernon","narrative":"Telephone conference re custodian list.","hours":0.4,"taskCode":"L350","activityCode":"A106","confidence":"medium","sourceEntryIDs":["e2"]}
    ]}
    """

    private func setUp() throws -> (store: SupraStore, dayID: String) {
        let store = try SupraStore.inMemory()
        try store.database.writer.write { db in
            try MatterRecord(id: "m-mckernon", name: "McKernon Motors v. Liberty Rail", clientNames: "McKernon", internalMatterID: "12044-0007", clientID: "MCKERNON", clientMatterID: "VS-LIT-2026-031").insert(db)
        }
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "e1", dayID: day.id, seq: 1, text: "Drafting for @McKernon",
                mentionsJSON: ScratchPadJSON.encodeStrings(["m-mckernon"])
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "e2", dayID: day.id, seq: 2, text: "Conference for @McKernon",
                mentionsJSON: ScratchPadJSON.encodeStrings(["m-mckernon"])
            ).insert(db)
        }
        return (store, day.id)
    }

    private func controller(_ store: SupraStore) -> BillingDraftController {
        BillingDraftController(store: store, service: BillingDraftService(store: store) { _, _ in self.json }, timekeeper: timekeeper)
    }

    func testGenerateLoadsLinesAndReconciliation() async throws {
        let (store, dayID) = try setUp()
        let controller = controller(store)
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        XCTAssertNil(controller.statusMessage)
        XCTAssertEqual(controller.lines.count, 2)
        XCTAssertEqual(controller.draftVersion, 1)
        XCTAssertEqual(controller.reconciliation?.billableTotalHours ?? 0, 1.7, accuracy: 0.001)
        XCTAssertEqual(controller.reconciliation?.totalAmount ?? 0, 765, accuracy: 0.001)
    }

    func testEditLineRecomputesAndMarksEdited() async throws {
        let (store, dayID) = try setUp()
        let controller = controller(store)
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        let target = try XCTUnwrap(controller.lines.first { $0.sourceEntryIDs == ["e1"] })
        controller.editLine(id: target.id, narrative: "Drafted and revised opposition.", hours: 2.0, taskCode: "L350", activityCode: "A103")
        let edited = try XCTUnwrap(controller.lines.first { $0.id == target.id })
        XCTAssertTrue(edited.userEdited)
        XCTAssertEqual(edited.hours, 2.0, accuracy: 0.001)
        // 2.0 + 0.4 = 2.4
        XCTAssertEqual(controller.reconciliation?.billableTotalHours ?? 0, 2.4, accuracy: 0.001)
    }

    func testRegeneratePreservesUserEdits() async throws {
        let (store, dayID) = try setUp()
        let controller = controller(store)
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        let target = try XCTUnwrap(controller.lines.first { $0.sourceEntryIDs == ["e1"] })
        controller.editLine(id: target.id, narrative: "Drafted opposition — REVISED.", hours: 2.0, taskCode: "L350", activityCode: "A103")

        // Regenerate: a fresh v2 from the same model output (hours 1.3 for e1).
        await controller.generate(sensitivity: 0.6)
        XCTAssertEqual(controller.draftVersion, 2)
        let preserved = try XCTUnwrap(controller.lines.first { $0.sourceEntryIDs == ["e1"] })
        XCTAssertEqual(preserved.hours, 2.0, accuracy: 0.001, "manual edit should survive regeneration")
        XCTAssertTrue(preserved.narrative.contains("REVISED"))
        XCTAssertEqual(controller.reconciliation?.billableTotalHours ?? 0, 2.4, accuracy: 0.001)
    }

    func testPreservationMatchBySourceThenMatter() {
        let edited = BillingLineItemRecord(draftID: "d0", seq: 1, matterID: "m1", narrative: "x", hours: 2.0, workDate: "2026-06-22", userEdited: true, sourceEntryIDsJSON: ScratchPadJSON.encodeStrings(["e1"]))
        let bySource = BillingLineItemRecord(draftID: "d1", seq: 1, matterID: "m1", narrative: "y", hours: 1.0, workDate: "2026-06-22", sourceEntryIDsJSON: ScratchPadJSON.encodeStrings(["e1", "e9"]))
        let byMatter = BillingLineItemRecord(draftID: "d1", seq: 2, matterID: "m1", narrative: "z", hours: 1.0, workDate: "2026-06-22")
        XCTAssertEqual(BillingDraftController.preservationMatch(for: edited, in: [byMatter, bySource])?.id, bySource.id)
        let noSourceEdit = BillingLineItemRecord(draftID: "d0", seq: 1, matterID: "m1", narrative: "x", hours: 2.0, workDate: "2026-06-22", userEdited: true)
        XCTAssertEqual(BillingDraftController.preservationMatch(for: noSourceEdit, in: [byMatter])?.id, byMatter.id)
    }

    func testApplySettingsWiresTimekeeperAndGenerationInputs() async throws {
        let (store, dayID) = try setUp()
        let controller = BillingDraftController(
            store: store,
            service: BillingDraftService(store: store) { _, _ in self.json },
            timekeeper: BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: "")
        )
        controller.applySettings(BillingSettings(
            globalInstructions: "No block billing.",
            sensitivity: 0.3,
            roundingIncrement: 0.25,
            utbmsAutoCoding: false,
            timekeeper: timekeeper
        ))
        XCTAssertEqual(controller.timekeeper.id, "TK-1001")
        XCTAssertEqual(controller.increment, 0.25, accuracy: 0.0001)
        XCTAssertEqual(controller.sensitivity, 0.3, accuracy: 0.0001)
        XCTAssertFalse(controller.utbmsAutoCoding)

        // generate() with no args uses the applied settings. Lines inherit the
        // timekeeper rate (stored nil) and the 0.25h increment rounds 1.3→1.25 and
        // 0.4→0.5, so the total reflects 1.75h × $450 = $787.50.
        controller.bind(dayID: dayID)
        await controller.generate()
        XCTAssertNil(controller.lines.first?.rate, "lines inherit the applied timekeeper rate")
        XCTAssertEqual(controller.reconciliation?.totalAmount ?? 0, 787.5, accuracy: 0.01)
    }

    func testExportIssuesBlockWhenTimekeeperUnconfigured() async throws {
        let (store, dayID) = try setUp()
        // Placeholder timekeeper (rate 0, no id/firm) — the app's default until Settings.
        let controller = BillingDraftController(
            store: store,
            service: BillingDraftService(store: store) { _, _ in self.json },
            timekeeper: BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: "")
        )
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        let kinds = Set(controller.exportIssues().map(\.kind))
        XCTAssertTrue(kinds.contains(.timekeeperRate))
        XCTAssertTrue(kinds.contains(.timekeeperID))
        XCTAssertTrue(kinds.contains(.firmID))

        // Once configured, the litigation lines (with task+activity codes) are clean.
        controller.applySettings(BillingSettings(timekeeper: timekeeper))
        XCTAssertTrue(controller.exportIssues().isEmpty)
    }

    func testDeleteReassignAndExportLifecycle() async throws {
        let (store, dayID) = try setUp()
        let controller = controller(store)
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        XCTAssertEqual(controller.lines.count, 2)

        // Delete one line.
        let first = try XCTUnwrap(controller.lines.first)
        controller.deleteLine(id: first.id)
        XCTAssertEqual(controller.lines.count, 1)

        // Reassign the remaining line off and back onto the matter (with its client id).
        let remaining = try XCTUnwrap(controller.lines.first)
        controller.reassignMatter(lineID: remaining.id, to: nil)
        XCTAssertNil(controller.lines.first?.matterID)
        controller.reassignMatter(lineID: remaining.id, to: "m-mckernon")
        XCTAssertEqual(controller.lines.first?.matterID, "m-mckernon")
        XCTAssertEqual(controller.lines.first?.clientID, "MCKERNON")

        // Export marks the draft exported and records an audit trail.
        controller.markExported(format: .csv)
        let draft = try XCTUnwrap(store.billing.latestDraft(dayID: dayID))
        XCTAssertEqual(draft.status, BillingDraftStatus.exported.rawValue)
        let events = try store.auditEvents.fetchEvents(matterID: "m-mckernon")
        XCTAssertTrue(events.contains { $0.eventType == "export_completed" })
        XCTAssertTrue(events.contains { $0.eventType == "billing_draft_generated" })
    }

    func testExportProducesLEDESAndCSV() async throws {
        let (store, dayID) = try setUp()
        let controller = controller(store)
        controller.bind(dayID: dayID)
        await controller.generate(sensitivity: 0.6)
        XCTAssertTrue(controller.exportString(format: .ledes).hasPrefix("LEDES1998B[]"))
        XCTAssertTrue(controller.exportString(format: .csv).contains("TOTAL"))
        XCTAssertTrue(controller.exportString(format: .clipboard).contains("Client / Matter"))
    }
}
