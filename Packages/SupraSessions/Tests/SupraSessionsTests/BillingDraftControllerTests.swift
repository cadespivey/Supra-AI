import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingDraftControllerTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001", name: "C. Spivey", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
    )

    private let json = """
    {"lineItems":[
      {"matterID":"m-vystar","narrative":"Drafted opposition to motion to compel.","hours":1.3,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]},
      {"matterID":"m-vystar","narrative":"Telephone conference re custodian list.","hours":0.4,"taskCode":"L350","activityCode":"A106","confidence":"medium","sourceEntryIDs":["e2"]}
    ]}
    """

    private func setUp() throws -> (store: SupraStore, dayID: String) {
        let store = try SupraStore.inMemory()
        try store.database.writer.write { db in
            try MatterRecord(id: "m-vystar", name: "Reardon v. VyStar", clientNames: "VyStar", internalMatterID: "12044-0007", clientID: "VYSTAR", clientMatterID: "VS-LIT-2026-031").insert(db)
        }
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Working on @VyStar", mentions: ["m-vystar"])
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
