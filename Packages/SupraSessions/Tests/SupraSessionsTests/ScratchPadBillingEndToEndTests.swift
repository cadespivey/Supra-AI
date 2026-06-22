import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// Milestone 4 Phase 8 end-to-end gate (spec §13): the whole ScratchPad → billing
/// journey driven through the real controllers and services with a deterministic
/// injected model — type → attach → generate → edit → export → lock. Everything
/// here runs on-device and model-free except the single injected generation, so the
/// flow is exercised exactly as the app wires it.
@MainActor
final class ScratchPadBillingEndToEndTests: XCTestCase {

    private func fixedNow() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 22; components.hour = 9
        return Calendar.current.date(from: components)!
    }

    func testTypeAttachGenerateEditExportLock() async throws {
        let store = try SupraStore.inMemory()

        // A litigation matter carrying the LEDES identifiers + a per-matter code set.
        let matterID = "m-vystar"
        try await store.database.writer.write { db in
            try MatterRecord(
                id: matterID, name: "Reardon v. VyStar",
                clientNames: "VyStar Credit Union", internalMatterID: "12044-0007",
                clientID: "VYSTAR", clientMatterID: "VS-LIT-2026-031"
            ).insert(db)
        }
        try store.billing.upsertBillingProfile(
            matterID: matterID, overrideInstructions: "No block billing.", billingCodeSet: .litigation
        )

        // Firm billing settings: a configured timekeeper is what unblocks LEDES export.
        let settings = BillingSettings(
            globalInstructions: "Spell out abbreviations on first use.",
            timekeeper: BillingTimekeeper(
                id: "TK-1001", name: "C. Spivey", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
            )
        )

        // 1) TYPE — the day's contemporaneous notes, tagged to the matter.
        let scratch = ScratchPadController(store: store, now: fixedNow)
        scratch.load()
        let dayID = try XCTUnwrap(scratch.currentDay?.id)
        XCTAssertTrue(scratch.addEntry(
            "Drafted opposition to motion to compel for @VyStar #discovery", explicitMentions: ["VyStar": matterID]
        ))
        XCTAssertTrue(scratch.addEntry(
            "TC w/ client re custodian list @VyStar", explicitMentions: ["VyStar": matterID]
        ))
        XCTAssertEqual(scratch.entries.count, 2)

        // 2) ATTACH — a local work-product file becomes day evidence (no model, no network).
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opposition-\(UUID().uuidString).txt")
        try "DRAFT — Opposition to Defendant's Motion to Compel. Argument: proportionality under Rule 26."
            .write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await scratch.addAttachment(fileURL: fileURL, matterID: matterID, explicitKind: .workProduct)
        XCTAssertNil(scratch.lastAttachmentError)
        XCTAssertEqual(scratch.attachments.count, 1)

        // 3) GENERATE — an injected deterministic model returns two litigation lines.
        let json = """
        {"lineItems":[
          {"matterID":"\(matterID)","narrative":"Drafted opposition to Defendant's motion to compel.","hours":1.3,"workDate":"2026-06-22","taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]},
          {"matterID":"\(matterID)","narrative":"Telephone conference (TC) with client regarding custodian list.","hours":0.4,"workDate":"2026-06-22","taskCode":"L350","activityCode":"A106","confidence":"medium"}
        ]}
        """
        let billing = BillingDraftController(
            store: store, service: BillingDraftService(store: store) { _, _ in json }, timekeeper: settings.timekeeper
        )
        billing.applySettings(settings)
        billing.bind(dayID: dayID)
        await billing.generate()
        XCTAssertNil(billing.statusMessage)
        XCTAssertEqual(billing.lines.count, 2)
        XCTAssertEqual(billing.reconciliation?.billableTotalHours ?? 0, 1.7, accuracy: 0.001)
        XCTAssertEqual(billing.reconciliation?.totalAmount ?? 0, 765, accuracy: 0.001) // 1.7h × $450

        // 4) EDIT — adjust a line; it's flagged user-edited and totals recompute.
        let target = try XCTUnwrap(billing.lines.first)
        billing.editLine(
            id: target.id, narrative: target.narrative + " (revised)", hours: 1.5, taskCode: "L350", activityCode: "A103"
        )
        XCTAssertTrue(try XCTUnwrap(billing.lines.first { $0.id == target.id }).userEdited)
        XCTAssertEqual(billing.reconciliation?.billableTotalHours ?? 0, 1.9, accuracy: 0.001) // 1.5 + 0.4

        // 5) EXPORT — the validator passes (configured timekeeper + litigation codes) and LEDES emits.
        XCTAssertTrue(billing.exportIssues().isEmpty, "a fully-configured draft must be export-ready")
        let ledes = billing.exportString(format: .ledes)
        XCTAssertTrue(ledes.hasPrefix("LEDES1998B[]"))
        XCTAssertTrue(ledes.contains("VYSTAR"))      // CLIENT_ID
        XCTAssertTrue(ledes.contains("12044-0007"))  // LAW_FIRM_MATTER_ID
        XCTAssertTrue(ledes.contains("TK-1001"))     // TIMEKEEPER_ID

        // 6) LOCK — the day finalizes and rejects further notes until reopened (§0.2d).
        scratch.lockCurrentDay()
        XCTAssertTrue(scratch.isCurrentDayLocked)
        XCTAssertFalse(scratch.addEntry("late addition"), "a locked day rejects new notes")
        scratch.reopenCurrentDay()
        XCTAssertFalse(scratch.isCurrentDayLocked)
    }

    /// The export gate blocks a draft whose timekeeper isn't configured (the app's
    /// default state until Settings are filled in), with actionable issues.
    func testExportBlockedUntilTimekeeperConfigured() async throws {
        let store = try SupraStore.inMemory()
        let matterID = "m1"
        try await store.database.writer.write { db in
            try MatterRecord(
                id: matterID, name: "Acme", clientNames: "Acme", internalMatterID: "F-1",
                clientID: "ACME", clientMatterID: "AC-1"
            ).insert(db)
        }
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Work @Acme", mentions: [matterID])

        let json = #"{"lineItems":[{"matterID":"m1","narrative":"Reviewed filings.","hours":0.5,"activityCode":"A104","confidence":"high"}]}"#
        let billing = BillingDraftController(
            store: store,
            service: BillingDraftService(store: store) { _, _ in json },
            timekeeper: BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: "")
        )
        billing.bind(dayID: day.id)
        await billing.generate(sensitivity: 0.5)
        let kinds = Set(billing.exportIssues().map(\.kind))
        XCTAssertTrue(kinds.contains(.timekeeperRate))
        XCTAssertTrue(kinds.contains(.timekeeperID))
        XCTAssertTrue(kinds.contains(.firmID))
    }
}
