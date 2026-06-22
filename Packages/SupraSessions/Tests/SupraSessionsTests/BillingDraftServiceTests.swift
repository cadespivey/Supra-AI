import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingDraftServiceTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001", name: "C. Spivey", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
    )

    private func makeStoreWithMatterAndDay() throws -> (store: SupraStore, matterID: String, dayID: String) {
        let store = try SupraStore.inMemory()
        let matterID = "m-vystar"
        try store.database.writer.write { db in
            try MatterRecord(
                id: matterID, name: "Reardon v. VyStar",
                clientNames: "VyStar Credit Union", internalMatterID: "12044-0007",
                clientID: "VYSTAR", clientMatterID: "VS-LIT-2026-031"
            ).insert(db)
        }
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Drafting opposition for @VyStar", mentions: [matterID], tags: ["drafting"])
        return (store, matterID, day.id)
    }

    private func service(_ store: SupraStore, returning json: String) -> BillingDraftService {
        BillingDraftService(store: store) { _, _ in json }
    }

    func testGenerateDraftPersistsLinesAndReconciles() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = """
        {"lineItems":[
          {"matterID":"\(matterID)","narrative":"Drafted opposition to Defendant's motion to compel.","hours":1.3,"workDate":"2026-06-22","taskCode":"L350","activityCode":"A103","confidence":"high","evidence":"stamp gap 09:12-10:30 + 9pp work product","sourceEntryIDs":["e1"]},
          {"matterID":"\(matterID)","narrative":"Telephone conference re custodian list.","hours":0.4,"workDate":"2026-06-22","taskCode":"L350","activityCode":"A106","confidence":"medium","evidence":"wrote ~0.4h"}
        ]}
        """
        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID, sensitivity: 0.6, timekeeper: timekeeper, invoiceDate: "2026-06-22"
        )

        XCTAssertEqual(result.lineCount, 2)
        XCTAssertEqual(result.version, 1)
        XCTAssertEqual(result.reconciliation.billableTotalHours, 1.7, accuracy: 0.001)
        XCTAssertEqual(result.reconciliation.totalAmount, 765, accuracy: 0.001)

        let persisted = try store.billing.lineItems(draftID: result.draftID)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted[0].matterID, matterID)
        XCTAssertEqual(persisted[0].clientID, "VYSTAR")
        XCTAssertEqual(persisted[0].utbmsTaskCode, "L350")
        XCTAssertEqual(try XCTUnwrap(persisted[0].rate), 450, accuracy: 0.001)
        XCTAssertEqual(persisted[0].hours, 1.3, accuracy: 0.001)

        // Reconciliation is persisted on the draft.
        let draft = try XCTUnwrap(store.billing.latestDraft(dayID: dayID))
        let reconJSON = try XCTUnwrap(draft.reconciliationJSON)
        let recon = try JSONDecoder().decode(BillingReconciliation.self, from: Data(reconJSON.utf8))
        XCTAssertEqual(recon.billableTotalHours, 1.7, accuracy: 0.001)
    }

    func testRepairsUnknownMatterAndRoundsHours() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = """
        {"lineItems":[
          {"matterID":"does-not-exist","narrative":"Reviewed filing","hours":null,"confidence":"low"},
          {"matterID":"\(matterID)","narrative":"Researched proportionality","hours":0.17,"taskCode":"L350","activityCode":"A102","confidence":"medium"}
        ]}
        """
        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
        )
        let lines = try store.billing.lineItems(draftID: result.draftID)
        XCTAssertEqual(lines.count, 2)
        // Unknown matter dropped to nil; null hours -> 0.
        XCTAssertNil(lines[0].matterID)
        XCTAssertEqual(lines[0].hours, 0, accuracy: 0.001)
        // Hours rounded to the 0.1h increment.
        XCTAssertEqual(lines[1].hours, 0.2, accuracy: 0.001)
        XCTAssertEqual(lines[1].matterID, matterID)
        // The unassigned line is flagged in reconciliation.
        XCTAssertTrue(result.reconciliation.flags.contains { $0.contains("no matter") })
    }

    func testEmptyDayThrows() async throws {
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        do {
            _ = try await service(store, returning: "{}").generateDraft(
                dayID: day.id, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
            )
            XCTFail("expected emptyDay")
        } catch BillingDraftError.emptyDay {
            // expected
        }
    }

    func testUnparseableThrows() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        do {
            _ = try await service(store, returning: "Sorry, I can't do that.").generateDraft(
                dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
            )
            XCTFail("expected unparseable")
        } catch BillingDraftError.unparseable {
            // expected
        }
    }

    func testResolveMatterByNameAndPureHelpers() throws {
        let matter = MatterRecord(id: "m1", name: "Meridian MSA")
        XCTAssertEqual(BillingDraftService.resolveMatter("m1", in: [matter])?.id, "m1")
        XCTAssertEqual(BillingDraftService.resolveMatter("meridian msa", in: [matter])?.id, "m1")
        XCTAssertNil(BillingDraftService.resolveMatter("unknown", in: [matter]))
        XCTAssertEqual(BillingDraftService.roundToIncrement(0.17, 0.1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(BillingDraftService.roundToIncrement(0.62, 0.25), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BillingDraftService.normalizedDate("2026-06-22"), "2026-06-22")
        XCTAssertNil(BillingDraftService.normalizedDate("June 22"))
    }
}
