import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

final class ScratchPadAttachmentTests: XCTestCase {

    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let emlSample = """
    From: opposing@example.com
    To: counsel@example.com
    Date: Sat, 21 Jun 2026 09:46:00 -0400
    Subject: Discovery deadline

    Per our call, the ESI custodian list is due Friday.
    """

    func testMakeEvidenceFromEmlIsEmailWithSubject() async throws {
        let url = try tempFile("note.eml", emlSample)
        let evidence = try await ScratchPadAttachmentService().makeEvidence(fileURL: url)
        XCTAssertEqual(evidence.billingKind, .email)
        XCTAssertEqual(evidence.subject, "Discovery deadline")
        XCTAssertGreaterThan(evidence.wordCount, 0)
        XCTAssertEqual(evidence.extractionMethod, "eml")
    }

    func testMakeEvidenceFromTextIsWorkProduct() async throws {
        let url = try tempFile("memo.txt", "Internal memo analyzing the indemnification clause and its carve-outs.")
        let evidence = try await ScratchPadAttachmentService().makeEvidence(fileURL: url)
        XCTAssertEqual(evidence.billingKind, .workProduct)
        XCTAssertGreaterThan(evidence.wordCount, 5)
    }

    func testMsgIsRejectedWithEmlGuidance() async throws {
        let url = try tempFile("email.msg", "binary-ish content")
        do {
            _ = try await ScratchPadAttachmentService().makeEvidence(fileURL: url)
            XCTFail("expected .msg to be rejected")
        } catch let ScratchPadAttachmentError.unsupported(message) {
            XCTAssertTrue(message.lowercased().contains(".eml"), "guidance should mention .eml")
        }
    }

    func testEvidenceRoundTripsThroughJSON() {
        let evidence = AttachmentEvidence(
            kind: BillingEvidenceKind.filing.rawValue,
            fileName: "Order.pdf",
            byteSize: 1234,
            wordCount: 200,
            partCount: 8,
            attachmentCount: 0,
            extractionMethod: "pdf",
            needsOCR: false,
            subject: nil,
            metadataCreatedAt: nil,
            metadataModifiedAt: nil,
            warnings: [],
            textExcerpt: "ORDER granting in part..."
        )
        let json = AttachmentEvidence.encode(evidence)
        XCTAssertNotNil(json)
        XCTAssertEqual(AttachmentEvidence.decode(json), evidence)
    }

    func testInferKindFlagsCourtFilingPDF() {
        let filingText = "UNITED STATES DISTRICT COURT ... Case No. 3:25-cv-00914 ... defendant's motion ... filed 06/21/2026"
        XCTAssertEqual(ScratchPadAttachmentService.inferKind(family: .pdf, text: filingText), .filing)
        XCTAssertEqual(ScratchPadAttachmentService.inferKind(family: .pdf, text: "Draft opposition brief, internal."), .workProduct)
    }

