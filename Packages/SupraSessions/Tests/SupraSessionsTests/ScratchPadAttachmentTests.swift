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
