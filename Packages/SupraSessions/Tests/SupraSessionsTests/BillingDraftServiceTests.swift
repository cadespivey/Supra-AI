import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingDraftServiceTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001", name: "Harvey Specter", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
    )

    private func makeStoreWithMatterAndDay() throws -> (store: SupraStore, matterID: String, dayID: String) {
        let store = try SupraStore.inMemory()
        let matterID = "m-mckernon"
        try store.database.writer.write { db in
            try MatterRecord(
                id: matterID, name: "McKernon Motors v. Liberty Rail",
                clientNames: "McKernon Motors", internalMatterID: "12044-0007",
                clientID: "MCKERNON", clientMatterID: "VS-LIT-2026-031"
            ).insert(db)
        }
        // Litigation matter → L-codes validate (UTBMS code-set validation).
        try store.billing.upsertBillingProfile(matterID: matterID, overrideInstructions: nil, billingCodeSet: .litigation)
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Drafting opposition for @McKernon", mentions: [matterID], tags: ["drafting"])
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
        XCTAssertEqual(persisted[0].clientID, "MCKERNON")
        XCTAssertEqual(persisted[0].utbmsTaskCode, "L350")
        XCTAssertNil(persisted[0].rate, "lines inherit the configured timekeeper rate (stored nil); the $765 total confirms the effective $450")
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

    func testNoteTaggedEntriesAreExcludedFromBilling() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        // A deliberate non-billable note-to-self alongside the billable entry.
        try store.scratchPad.addEntry(
            dayID: dayID, text: "Remember to call the printer about exhibits #Note",
            mentions: [], tags: [ScratchPadEntryRecord.nonBillableTag]
        )
        var capturedUserPrompt = ""
        let service = BillingDraftService(store: store) { _, user in
            capturedUserPrompt = user
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high"}]}"#
        }
        let result = try await service.generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
        )
        // The #Note text never reaches the billing model.
        XCTAssertFalse(capturedUserPrompt.contains("call the printer"), "#Note entry must be filtered before the prompt")
        XCTAssertTrue(capturedUserPrompt.contains("Drafting opposition"), "the billable entry still reaches the prompt")
        // The exclusion is surfaced on the reconciliation.
        XCTAssertEqual(result.reconciliation.nonBillableExcluded, "1 note tagged #Note excluded from billing.")
    }

    func testNoteTaggedEntryAttachmentsAreExcludedFromBillingPrompt() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let note = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "Do not bill this client-sensitive strategy reminder #Note",
            mentions: [],
            tags: [ScratchPadEntryRecord.nonBillableTag]
        )
        let evidence = AttachmentEvidence(
            kind: BillingEvidenceKind.workProduct.rawValue,
            fileName: "private-strategy.txt",
            byteSize: 20,
            wordCount: 3,
            partCount: 1,
            attachmentCount: 0,
            extractionMethod: "txt",
            needsOCR: false,
            subject: nil,
            metadataCreatedAt: nil,
            metadataModifiedAt: nil,
            warnings: [],
            textExcerpt: "SECRET NONBILLABLE STRATEGY"
        )
        try store.scratchPad.addAttachment(
            dayID: dayID,
            entryID: note.id,
            evidenceKind: .workProduct,
            evidenceSignalsJSON: AttachmentEvidence.encode(evidence)
        )

        var capturedUserPrompt = ""
        let service = BillingDraftService(store: store) { _, user in
            capturedUserPrompt = user
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high"}]}"#
        }
        let result = try await service.generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
        )

        XCTAssertFalse(capturedUserPrompt.contains("client-sensitive strategy"), "#Note text must be filtered")
        XCTAssertFalse(capturedUserPrompt.contains("SECRET NONBILLABLE STRATEGY"), "#Note attachment excerpt must be filtered")
        XCTAssertFalse(capturedUserPrompt.contains("private-strategy.txt"), "#Note attachment metadata must be filtered")
        XCTAssertEqual(
            result.reconciliation.nonBillableExcluded,
            "1 note tagged #Note excluded; 1 attached file tied to excluded notes excluded from billing."
        )
    }

    func testAllNoteDayThrowsEmptyDay() async throws {
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-22")
        try store.scratchPad.addEntry(dayID: day.id, text: "Personal errand #Note", mentions: [], tags: [ScratchPadEntryRecord.nonBillableTag])
        do {
            _ = try await service(store, returning: "{\"lineItems\":[]}").generateDraft(
                dayID: day.id, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
            )
            XCTFail("expected emptyDay when every entry is #Note")
        } catch BillingDraftError.emptyDay {
            // expected — a day of only non-billable notes has nothing to bill
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

    /// Phase-7 gate: the per-matter override AND uploaded client-guideline text both
    /// reach the model's prompt, layered on the global instructions (merged stack).
    func testOverrideAndGuidelineReachThePrompt() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        // Per-matter override + code set.
        try store.billing.upsertBillingProfile(
            matterID: matterID,
            overrideInstructions: "Do not bill intra-office conferences.",
            billingCodeSet: .litigation
        )
        // A client billing-guideline document with extracted text, tagged.
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "g", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/g.pdf")).blob
        let guideline = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, displayName: "McKernon Guidelines.pdf",
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: guideline.id, parts: [
            DocumentPagePartRecord(documentID: guideline.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue,
                                   normalizedText: "Travel time is billed at 50 percent.", charCount: 36)
        ])
        let tag = try store.documentLibrary.createTag(matterID: matterID, name: BillingInstructions.guidelineTagName)
        try store.documentLibrary.assignTag(tagID: tag.id, documentID: guideline.id)

        // Capture the user prompt the service hands to the model.
        var capturedUserPrompt = ""
        let service = BillingDraftService(store: store) { _, user in
            capturedUserPrompt = user
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high"}]}"#
        }
        _ = try await service.generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper,
            invoiceDate: "2026-06-22", globalInstructions: "Firm minimum increment 0.1h."
        )

        XCTAssertTrue(capturedUserPrompt.contains("Firm minimum increment 0.1h."), "global instructions reach the prompt")
        XCTAssertTrue(capturedUserPrompt.contains("Do not bill intra-office conferences."), "per-matter override reaches the prompt")
        XCTAssertTrue(capturedUserPrompt.contains("Travel time is billed at 50 percent."), "client guideline excerpt reaches the prompt")
        XCTAssertTrue(capturedUserPrompt.contains("codeSet=litigation"))
    }

    func testAutoCodingOffDirectiveReachesThePrompt() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        var capturedUserPrompt = ""
        let service = BillingDraftService(store: store) { _, user in
            capturedUserPrompt = user
            return "{\"lineItems\":[]}"
        }
        _ = try? await service.generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22", autoCoding: false
        )
        XCTAssertTrue(capturedUserPrompt.contains("UTBMS coding is OFF"))
    }

    func testAutoTimestampTogglesTimeEvidenceClauseInThePrompt() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        var promptOff = ""
        _ = try? await BillingDraftService(store: store, generate: { _, user in promptOff = user; return "{\"lineItems\":[]}" })
            .generateDraft(dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22", autoTimestamp: false)
        XCTAssertTrue(promptOff.contains("timestamps are NOT reliable duration evidence"), "auto-timestamp off → written-cue degradation reaches the prompt")

        var promptOn = ""
        _ = try? await BillingDraftService(store: store, generate: { _, user in promptOn = user; return "{\"lineItems\":[]}" })
            .generateDraft(dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22", autoTimestamp: true)
        XCTAssertTrue(promptOn.contains("estimate from timestamp gaps"), "auto-timestamp on → timestamp-gap evidence reaches the prompt")
    }

    func testValidatesUTBMSCodesAgainstTheCodeSet() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay() // litigation profile
        let json = """
        {"lineItems":[
          {"matterID":"\(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103"},
          {"matterID":"\(matterID)","narrative":"Reviewed file.","hours":0.5,"taskCode":"L999","activityCode":"ZZZ"}
        ]}
        """
        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
        )
        let lines = try store.billing.lineItems(draftID: result.draftID)
        XCTAssertEqual(lines[0].utbmsTaskCode, "L350")       // valid litigation code kept
        XCTAssertEqual(lines[0].utbmsActivityCode, "A103")   // valid activity kept
        XCTAssertNil(lines[1].utbmsTaskCode, "L999 is not a real L-code → dropped")
        XCTAssertNil(lines[1].utbmsActivityCode, "ZZZ is not a real A-code → dropped")
    }

    func testWorkDateRejectsInvalidAndFutureDates() {
        XCTAssertEqual(BillingDraftService.workDate("2026-06-21", dayDate: "2026-06-22"), "2026-06-21") // backdated ok
        XCTAssertEqual(BillingDraftService.workDate("2026-06-23", dayDate: "2026-06-22"), "2026-06-22") // future → day
        XCTAssertEqual(BillingDraftService.workDate("2026-99-99", dayDate: "2026-06-22"), "2026-06-22") // invalid → day
        XCTAssertNil(BillingDraftService.normalizedDate("2026-02-30"), "Feb 30 is not a real calendar date")
        XCTAssertNil(BillingDraftService.normalizedDate("2026-13-01"))
        XCTAssertEqual(BillingDraftService.normalizedDate("2026-06-22"), "2026-06-22")
    }

    func testLockedDayBlocksGeneration() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        try store.scratchPad.lockDay(id: dayID)
        do {
            _ = try await service(store, returning: "{\"lineItems\":[]}").generateDraft(
                dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22"
            )
            XCTFail("expected dayLocked")
        } catch BillingDraftError.dayLocked {
            // expected
        }
    }

    func testEntryIDsAndAttachmentExcerptReachThePrompt() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let entryID = try XCTUnwrap(store.scratchPad.entries(dayID: dayID).first?.id)
        try store.scratchPad.addAttachment(
            dayID: dayID, matterID: matterID, evidenceKind: .workProduct,
            evidenceSignalsJSON: AttachmentEvidence.encode(AttachmentEvidence(
                kind: "work_product", fileName: "opp.txt", byteSize: 10, wordCount: 5, partCount: 1, attachmentCount: 0,
                extractionMethod: "text", needsOCR: false, subject: nil, metadataCreatedAt: nil, metadataModifiedAt: nil,
                warnings: [], textExcerpt: "Opposition argues proportionality under Rule 26."))
        )
        var captured = ""
        _ = try? await BillingDraftService(store: store, generate: { _, user in captured = user; return "{\"lineItems\":[]}" })
            .generateDraft(dayID: dayID, sensitivity: 0.5, timekeeper: timekeeper, invoiceDate: "2026-06-22")
        XCTAssertTrue(captured.contains("id=\(entryID)"), "entry ids must reach the prompt so sourceEntryIDs can be cited")
        XCTAssertTrue(captured.contains("Opposition argues proportionality under Rule 26."), "attachment excerpt must reach the prompt")
    }

    func testResolveMatterByNameAndPureHelpers() throws {
        let matter = MatterRecord(id: "m1", name: "Hessington MSA")
        XCTAssertEqual(BillingDraftService.resolveMatter("m1", in: [matter])?.id, "m1")
        XCTAssertEqual(BillingDraftService.resolveMatter("hessington msa", in: [matter])?.id, "m1")
        XCTAssertNil(BillingDraftService.resolveMatter("unknown", in: [matter]))
        XCTAssertEqual(BillingDraftService.roundToIncrement(0.17, 0.1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(BillingDraftService.roundToIncrement(0.62, 0.25), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BillingDraftService.normalizedDate("2026-06-22"), "2026-06-22")
        XCTAssertNil(BillingDraftService.normalizedDate("June 22"))
    }
}
