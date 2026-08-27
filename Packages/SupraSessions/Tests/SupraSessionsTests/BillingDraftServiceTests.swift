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
        try store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "e1",
                dayID: day.id,
                seq: 1,
                text: "Drafting opposition for @McKernon",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                tagsJSON: ScratchPadJSON.encodeStrings(["drafting"])
            ).insert(db)
        }
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
          {"matterID":"\(matterID)","narrative":"Telephone conference re custodian list.","hours":0.4,"workDate":"2026-06-22","taskCode":"L350","activityCode":"A106","confidence":"medium","evidence":"wrote ~0.4h","sourceEntryIDs":["e1"]}
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
        XCTAssertEqual(recon.evidenceValidation?.version, 1)
        XCTAssertEqual(recon.evidenceValidation?.candidateMatterIDs, [matterID])
        XCTAssertEqual(recon.evidenceValidation?.includedEntryIDs, ["e1"])
    }

    func testKeepsUnassignedLineAndRoundsHours() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = """
        {"lineItems":[
          {"matterID":null,"narrative":"Reviewed filing","hours":null,"confidence":"low","sourceEntryIDs":["e1"]},
          {"matterID":"\(matterID)","narrative":"Researched proportionality","hours":0.17,"taskCode":"L350","activityCode":"A102","confidence":"medium","sourceEntryIDs":["e1"]}
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
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]}]}"#
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
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]}]}"#
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
            return #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","confidence":"high","sourceEntryIDs":["e1"]}]}"#
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

    func testInvalidModelCodesAreDroppedAndRecordedForReview() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = """
        {"lineItems":[
          {"matterID":"\(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L999","activityCode":"A999","codeNote":"Model rationale.","sourceEntryIDs":["e1"]}
        ]}
        """

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )
        let line = try XCTUnwrap(store.billing.lineItems(draftID: result.draftID).first)

        XCTAssertNil(line.utbmsTaskCode)
        XCTAssertNil(line.utbmsActivityCode)
        let codeNote = try XCTUnwrap(line.codeNote)
        XCTAssertTrue(codeNote.contains("Model rationale."))
        XCTAssertTrue(codeNote.contains("Rejected unsupported task code L999."))
        XCTAssertTrue(codeNote.contains("Rejected unsupported activity code A999."))
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
        XCTAssertTrue(capturedUserPrompt.contains("leave taskCode and activityCode null"))
        XCTAssertFalse(capturedUserPrompt.contains("L350 — Discovery Motions"))
        XCTAssertFalse(capturedUserPrompt.contains("A103 — Draft/revise"))
    }

    func testAutoCodingOffDeterministicallyDropsModelSuppliedCodes() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = """
        {"lineItems":[
          {"matterID":"\(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","sourceEntryIDs":["e1"]}
        ]}
        """

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22",
            autoCoding: false
        )
        let line = try XCTUnwrap(store.billing.lineItems(draftID: result.draftID).first)

        XCTAssertNil(line.utbmsTaskCode)
        XCTAssertNil(line.utbmsActivityCode)
    }

    func testAutoCodingOnSuppliesCanonicalCatalogAndGroundsSelectionInNarrativeAndEvidence() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        var capturedUserPrompt = ""
        _ = try? await BillingDraftService(store: store, generate: { _, user in
            capturedUserPrompt = user
            return "{\"lineItems\":[]}"
        }).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22",
            autoCoding: true
        )

        XCTAssertTrue(capturedUserPrompt.contains("L350 — Discovery Motions"))
        XCTAssertTrue(capturedUserPrompt.contains("A103 — Draft/revise"))
        XCTAssertTrue(capturedUserPrompt.contains("generated narrative and its cited note or attachment evidence"))
        XCTAssertTrue(capturedUserPrompt.contains("If no listed code is a reasonable interpretation"))
        XCTAssertTrue(capturedUserPrompt.contains("codeNote"))
        for item in UTBMSCodes.litigationTask + UTBMSCodes.activity {
            XCTAssertEqual(
                capturedUserPrompt.components(separatedBy: "- \(item.code) — \(item.title)").count,
                2,
                "Expected every canonical code/title to appear exactly once: \(item.code)"
            )
        }
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
          {"matterID":"\(matterID)","narrative":"Drafted opposition.","hours":1.0,"taskCode":"L350","activityCode":"A103","sourceEntryIDs":["e1"]},
          {"matterID":"\(matterID)","narrative":"Reviewed file.","hours":0.5,"taskCode":"L999","activityCode":"ZZZ","sourceEntryIDs":["e1"]}
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

    // MARK: - Adversarial evidence-scope gates (SA-ACR-007)

    func testACRBILL001UnrelatedMatterIdentityAndRulesNeverReachPrompt() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let unrelatedID = try store.matters.createMatter(
            name: "SECRET CANARY MATTER",
            clientNames: "SECRET CANARY CLIENT"
        ).id
        try store.billing.upsertBillingProfile(
            matterID: unrelatedID,
            overrideInstructions: "SECRET CANARY BILLING RULE",
            billingCodeSet: .litigation
        )
        let sourceID = try XCTUnwrap(store.scratchPad.entries(dayID: dayID).first?.id)
        var captured = ""
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted opposition.","hours":1.0,"sourceEntryIDs":["\#(sourceID)"]}]}"#

        _ = try await BillingDraftService(store: store) { _, prompt in
            captured = prompt
            return json
        }.generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        XCTAssertFalse(captured.contains("SECRET CANARY MATTER"))
        XCTAssertFalse(captured.contains("SECRET CANARY CLIENT"))
        XCTAssertFalse(captured.contains("SECRET CANARY BILLING RULE"))
    }

    func testACRBILL002FabricatedSourceEntryRejectsWholePayloadBeforePersistence() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Invented work.","hours":1.0,"sourceEntryIDs":["fabricated-entry"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("fabricated evidence must reject the entire payload")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL003ValidEntryCannotSelectForeignMatter() async throws {
        let (store, _, dayID) = try makeStoreWithMatterAndDay()
        let foreignID = try store.matters.createMatter(name: "Foreign Matter").id
        let sourceID = try XCTUnwrap(store.scratchPad.entries(dayID: dayID).first?.id)
        let json = #"{"lineItems":[{"matterID":"\#(foreignID)","narrative":"Misassigned work.","hours":1.0,"sourceEntryIDs":["\#(sourceID)"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("a source entry may not authorize an unrelated matter")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL004EmptySourceListRejectsWholePayload() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Untraceable work.","hours":1.0,"sourceEntryIDs":[]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("every generated line requires included source evidence")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL005ConflictingEntryAndAttachmentMatterRequiresUnassignedReview() async throws {
        let (store, mentionedMatterID, dayID) = try makeStoreWithMatterAndDay()
        let conflictingMatterID = try store.matters.createMatter(name: "Conflicting Matter").id
        let sourceID = try XCTUnwrap(store.scratchPad.entries(dayID: dayID).first?.id)
        try store.scratchPad.addAttachment(
            dayID: dayID,
            entryID: sourceID,
            matterID: conflictingMatterID,
            evidenceKind: .workProduct
        )
        let json = #"{"lineItems":[{"matterID":"\#(mentionedMatterID)","narrative":"Ambiguous work.","hours":1.0,"sourceEntryIDs":["\#(sourceID)"]}]}"#
        var capturedUserPrompt = ""
        let draftService = BillingDraftService(store: store) { _, userPrompt in
            capturedUserPrompt = userPrompt
            return json
        }

        do {
            _ = try await draftService.generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("conflicting matter evidence must not be assigned automatically")
        } catch {
            XCTAssertFalse(capturedUserPrompt.contains("McKernon Motors v. Liberty Rail"))
            XCTAssertFalse(capturedUserPrompt.contains("Conflicting Matter"))
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL006EntryWithoutMatterEvidenceCannotBorrowAnotherEntryMatter() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let unassigned = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "Reviewed an unlabeled intake item",
            mentions: []
        )
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Reviewed intake item.","hours":0.3,"sourceEntryIDs":["\#(unassigned.id)"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("unassigned evidence may not borrow a candidate from another entry")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL008UniqueClientNameTextAuthorizesMatterWithAuditBasis() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let inferred = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "For McKernon Motors, researched carrier liability defenses for exactly 0.6 hours.",
            mentions: []
        )
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Researched carrier liability defenses.","hours":0.6,"taskCode":"L120","activityCode":"A102","sourceEntryIDs":["\#(inferred.id)"]}]}"#

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        let lines = try store.billing.lineItems(draftID: result.draftID)
        XCTAssertEqual(lines.map(\.matterID), [matterID])
        let draft = try XCTUnwrap(store.billing.latestDraft(dayID: dayID))
        let reconciliationJSON = try XCTUnwrap(draft.reconciliationJSON)
        let reconciliation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reconciliationJSON.utf8)) as? [String: Any])
        let validation = try XCTUnwrap(reconciliation["evidenceValidation"] as? [String: Any])
        let authorizations = try XCTUnwrap(validation["inferredMatterAuthorizations"] as? [[String: Any]])
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertEqual(authorizations[0]["entryID"] as? String, inferred.id)
        XCTAssertEqual(authorizations[0]["matterID"] as? String, matterID)
        XCTAssertEqual(authorizations[0]["basis"] as? String, "explicitClientName")
    }

    func testACRBILL010SharedClientNameRemainsAmbiguous() async throws {
        let (store, firstMatterID, dayID) = try makeStoreWithMatterAndDay()
        let secondMatterID = "shared-client-second-matter"
        try await store.database.writer.write { db in
            try MatterRecord(
                id: secondMatterID,
                name: "McKernon Motors v. Second Defendant",
                clientNames: "McKernon Motors"
            ).insert(db)
        }
        let inferred = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "For McKernon Motors, researched liability defenses for 0.3 hours.",
            mentions: []
        )
        let json = #"{"lineItems":[{"matterID":"\#(firstMatterID)","narrative":"Researched liability defenses.","hours":0.3,"sourceEntryIDs":["\#(inferred.id)"]}]}"#
        var capturedUserPrompt = ""
        let draftService = BillingDraftService(store: store) { _, userPrompt in
            capturedUserPrompt = userPrompt
            return json
        }

        do {
            _ = try await draftService.generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("shared client name must not choose between two matters")
        } catch BillingDraftError.invalidEvidenceScope(let violation) {
            XCTAssertEqual(violation.reason, .ambiguousSourceEntry(inferred.id))
            XCTAssertFalse(capturedUserPrompt.contains("McKernon Motors v. Second Defendant"))
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL014ExactMatterNameUsesMatterNameAuditBasis() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let inferred = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "For McKernon Motors v. Liberty Rail, researched carrier liability for 0.4 hours.",
            mentions: []
        )
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Researched carrier liability.","hours":0.4,"sourceEntryIDs":["\#(inferred.id)"]}]}"#

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        let authorization = try XCTUnwrap(
            result.reconciliation.evidenceValidation?.inferredMatterAuthorizations?.first {
                $0.entryID == inferred.id
            }
        )
        XCTAssertEqual(authorization.matterID, matterID)
        XCTAssertEqual(authorization.basis, "explicitMatterName")
    }

    func testACRBILL011ExplicitDurationsDoNotTriggerTimestampBoundaryGuard() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_921_600)
        let end = start.addingTimeInterval(1_800)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "explicit-start",
                dayID: dayID,
                seq: 2,
                text: "Started reviewing client correspondence about indemnity; spent 0.2 hours.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "explicit-end",
                dayID: dayID,
                seq: 3,
                text: "Completed drafting client update about settlement; spent 0.3 hours.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Reviewed indemnity correspondence.","hours":0.2,"sourceEntryIDs":["explicit-start"]},{"matterID":"\#(matterID)","narrative":"Drafted settlement update.","hours":0.3,"sourceEntryIDs":["explicit-end"]}]}"#

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        XCTAssertEqual(result.lineCount, 2)
    }

    func testACRBILL009SplitBoundaryIntervalRejectsWholePayload() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_918_000)
        let end = start.addingTimeInterval(30 * 60)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "boundary-start",
                dayID: dayID,
                seq: 2,
                text: "Began preparing the project manager for deposition.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                tagsJSON: ScratchPadJSON.encodeStrings([]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "boundary-end",
                dayID: dayID,
                seq: 3,
                text: "Completed deposition preparation session.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                tagsJSON: ScratchPadJSON.encodeStrings([]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Prepared project manager for deposition.","hours":0.5,"sourceEntryIDs":["boundary-start"]},{"matterID":"\#(matterID)","narrative":"Completed deposition preparation session.","hours":0.5,"sourceEntryIDs":["boundary-end"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("one timestamp interval must not persist as two full-duration lines")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL016WhitespacePaddedSourceIDsDoNotBypassSplitBoundaryGuard() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_921_600)
        let end = start.addingTimeInterval(30 * 60)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "padded-boundary-start",
                dayID: dayID,
                seq: 2,
                text: "Began preparing the project manager for deposition.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                tagsJSON: ScratchPadJSON.encodeStrings([]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "padded-boundary-end",
                dayID: dayID,
                seq: 3,
                text: "Completed deposition preparation session.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                tagsJSON: ScratchPadJSON.encodeStrings([]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Prepared project manager for deposition.","hours":0.5,"sourceEntryIDs":["  padded-boundary-start\n"]},{"matterID":"\#(matterID)","narrative":"Completed deposition preparation session.","hours":0.5,"sourceEntryIDs":["\t padded-boundary-end  "]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("source ID whitespace must not hide one fragmented timestamp interval")
        } catch BillingDraftError.invalidEvidenceScope(let violation) {
            XCTAssertEqual(
                violation.reason,
                .fragmentedTimestampInterval(
                    startEntryID: "padded-boundary-start",
                    endEntryID: "padded-boundary-end"
                )
            )
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL012InterveningNoteDoesNotHideSplitBoundaryInterval() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_925_200)
        let end = start.addingTimeInterval(30 * 60)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "nonadjacent-start",
                dayID: dayID,
                seq: 2,
                text: "Began preparing the project manager for deposition.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "intervening-note",
                dayID: dayID,
                seq: 3,
                text: "Received an unrelated scheduling email.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: start.addingTimeInterval(10 * 60),
                updatedAt: start.addingTimeInterval(10 * 60)
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "nonadjacent-end",
                dayID: dayID,
                seq: 4,
                text: "Completed deposition preparation session.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Prepared project manager for deposition.","hours":0.5,"sourceEntryIDs":["nonadjacent-start"]},{"matterID":"\#(matterID)","narrative":"Completed deposition preparation session.","hours":0.5,"sourceEntryIDs":["nonadjacent-end"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("an intervening note must not hide one fragmented timestamp interval")
        } catch BillingDraftError.invalidEvidenceScope(let violation) {
            XCTAssertEqual(
                violation.reason,
                .fragmentedTimestampInterval(
                    startEntryID: "nonadjacent-start",
                    endEntryID: "nonadjacent-end"
                )
            )
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }

    func testACRBILL013WordBasedExplicitDurationsDoNotTriggerBoundaryGuard() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_928_800)
        let end = start.addingTimeInterval(90 * 60)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "word-duration-start",
                dayID: dayID,
                seq: 2,
                text: "Started drafting the settlement update; spent half an hour.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "word-duration-end",
                dayID: dayID,
                seq: 3,
                text: "Finished revising the settlement update after an hour.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Drafted settlement update.","hours":0.5,"sourceEntryIDs":["word-duration-start"]},{"matterID":"\#(matterID)","narrative":"Revised settlement update.","hours":1.0,"sourceEntryIDs":["word-duration-end"]}]}"#

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        XCTAssertEqual(result.lineCount, 2)
    }

    func testACRBILL015GenericClientTokenDoesNotMergeUnrelatedBoundaryNotes() async throws {
        let (store, matterID, dayID) = try makeStoreWithMatterAndDay()
        let start = Date(timeIntervalSince1970: 1_782_932_400)
        let end = start.addingTimeInterval(30 * 60)
        try await store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: "unrelated-boundary-start",
                dayID: dayID,
                seq: 2,
                text: "Started researching indemnity issues for the client.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: start,
                updatedAt: start
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "unrelated-boundary-end",
                dayID: dayID,
                seq: 3,
                text: "Finished drafting settlement update for the client.",
                mentionsJSON: ScratchPadJSON.encodeStrings([matterID]),
                createdAt: end,
                updatedAt: end
            ).insert(db)
        }
        let json = #"{"lineItems":[{"matterID":"\#(matterID)","narrative":"Researched indemnity issues.","hours":0.2,"sourceEntryIDs":["unrelated-boundary-start"]},{"matterID":"\#(matterID)","narrative":"Drafted settlement update.","hours":0.3,"sourceEntryIDs":["unrelated-boundary-end"]}]}"#

        let result = try await service(store, returning: json).generateDraft(
            dayID: dayID,
            sensitivity: 0.5,
            timekeeper: timekeeper,
            invoiceDate: "2026-06-22"
        )

        XCTAssertEqual(result.lineCount, 2)
    }

    func testACRBILL007MixedMatterSourcesCannotBeCollapsedIntoOneMatter() async throws {
        let (store, firstMatterID, dayID) = try makeStoreWithMatterAndDay()
        let secondMatterID = try store.matters.createMatter(name: "Second Matter").id
        let secondSource = try store.scratchPad.addEntry(
            dayID: dayID,
            text: "Reviewed discovery for the second matter",
            mentions: [secondMatterID]
        )
        let json = #"{"lineItems":[{"matterID":"\#(firstMatterID)","narrative":"Combined unrelated work.","hours":1.0,"sourceEntryIDs":["e1","\#(secondSource.id)"]}]}"#

        do {
            _ = try await service(store, returning: json).generateDraft(
                dayID: dayID,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: "2026-06-22"
            )
            XCTFail("mixed-matter evidence must not be collapsed into one matter")
        } catch {
            XCTAssertNil(try store.billing.latestDraft(dayID: dayID))
        }
    }
}
