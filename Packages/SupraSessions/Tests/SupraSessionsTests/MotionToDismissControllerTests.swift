import Foundation
import SupraCore
import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraExports
@testable import SupraSessions
import SupraStore
import XCTest

/// T-MTD-01...18: the first supported motion vertical. Every fixture is
/// fictional and every negative assertion checks both the file boundary and the
/// success-audit boundary.
@MainActor
final class MotionToDismissControllerTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    // T-MTD-01...04 — availability and a typed, non-default request contract.
    func testTMTD01Through04MotionAvailabilityAndTypedRequestContract() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        let motion = try XCTUnwrap(controller.availableDraftKinds().first { $0.id == .motionToDismiss })
        XCTAssertTrue(motion.isEnabled)
        XCTAssertNil(motion.disabledReason)

        let request = MatterDraftRequest.motionToDismiss(fixture.selectedInput)
        switch request {
        case let .motionToDismiss(input):
            XCTAssertEqual(input.grounds, ["failure to state a claim"])
            XCTAssertEqual(input.respondingTo, "Plaintiff's First Amended Complaint")
            XCTAssertEqual(input.reliefSought, "dismissal without prejudice and leave to amend")
            XCTAssertEqual(input.selectedFactChunkIDs, [fixture.selectedFact.chunkID])
            XCTAssertEqual(input.selectedAuthorityIDs, [fixture.selectedAuthorityID])
        case .noticeAppearance, .customDescription:
            XCTFail("motion request was silently converted to a notice/custom request")
        }
    }

    // T-MTD-05...08 — exact selected-only packet wiring and unsupported-ground block.
    func testTMTD05Through08SelectedOnlyPacketAndUnsupportedGroundBlock() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        let packet = try controller.motionPacket(input: fixture.selectedInput, matterID: fixture.matterID)
        XCTAssertEqual(packet.facts.map(\.chunkID), [fixture.selectedFact.chunkID])
        XCTAssertEqual(packet.authorities.map(\.authorityID), [fixture.selectedAuthorityID])
        XCTAssertEqual(packet.facts.map(\.text), [fixture.selectedFact.text])
        XCTAssertTrue(packet.authorities[0].snippet.contains("SELECTED_AUTHORITY_CANARY"))
        XCTAssertFalse(packet.facts.map(\.text).joined().contains("UNSELECTED_FACT_CANARY"))
        XCTAssertFalse(packet.authorities.map(\.snippet).joined().contains("UNSELECTED_AUTHORITY_CANARY"))

        var unsupported = fixture.selectedInput
        unsupported.grounds = ["lack of personal jurisdiction"]
        let readiness = controller.motionReadiness(input: unsupported, matterID: fixture.matterID)
        XCTAssertFalse(readiness.canGenerate)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.localizedCaseInsensitiveContains("unsupported ground") })

        let result = await controller.draft(.motionToDismiss(unsupported), matterID: fixture.matterID)
        assertFailure(result)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-09...12 — supported Florida assembly, runMotion, renderer, and firm-style wire proof.
    func testTMTD09Through12SupportedFloridaMotionRendersRequiredDOCXStructure() async throws {
        let fixture = try makeFixture()
        let renderer = CapturingMotionRenderer()
        var style = FirmStyleProfile()
        style.captionCaseNumberLabel = "CASE NUMBER: "
        style.signatureSubmittedLabel = "Submitted for review: "
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            firmStyleProfile: style,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        let result = await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        let artifact = try successArtifact(result)
        XCTAssertEqual(artifact.source, .kind(.motionToDismiss))
        XCTAssertEqual(artifact.format, .docx)
        XCTAssertEqual(renderer.renderCount, 1)
        try DocumentExportValidator.validate(artifact.fileURL, as: .docx)

        let model = try XCTUnwrap(renderer.capturedCourtModel)
        XCTAssertNil(model.caption.division)
        XCTAssertEqual(model.caption.judge, "Avery Stone")
        let renderedStyle = try XCTUnwrap(renderer.capturedStyle)
        let xml = try CourtFLRenderer().documentXML(model, style: renderedStyle)
        for required in [
            "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT",
            "CASE NUMBER: 2026-CA-001847",
            "MOTION TO DISMISS PLAINTIFF'S FIRST AMENDED COMPLAINT",
            "STATEMENT OF FACTS",
            "MEMORANDUM OF LAW",
            "FAILS TO STATE A CLAIM",
            fixture.selectedAuthorityCitation,
            "JUDGE: Avery Stone",
            "Submitted for review:",
            "/s/ Harvey Specter",
            "CERTIFICATE OF SERVICE",
        ] {
            XCTAssertTrue(xml.contains(required), "motion DOCX XML missing \(required)")
        }
        XCTAssertTrue(xml.contains(fixture.selectedFact.text))
        XCTAssertFalse(xml.contains("UNSELECTED_FACT_CANARY"))
        XCTAssertFalse(xml.contains("UNSELECTED_AUTHORITY_CANARY"))
    }

    // T-MTD-13 — any missing required input creates neither file nor success audit.
    func testTMTD13MissingRequiredSlotsCreateNoFileOrSuccessAudit() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        var missing = fixture.selectedInput
        missing.respondingTo = ""
        missing.reliefSought = ""
        missing.recipients = []

        let readiness = controller.motionReadiness(input: missing, matterID: fixture.matterID)
        XCTAssertFalse(readiness.canGenerate)
        XCTAssertGreaterThanOrEqual(readiness.blockingReasons.count, 3)
        let result = await controller.draft(.motionToDismiss(missing), matterID: fixture.matterID)
        assertFailure(result)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-14 — malformed citations and authorities without reviewed proposition
    // evidence both fail before runMotion/render/persistence.
    func testTMTD14UnsupportedCitationAndPropositionCreateNoFileOrSuccessAudit() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        for authorityID in [fixture.invalidCitationAuthorityID, fixture.unreviewedAuthorityID] {
            var input = fixture.selectedInput
            input.selectedAuthorityIDs = [authorityID]
            let readiness = controller.motionReadiness(input: input, matterID: fixture.matterID)
            XCTAssertFalse(readiness.canGenerate)
            let result = await controller.draft(.motionToDismiss(input), matterID: fixture.matterID)
            assertFailure(result)
            try assertNoSuccessfulMotionSideEffects(fixture)
        }
    }

    // T-MTD-15 — a blocking verifier result never reaches renderer, file, or audit.
    func testTMTD15BlockingVerifierCreatesNoFileOrSuccessAudit() async throws {
        let fixture = try makeFixture()
        let renderer = CapturingMotionRenderer()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            pipelineFactory: { DraftPipeline(verifier: BlockingMotionVerifier(), renderer: renderer) }
        )

        let result = await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        assertFailure(result)
        XCTAssertEqual(renderer.renderCount, 0)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-16 — expected RED: lineage uses controller-authored version strings and
    // omits exact snapshot, component, receipt, request, and output identities.
    func testTMTD16AuditLineageRetainsExactInputsRevisionsAndEngineVersions() async throws {
        let fixture = try makeFixture()
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture)
        )
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "lineage" }
        )

        let artifact = try successArtifact(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )
        let event = try XCTUnwrap(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .first { $0.eventType == "draft_generated" }
        )
        let metadata = try XCTUnwrap(event.metadataJSON)
        let lineage = try JSONDecoder().decode(MotionDraftAuditLineage.self, from: Data(metadata.utf8))

        XCTAssertEqual(lineage.schemaVersion, 2)
        XCTAssertEqual(lineage.kindID, DraftKindID.motionToDismiss.rawValue)
        XCTAssertEqual(lineage.sourceSnapshotSHA256, snapshot.fingerprintSHA256)
        XCTAssertEqual(lineage.facts.map(\.chunkID), [fixture.selectedFact.chunkID])
        XCTAssertEqual(lineage.facts.map(\.documentID), [fixture.selectedFact.documentID])
        XCTAssertEqual(lineage.facts.map(\.revisionID), [fixture.selectedFact.revisionID])
        XCTAssertEqual(lineage.facts.map(\.excerptSHA256), snapshot.facts.map(\.excerptSHA256))
        XCTAssertEqual(lineage.authorities.map(\.authorityID), [fixture.selectedAuthorityID])
        XCTAssertEqual(lineage.authorities.map(\.bindingSHA256), snapshot.authorities.map(\.bindingSHA256))
        XCTAssertEqual(lineage.groundKeys, [MotionGroundSpec.failureToStateClaim.key])
        XCTAssertTrue(isSHA256(lineage.requestSHA256))
        XCTAssertTrue(isSHA256(lineage.captionSHA256))
        XCTAssertEqual(lineage.assistantProfileSHA256, snapshot.assistantProfile.valueSHA256)
        XCTAssertTrue(isSHA256(lineage.effectiveStyleSHA256))
        XCTAssertEqual(lineage.groundContractIdentity, MotionGroundSpec.contractIdentity)
        XCTAssertEqual(lineage.assemblerIdentity, MotionToDismiss.assemblerIdentity)
        XCTAssertEqual(lineage.verifierIdentity, DraftVerifier().identity)
        XCTAssertEqual(lineage.gateIdentity, PreFileGate.identity)
        XCTAssertEqual(lineage.rendererIdentity, CompositeRenderer().identity)
        XCTAssertEqual(lineage.verificationStatus, .passed)
        XCTAssertTrue(isSHA256(lineage.verificationReceiptSHA256))
        XCTAssertEqual(lineage.outputFileName, artifact.fileURL.lastPathComponent)
        let output = try Data(contentsOf: artifact.fileURL)
        XCTAssertEqual(lineage.outputSHA256, DocumentStorage.sha256Hex(of: output))
        XCTAssertEqual(lineage.outputByteSize, output.count)
        XCTAssertFalse(lineage.outputFileName.contains("/"))
        for rawSource in [
            fixture.selectedFact.text,
            fixture.selectedAuthorityCitation,
            "SELECTED_AUTHORITY_CANARY",
            "Pearson Specter Litt",
        ] {
            XCTAssertFalse(metadata.contains(rawSource), "audit leaked raw source/profile text")
        }
        let keys = Set(try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
        ).keys)
        XCTAssertFalse(keys.contains("model_repository"))
        XCTAssertFalse(keys.contains("model_revision"))
    }

    // T-MTD-17 — writer failure preserves a reviewed canary and writes no success audit.
    func testTMTD17WriterFailurePreservesCanaryAndWritesNoSuccessAudit() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-fixed.docx")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let canary = Data("reviewed-motion-canary".utf8)
        try canary.write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw InjectedFailure.stop }
        }
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        assertFailure(result)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "draft_generated" })
    }

    // T-MTD-18 — expected RED: the motion audit is not coupled to source
    // revalidation and rollback still assumes replacement semantics.
    func testTMTD18AuditFailureRemovesOnlyNewExclusiveFileAndReportsFailure() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-fixed.docx")
        var observedMetadata = false
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "fixed" },
            motionAuditCommitter: { event, _ in
                observedMetadata = event.eventType == "draft_generated" && event.metadataJSON != nil
                throw InjectedFailure.stop
            }
        )

        let result = await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        assertFailure(result)
        XCTAssertTrue(observedMetadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "draft_generated" })
    }

    // T-MTD-19 — expected RED: second-granularity filenames replace an earlier DOCX.
    func testTMTD19FilenameCollisionPreservesExistingMotionAndCreatesDistinctArtifact() async throws {
        let fixture = try makeFixture()
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("Motion-to-Dismiss-fixed.docx")
        let canary = Data("prior-reviewed-motion".utf8)
        try canary.write(to: existing)
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "fixed" }
        )

        let artifact = try successArtifact(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )

        XCTAssertEqual(try Data(contentsOf: existing), canary)
        XCTAssertEqual(artifact.fileURL.lastPathComponent, "Motion-to-Dismiss-fixed-2.docx")
        XCTAssertNotEqual(artifact.fileURL, existing)
        try DocumentExportValidator.validate(artifact.fileURL, as: .docx)
    }

    // T-MTD-20 — expected RED: a profile/source mutation during async verification is
    // not rechecked in the transaction that inserts the success audit.
    func testTMTD20DependencyDriftBeforeAuditRollsBackNewFileAndWritesNoAudit() async throws {
        let fixture = try makeFixture()
        let store = fixture.store
        var changedProfile = completeProfile()
        changedProfile.organization = "Changed After Snapshot LLP"
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "drift" },
            beforeMotionPersistence: {
                try store.appSettings.setSetting(
                    AssistantProfile.profileKey,
                    value: changedProfile
                )
            }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        assertFailure(result)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-21 — expected RED: jurisdiction currently substitutes for a missing court
    // and prints "Florida" as though it were a filing court.
    func testTMTD21MissingExplicitCourtNeverFallsBackToJurisdiction() async throws {
        let fixture = try makeFixture()
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET court = NULL WHERE id = ?",
                arguments: [fixture.matterID]
            )
        }
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        assertFailure(result)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-22 — expected RED: assembly currently prefers mutable case_summary over
    // the exact proposition bytes bound by counsel's reviewed evidence.
    func testTMTD22AssemblyUsesReviewedExcerptNotMutableCaseSummary() async throws {
        let fixture = try makeFixture()
        try fixture.store.authorities.updateCaseSummary(
            authorityID: fixture.selectedAuthorityID,
            summary: "UNREVIEWED_SUMMARY_CANARY A motion to dismiss for failure to state a claim tests the legal sufficiency of complaint allegations."
        )
        let renderer = CapturingMotionRenderer()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        _ = try successArtifact(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )

        let model = try XCTUnwrap(renderer.capturedCourtModel)
        let bodyText = model.body.map { block -> String in
            switch block {
            case let .paragraph(text), let .numberedAllegation(_, text),
                 let .pointHeading(_, _, text), let .sectionHeading(text):
                return text
            }
        }.joined(separator: "\n")
        XCTAssertTrue(bodyText.contains("SELECTED_AUTHORITY_CANARY"))
        XCTAssertFalse(bodyText.contains("UNREVIEWED_SUMMARY_CANARY"))
    }

    // T-UI-MTD-06 companion — cancellation after the async verifier boundary cannot persist.
    func testTUIMTD06CancellationLeavesNoArtifactOrSuccessAudit() async throws {
        let fixture = try makeFixture()
        let verifierStarted = expectation(description: "verifier started")
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            pipelineFactory: {
                DraftPipeline(
                    verifier: DelayedMotionVerifier(started: verifierStarted),
                    renderer: CapturingMotionRenderer()
                )
            }
        )

        let task = Task {
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        }
        await fulfillment(of: [verifierStarted], timeout: 2)
        task.cancel()
        let result = await task.value
        switch result {
        case .failure(.cancelled): break
        case .failure(let error): XCTFail("expected typed cancellation, got \(error)")
        case .success: XCTFail("cancelled motion unexpectedly produced an artifact")
        }
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // MARK: - Fixtures

    private struct IndexedFact {
        let documentID: String
        let chunkID: String
        let revisionID: String
        let text: String
    }

    private struct Fixture {
        let store: SupraStore
        let matterID: String
        let storage: DocumentStorage
        let selectedFact: IndexedFact
        let unselectedFact: IndexedFact
        let selectedAuthorityID: String
        let unselectedAuthorityID: String
        let invalidCitationAuthorityID: String
        let unreviewedAuthorityID: String
        let selectedAuthorityCitation: String
        let selectedInput: MotionToDismissDraftInput
    }

    private func makeFixture() throws -> Fixture {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "Fictional Harbor Supply, LLC v. Gulf Works, Inc.",
            jurisdiction: "Florida",
            partyPerspective: .defendant,
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "Avery Stone",
            docketNumber: "2026-CA-001847"
        )
        let selectedFact = try insertFact(
            store: store,
            matterID: matter.id,
            name: "First Amended Complaint.txt",
            text: "SELECTED_FACT_CANARY The pleading alleges only that Gulf Works received materials, without alleging a breached contractual duty."
        )
        let unselectedFact = try insertFact(
            store: store,
            matterID: matter.id,
            name: "Unrelated Deposition.txt",
            text: "UNSELECTED_FACT_CANARY This unrelated testimony must never enter the motion packet."
        )

        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Fictional motion authorities",
            issueText: "Failure to state a claim",
            jurisdiction: "Florida",
            status: .approved
        )
        let query = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "Florida motion to dismiss standard",
            queryIndex: 0,
            status: .approved
        )
        let selectedCitation = "Fictional Marine, LLC v. Harbor Works, Inc., 345 So. 3d 100, 104 (Fla. 1st DCA 2025)"
        let selectedAuthorityID = try insertAuthority(
            store: store,
            matterID: matter.id,
            sessionID: session.id,
            queryID: query.id,
            caseName: "Fictional Marine, LLC v. Harbor Works, Inc.",
            citation: selectedCitation,
            supportText: "SELECTED_AUTHORITY_CANARY A motion to dismiss for failure to state a cause of action tests legal sufficiency, accepts well-pleaded allegations as true, and does not accept conclusory allegations."
        )
        let unselectedAuthorityID = try insertAuthority(
            store: store,
            matterID: matter.id,
            sessionID: session.id,
            queryID: query.id,
            caseName: "Fictional Port Holdings, Inc. v. Pier Seven, LLC",
            citation: "Fictional Port Holdings, Inc. v. Pier Seven, LLC, 346 So. 3d 200, 204 (Fla. 2d DCA 2025)",
            supportText: "UNSELECTED_AUTHORITY_CANARY A motion to dismiss tests the legal sufficiency of a complaint and accepts well-pleaded allegations as true."
        )
        let invalidCitationAuthorityID = try insertAuthority(
            store: store,
            matterID: matter.id,
            sessionID: session.id,
            queryID: query.id,
            caseName: "Fictional Invalid Citation Case",
            citation: "not-a-citation",
            supportText: "A motion to dismiss for failure to state a claim tests legal sufficiency of the complaint allegations."
        )
        let unreviewedAuthorityID = try insertAuthority(
            store: store,
            matterID: matter.id,
            sessionID: session.id,
            queryID: query.id,
            caseName: "Fictional Discovery Case",
            citation: "Fictional Discovery Case, 347 So. 3d 300, 304 (Fla. 3d DCA 2025)",
            supportText: "A discovery order may require production of nonprivileged accounting records.",
            reviewGround: false
        )
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("MotionFiles-\(UUID().uuidString)", isDirectory: true)
        )
        let input = MotionToDismissDraftInput(
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Gulf Works, Inc.",
            recipients: sampleRecipients(),
            serviceDate: DateOnly(year: 2026, month: 7, day: 31),
            respondingTo: "Plaintiff's First Amended Complaint",
            grounds: ["failure to state a claim"],
            reliefSought: "dismissal without prejudice and leave to amend",
            selectedFactChunkIDs: [selectedFact.chunkID],
            selectedAuthorityIDs: [selectedAuthorityID]
        )
        return Fixture(
            store: store,
            matterID: matter.id,
            storage: storage,
            selectedFact: selectedFact,
            unselectedFact: unselectedFact,
            selectedAuthorityID: selectedAuthorityID,
            unselectedAuthorityID: unselectedAuthorityID,
            invalidCitationAuthorityID: invalidCitationAuthorityID,
            unreviewedAuthorityID: unreviewedAuthorityID,
            selectedAuthorityCitation: selectedCitation,
            selectedInput: input
        )
    }

    private func insertFact(store: SupraStore, matterID: String, name: String, text: String) throws -> IndexedFact {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: DocumentStorage.sha256Hex(of: Data(name.utf8)),
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(name)"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue,
            extractionMethod: "synthetic@toolchain:motion-tests"
        ))
        let part = DocumentPagePartRecord(
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "motion:\(document.id)",
            origin: "parser",
            method: "synthetic",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "motion:\(document.id)",
            selectedBy: "policy",
            policyVersion: 1,
            decisionJSON: #"{"rule":"synthetic_motion_fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        let chunk = DocumentChunkRecord(
            documentID: document.id,
            pagePartID: part.id,
            revisionID: revision.id,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text,
            displayExcerpt: text,
            tokenCount: 30
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        return IndexedFact(documentID: document.id, chunkID: chunk.id, revisionID: revision.id, text: text)
    }

    private func insertAuthority(
        store: SupraStore,
        matterID: String,
        sessionID: String,
        queryID: String,
        caseName: String,
        citation: String,
        supportText: String,
        reviewGround: Bool = true
    ) throws -> String {
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: queryID, caseName: caseName))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matterID,
            researchSessionID: sessionID,
            researchResultID: result.id,
            caseName: caseName,
            citationJSON: String(decoding: try JSONEncoder().encode([citation]), as: UTF8.self),
            preferredCitation: citation,
            court: "Florida District Court of Appeal",
            courtID: "fladistctapp",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            useStatus: AuthorityUseStatus.userMarkedVerified.rawValue,
            opinionText: supportText,
            caseSummary: supportText
        ))
        if reviewGround {
            let reviewed = try store.authorities.reviewProposition(
                authorityID: authority.id,
                groundKey: .failureToStateClaim,
                excerpt: supportText,
                reviewedBy: "synthetic-motion-reviewer",
                reviewedAt: Date(timeIntervalSince1970: 1_785_513_600)
            )
            XCTAssertEqual(reviewed.excerpt, supportText)
        }
        return authority.id
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func completeProfile() -> AssistantProfile {
        var profile = AssistantProfile()
        profile.fullName = "Harvey Specter"
        profile.organization = "Pearson Specter Litt"
        profile.barNumber = "100847"
        profile.officeStreet = "200 West Forsyth Street"
        profile.officeSuite = "Suite 1400"
        profile.officeCity = "Jacksonville"
        profile.officeState = "Florida"
        profile.officeZip = "32202"
        profile.officePhone = "(904) 555-0142"
        profile.officeFax = "(904) 555-0143"
        profile.primaryEmail = "hspecter@pearsonspecterlitt.example"
        profile.secondaryEmails = ["litdocket@pearsonspecterlitt.example"]
        return profile
    }

    private func sampleParties() -> [PartyLine] {
        [
            PartyLine(name: "FICTIONAL HARBOR SUPPLY, LLC,", designation: "Plaintiff,"),
            PartyLine(name: "GULF WORKS, INC.,", designation: "Defendant."),
        ]
    }

    private func sampleRecipients() -> [ServiceRecipient] {
        [ServiceRecipient(
            name: "Jordan Rowan, Esq.",
            firm: "Rowan & Finch, P.A.",
            address: OfficeBlock(
                street: "1 Independent Drive",
                suite: "Suite 2400",
                city: "Jacksonville",
                state: "Florida",
                zip: "32202",
                phone: "",
                fax: nil
            ),
            emails: ["jrowan@example.test"],
            role: "Counsel for Plaintiff"
        )]
    }

    private func successArtifact(
        _ result: Result<MatterDraftingController.DraftArtifact, MatterDraftingController.DraftError>
    ) throws -> MatterDraftingController.DraftArtifact {
        switch result {
        case let .success(artifact): return artifact
        case let .failure(error):
            XCTFail("expected motion success, got \(error)")
            throw error
        }
    }

    private func snapshotRequest(for fixture: Fixture) -> MotionDraftSnapshotRequest {
        MotionDraftSnapshotRequest(
            matterID: fixture.matterID,
            factChunkIDs: fixture.selectedInput.selectedFactChunkIDs,
            authoritySelections: fixture.selectedInput.selectedAuthorityIDs.map {
                MotionDraftAuthoritySelection(
                    authorityID: $0,
                    groundKey: .failureToStateClaim
                )
            },
            assistantProfileSettingKey: AssistantProfile.profileKey,
            firmStyleProfileSettingKey: FirmStyleProfile.profileKey
        )
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func assertFailure(
        _ result: Result<MatterDraftingController.DraftArtifact, MatterDraftingController.DraftError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .success = result {
            XCTFail("expected motion failure", file: file, line: line)
        }
    }

    private func assertNoSuccessfulMotionSideEffects(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        let entries: [URL]
        if FileManager.default.fileExists(atPath: directory.path) {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } else {
            entries = []
        }
        XCTAssertTrue(entries.isEmpty, "blocking input created a file", file: file, line: line)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .contains { $0.eventType == "draft_generated" },
            "blocking input wrote a success audit",
            file: file,
            line: line
        )
    }
}