    @MainActor
    func testControllerAddAndRemoveAttachment() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("note.eml", emlSample)
        await controller.addAttachment(fileURL: url)
        XCTAssertNil(controller.lastAttachmentError)
        XCTAssertEqual(controller.attachments.count, 1)
        XCTAssertEqual(controller.attachments.first?.kind, .email)
        controller.removeAttachment(id: controller.attachments[0].id)
        XCTAssertTrue(controller.attachments.isEmpty)
    }

    @MainActor
    func testControllerDefaultsAttachmentMatterToMostMentioned() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let controller = ScratchPadController(store: store)
        controller.load()
        XCTAssertTrue(controller.addEntry("Reviewed motion for @Liberty"))
        let url = try tempFile("note.eml", emlSample)
        await controller.addAttachment(fileURL: url)
        XCTAssertEqual(controller.attachments.first?.matterID, matter.id)
    }

    @MainActor
    func testAddEntryWithAttachmentTiesFileToTheNote() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("opp.txt", "Opposition draft.")
        let ok = await controller.addEntry("Drafted opposition for @Liberty", attachmentURLs: [url])
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.entries.count, 1)
        let entryID = try XCTUnwrap(controller.entries.first?.id)
        // Recorded inline with the note (not as a day-level/unfiled attachment)…
        XCTAssertEqual(controller.attachments(forEntry: entryID).count, 1)
        XCTAssertTrue(controller.unfiledAttachments.isEmpty)
        // …and inheriting the note's own @matter.
        XCTAssertEqual(controller.attachments(forEntry: entryID).first?.matterID, matter.id)
    }

    @MainActor
    func testBareFileDropCreatesAMinimalNote() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("evidence.txt", "Some evidence.")
        let ok = await controller.addEntry("", attachmentURLs: [url])
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.entries.count, 1, "a bare drop still creates a note so the file is tied to one")
        XCTAssertTrue(controller.entries.first?.text.contains("evidence.txt") ?? false)
        let entryID = try XCTUnwrap(controller.entries.first?.id)
        XCTAssertEqual(controller.attachments(forEntry: entryID).count, 1)
    }

    // Expected RED: `addEntry` persisted the generic note before extraction, so
    // an unsupported bare drop left a false "Attached x.msg" timeline entry.
    @MainActor
    func testUnsupportedBareDropDoesNotCreateFalseNote() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("unsupported.msg", "not an Outlook message")

        let ok = await controller.addEntry("", attachmentURLs: [url])

        XCTAssertFalse(ok)
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(controller.attachments.isEmpty)
        XCTAssertNotNil(controller.lastAttachmentError)
    }

    // Expected RED: each successful attachment cleared `lastAttachmentError`, so
    // a bad file followed by a good one hid the partial failure from the user.
    @MainActor
    func testMixedAttachmentBatchPreservesFailuresAndSuccessfulFiles() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let bad = try tempFile("unsupported.msg", "not an Outlook message")
        let good = try tempFile("evidence.txt", "Usable evidence")

        let ok = await controller.addEntry("", attachmentURLs: [bad, good])

        XCTAssertTrue(ok)
        XCTAssertEqual(controller.entries.count, 1)
        XCTAssertEqual(controller.attachments.count, 1)
        XCTAssertEqual(controller.attachments.first?.fileName, "evidence.txt")
        XCTAssertTrue(controller.lastAttachmentError?.contains(".eml") ?? false)
    }

    // Expected RED: delayed promise handlers used the controller's current day,
    // so navigating before fulfillment retargeted the evidence to the wrong date.
    @MainActor
    func testTargetDayRemainsStableAcrossNavigation() async throws {
        let store = try SupraStore.inMemory()
        let calendar = Calendar(identifier: .gregorian)
        let controller = ScratchPadController(
            store: store,
            now: { Date(timeIntervalSince1970: 1_782_876_800) },
            calendar: calendar
        )
        controller.load()
        let targetDay = controller.displayedDate
        controller.selectDate(Date(timeIntervalSince1970: 1_782_963_200))
        let visibleDay = controller.displayedDate
        let file = try tempFile("delayed.txt", "Delayed promise")

        let ok = await controller.addEntry("", attachmentURLs: [file], targetDay: targetDay)

        XCTAssertTrue(ok)
        XCTAssertEqual(controller.displayedDate, visibleDay)
        XCTAssertTrue(controller.entries.isEmpty, "the currently visible day must not receive the delayed drop")
        let persistedTarget = try XCTUnwrap(store.scratchPad.fetchDay(day: targetDay))
        XCTAssertEqual(try store.scratchPad.entries(dayID: persistedTarget.id).count, 1)
        XCTAssertEqual(try store.scratchPad.attachments(dayID: persistedTarget.id).count, 1)
    }

    // Expected RED: a delayed failure assigned the global error banner after the
    // user navigated, making an old day's error appear on the newly visible day.
    @MainActor
    func testDelayedAttachmentErrorRemainsScopedToItsTargetDay() async throws {
        let store = try SupraStore.inMemory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))
        )
        let controller = ScratchPadController(store: store, now: { today }, calendar: calendar)
        controller.load()
        let targetDay = try XCTUnwrap(controller.currentDay)
        controller.selectDate(try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today)))
        let visibleDay = controller.displayedDate
        let bad = try tempFile("delayed-unsupported.msg", "not an Outlook message")

        let ok = await controller.addEntry("", attachmentURLs: [bad], targetDay: targetDay.day)

        XCTAssertFalse(ok)
        XCTAssertEqual(controller.displayedDate, visibleDay)
        XCTAssertNil(controller.lastAttachmentError, "the visible day must not show another day's failure")

        controller.selectDay(id: targetDay.id)
        XCTAssertTrue(
            controller.lastAttachmentError?.contains(".eml") == true,
            "returning to the target day must surface its retained attachment error"
        )
    }

    @MainActor
    func testDeletingEntryDeletesInlineAttachments() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("evidence.txt", "Some evidence.")
        let ok = await controller.addEntry("Attached evidence for review", attachmentURLs: [url])
        XCTAssertTrue(ok)
        let entryID = try XCTUnwrap(controller.entries.first?.id)
        XCTAssertEqual(controller.attachments(forEntry: entryID).count, 1)

        controller.deleteEntry(id: entryID)

        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(controller.attachments.isEmpty)
        let dayID = try XCTUnwrap(controller.currentDay?.id)
        XCTAssertTrue(try store.scratchPad.attachments(dayID: dayID).isEmpty)
    }

    @MainActor
    func testControllerSurfacesMsgError() async throws {
        let store = try SupraStore.inMemory()
        let controller = ScratchPadController(store: store)
        controller.load()
        let url = try tempFile("x.msg", "x")
        await controller.addAttachment(fileURL: url)
        XCTAssertEqual(controller.attachments.count, 0)
        XCTAssertNotNil(controller.lastAttachmentError)
    }
}