private final class CapturingMotionRenderer: Renderer, @unchecked Sendable {
    let identity = DraftComponentIdentity(id: "test.capturing-motion-renderer", version: "1")
    private(set) var renderCount = 0
    private(set) var capturedCourtModel: DocumentModel?
    private(set) var capturedStyle: HouseStyleSheet?

    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        renderCount += 1
        capturedStyle = style
        if case let .court(model) = input { capturedCourtModel = model }
        return try CompositeRenderer().render(input, style: style)
    }
}

private struct BlockingMotionVerifier: Verifier {
    let identity = DraftComponentIdentity(id: "test.blocking-motion-verifier", version: "1")

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        VerificationResult(
            failures: [GateFailure(
                gate: .authorityValidity,
                detail: "Synthetic blocking authority verification result.",
                repair: .stripToPlaceholderAndFlag
            )],
            followUps: []
        )
    }
}

private final class DelayedMotionVerifier: Verifier, @unchecked Sendable {
    let identity = DraftComponentIdentity(id: "test.delayed-motion-verifier", version: "1")
    let started: XCTestExpectation

    init(started: XCTestExpectation) { self.started = started }

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        started.fulfill()
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch is CancellationError {
            // The controller must observe this same task cancellation before its
            // persistence boundary; returning a nominal verifier result exposes it.
        } catch {
            XCTFail("unexpected verifier delay error: \(error)")
        }
        return await DraftVerifier().verify(unit, kind: kind, style: style)
    }
}
