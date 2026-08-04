import Foundation
import GRDB
import SupraCore
@testable import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraExports
@testable import SupraSessions
import SupraStore
import XCTest

/// T-MTD-01...36: the first supported motion vertical. Every fixture is
/// fictional and every negative assertion checks both the file boundary and the
/// success-audit boundary.
@MainActor
final class MotionToDismissControllerTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }
    private struct DirectorySyncFailure: LocalizedError {
        var errorDescription: String? { "injected directory synchronization failure" }
    }
    private final class DirectorySyncProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let failOnCall: Int?
        private var quarantine: URL?
        private var directories: [URL] = []
        private var destinationStates: [Bool] = []
        private var quarantineStates: [Bool] = []

        init(failOnCall: Int? = nil) {
            self.failOnCall = failOnCall
        }

        func setQuarantine(_ url: URL) {
            lock.withLock { quarantine = url }
        }

        func synchronize(directory: URL, destination: URL) throws {
            let shouldFail = lock.withLock { () -> Bool in
                directories.append(directory.standardizedFileURL)
                destinationStates.append(FileManager.default.fileExists(atPath: destination.path))
                quarantineStates.append(
                    quarantine.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                )
                return failOnCall == directories.count
            }
            if shouldFail { throw DirectorySyncFailure() }
        }

        var synchronizedDirectories: [URL] { lock.withLock { directories } }
        var destinationExistsAtSync: [Bool] { lock.withLock { destinationStates } }
        var quarantineExistsAtSync: [Bool] { lock.withLock { quarantineStates } }
        var callCount: Int { lock.withLock { directories.count } }
    }

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
            XCTAssertEqual(input.selectedAuthorities.map(\.authorityID), [fixture.selectedAuthorityID])
            XCTAssertTrue(input.selectedAuthorities.allSatisfy { isSHA256($0.expectedBindingSHA256) })
        case .noticeAppearance, .customDescription:
            XCTFail("motion request was silently converted to a notice/custom request")
        }
    }

    // T-MTD-05...08 — exact selected-only packet wiring and unsupported-ground block.
    func testTMTD05Through08SelectedOnlyPacketAndUnsupportedGroundBlock() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture)
        )
        let packet = MatterDraftingController.motionPacket(
            snapshot: snapshot,
            groundSpecs: [.failureToStateClaim]
        )
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
            "Selected fact 1",
            "is reproduced for counsel’s analysis under the reviewed pleading standards",
            "JUDGE: Avery Stone",
            "Submitted for review:",
            "/s/ Harvey Specter",
            "CERTIFICATE OF SERVICE",
        ] {
            XCTAssertTrue(xml.contains(required), "motion DOCX XML missing \(required)")
        }
        XCTAssertTrue(xml.contains(fixture.selectedFact.text))
        XCTAssertFalse(xml.contains("does not plead the ultimate facts necessary to state a legally sufficient claim"))
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

    // T-MTD-14 — expected RED for the federal false-positive fixture: malformed
    // citations, federal citations with Florida in the party name, and authorities
    // without reviewed proposition evidence must fail before render/persistence.
    func testTMTD14UnsupportedCitationAndPropositionCreateNoFileOrSuccessAudit() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)

        for authorityID in [
            fixture.invalidCitationAuthorityID,
            fixture.unreviewedAuthorityID,
            fixture.federalFalsePositiveAuthorityID,
        ] {
            var input = fixture.selectedInput
            input.selectedAuthorities = [try authoritySelection(store: fixture.store, authorityID: authorityID)]
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

    // T-MTD-16 — lineage retains exact snapshot, component, receipt, request,
    // and output identities without retaining raw source/profile text.
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

        XCTAssertEqual(lineage.schemaVersion, 3)
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
        XCTAssertEqual(lineage.groundContractIdentity.id, MotionGroundSpec.contractIdentity.id)
        XCTAssertEqual(lineage.groundContractIdentity.version, MotionGroundSpec.contractIdentity.version)
        XCTAssertEqual(lineage.assemblerIdentity.id, MotionToDismiss.assemblerIdentity.id)
        XCTAssertEqual(lineage.assemblerIdentity.version, MotionToDismiss.assemblerIdentity.version)
        XCTAssertEqual(lineage.verifierIdentity.id, DraftVerifier().identity.id)
        XCTAssertEqual(lineage.verifierIdentity.version, DraftVerifier().identity.version)
        XCTAssertEqual(lineage.gateIdentity.id, PreFileGate.identity.id)
        XCTAssertEqual(lineage.gateIdentity.version, PreFileGate.identity.version)
        XCTAssertEqual(lineage.rendererIdentity.id, CompositeRenderer().identity.id)
        XCTAssertEqual(lineage.rendererIdentity.version, CompositeRenderer().identity.version)
        XCTAssertEqual(lineage.verificationStatus, .passed)
        XCTAssertEqual(
            lineage.verificationReceiptScope,
            .motionSelectedSourceReproductionAndStructure
        )
        XCTAssertEqual(lineage.verificationScope.schemaVersion, 1)
        XCTAssertEqual(lineage.verificationScope.kindID, DraftKindID.motionToDismiss.rawValue)
        XCTAssertEqual(lineage.verificationScope.groundKeys, [MotionGroundSpec.failureToStateClaim.key])
        XCTAssertEqual(
            lineage.verificationScope.factPropositionIDs,
            ["motion.fact.\(fixture.selectedFact.chunkID)"]
        )
        XCTAssertEqual(
            lineage.verificationScope.authorityPropositionIDs,
            ["motion.authority.\(fixture.selectedAuthorityID)"]
        )
        XCTAssertEqual(
            lineage.verificationScope.bodyContract,
            MotionDraftVerificationScope.exactSelectedBodyContract
        )
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

    // T-MTD-18 — audit failure removes only the new create-only artifact.
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

    // T-MTD-19 — a filename collision preserves the earlier DOCX and retries.
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

    // T-MTD-20 — a profile/source mutation during async verification is
    // rechecked in the transaction that inserts the success audit.
    func testTMTD20DependencyDriftBeforeAuditRollsBackNewFileAndWritesNoAudit() async throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let changedProfile: AssistantProfile = {
            var profile = completeProfile()
            profile.organization = "Changed After Snapshot LLP"
            return profile
        }()
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

    // T-MTD-21 — jurisdiction never substitutes for a missing filing court.
    func testTMTD21MissingExplicitCourtNeverFallsBackToJurisdiction() async throws {
        let fixture = try makeFixture()
        try await fixture.store.database.writer.write { db in
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

    // T-MTD-22 — assembly uses the exact proposition bytes bound by counsel's review.
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

    // T-MTD-23. Expected RED: compensation hashes the public destination and then
    // unlinks that same path, with no quarantine/interleaving seam. A replacement
    // that arrives after verification can therefore be deleted as if it were ours.
    func testTMTD23CompensationNeverDeletesReplacementInstalledAfterQuarantine() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-interleaving.docx")
        let replacement = Data("concurrent-reviewed-replacement".utf8)
        var checkpointCount = 0
        var observedQuarantine: URL?
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "interleaving" },
            motionCompensationCheckpoint: { publicURL, quarantineURL in
                checkpointCount += 1
                observedQuarantine = quarantineURL
                XCTAssertEqual(publicURL.standardizedFileURL, destination.standardizedFileURL)
                XCTAssertFalse(FileManager.default.fileExists(atPath: publicURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
                try replacement.write(to: publicURL, options: .withoutOverwriting)
            },
            motionAuditCommitter: { _, _ in throw InjectedFailure.stop }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        assertFailure(result)
        XCTAssertEqual(checkpointCount, 1)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(observedQuarantine).path))
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .contains { $0.eventType == "draft_generated" })
    }

    // T-MTD-24. Expected RED: compensation has no atomic, non-overwriting restore
    // path for mismatched content. If another file wins the public path after
    // quarantine, both it and the mismatched quarantined bytes must survive.
    func testTMTD24MismatchedQuarantineNeverOverwritesConcurrentDestination() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-mismatch.docx")
        let mismatched = Data("unexpected-pre-compensation-content".utf8)
        let replacement = Data("concurrent-destination-content".utf8)
        var observedQuarantine: URL?
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "mismatch" },
            motionCompensationCheckpoint: { publicURL, quarantineURL in
                observedQuarantine = quarantineURL
                XCTAssertFalse(FileManager.default.fileExists(atPath: publicURL.path))
                try replacement.write(to: publicURL, options: .withoutOverwriting)
            },
            motionAuditCommitter: { _, _ in
                try mismatched.write(to: destination, options: .atomic)
                throw InjectedFailure.stop
            }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        assertFailure(result)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let quarantine = try XCTUnwrap(observedQuarantine)
        XCTAssertEqual(try Data(contentsOf: quarantine), mismatched)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .contains { $0.eventType == "draft_generated" })
    }

    // T-MTD-25. Expected RED: motion gating currently accepts any explicit court when
    // the broad matter jurisdiction says Florida, and accepts federal/appellate courts
    // whose own names contain Florida. Rule 1.140 motion generation is limited to an
    // explicit Florida state circuit or county trial court.
    func testTMTD25CourtContractAllowsStateTrialCourtsAndBlocksEveryOtherCourt() async throws {
        let fixture = try makeFixture()
        let verifier = InvocationCountingBlockingMotionVerifier()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            pipelineFactory: {
                DraftPipeline(verifier: verifier, renderer: CapturingMotionRenderer())
            }
        )

        for supportedCourt in [
            "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT, IN AND FOR DUVAL COUNTY, FLORIDA",
            "IN THE COUNTY COURT IN AND FOR DUVAL COUNTY, FLORIDA",
        ] {
            try await setCourt(supportedCourt, fixture: fixture)
            XCTAssertTrue(
                controller.motionReadiness(input: fixture.selectedInput, matterID: fixture.matterID).canGenerate,
                "expected supported Florida state trial court: \(supportedCourt)"
            )
        }

        for unsupportedCourt in [
            "UNITED STATES DISTRICT COURT FOR THE MIDDLE DISTRICT OF FLORIDA",
            "FLORIDA FIRST DISTRICT COURT OF APPEAL",
            "IN THE CIRCUIT COURT OF FULTON COUNTY, GEORGIA",
        ] {
            try await setCourt(unsupportedCourt, fixture: fixture)
            let readiness = controller.motionReadiness(
                input: fixture.selectedInput,
                matterID: fixture.matterID
            )
            XCTAssertFalse(readiness.canGenerate, "unsupported filing court passed: \(unsupportedCourt)")
            XCTAssertTrue(
                readiness.blockingReasons.contains {
                    $0.localizedCaseInsensitiveContains("Florida state circuit or county")
                },
                "missing state-trial-court reason for: \(unsupportedCourt)"
            )
            assertFailure(
                await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
            )
        }

        XCTAssertEqual(verifier.verifyCount, 0, "unsupported filing courts reached motion verification")
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-26. Expected RED: controller verification evidence currently uses the
    // mutable document aggregate ID instead of the exact selected revision ID.
    func testTMTD26VerifierFactEvidenceUsesExactRevisionIdentity() async throws {
        let fixture = try makeFixture()
        let verifier = CapturingDelegatingMotionVerifier()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            pipelineFactory: {
                DraftPipeline(verifier: verifier, renderer: CapturingMotionRenderer())
            }
        )

        _ = try successArtifact(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )

        XCTAssertEqual(verifier.factSourceIDs, [fixture.selectedFact.revisionID])
        XCTAssertFalse(verifier.factSourceIDs.contains(fixture.selectedFact.documentID))
    }

    // T-MTD-27. Expected RED: writeNew synchronizes the install, but a later
    // failed-audit compensation unlinks its quarantine without another directory
    // sync before reporting that rollback succeeded.
    func testTMTD27AuditRollbackSynchronizesDirectoryAfterQuarantineRemoval() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-sync-rollback.docx")
        let syncProbe = DirectorySyncProbe()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { directory in
                try syncProbe.synchronize(directory: directory, destination: destination)
            }
        )
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer,
            fileStampProvider: { "sync-rollback" },
            motionCompensationCheckpoint: { _, quarantine in
                syncProbe.setQuarantine(quarantine)
            },
            motionAuditCommitter: { _, _ in throw InjectedFailure.stop }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        assertFailure(result)
        XCTAssertEqual(syncProbe.synchronizedDirectories.count, 2)
        XCTAssertEqual(Set(syncProbe.synchronizedDirectories).count, 1)
        XCTAssertEqual(syncProbe.destinationExistsAtSync, [true, false])
        XCTAssertEqual(syncProbe.quarantineExistsAtSync, [false, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .contains { $0.eventType == "draft_generated" })
    }

    // T-MTD-28. Expected RED: without the compensating directory sync, an audit
    // failure is reported as fully rolled back even when that durability boundary
    // would fail.
    func testTMTD28AuditRollbackDirectorySyncFailureReportsPartialFailure() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-sync-failure.docx")
        let syncProbe = DirectorySyncProbe(failOnCall: 2)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in
                try syncProbe.synchronize(
                    directory: destination.deletingLastPathComponent(),
                    destination: destination
                )
            }
        )
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer,
            fileStampProvider: { "sync-failure" },
            motionAuditCommitter: { _, _ in throw InjectedFailure.stop }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected a partial rollback failure, got \(result)")
        }
        XCTAssertTrue(message.contains("rollback also failed"), message)
        XCTAssertTrue(message.contains("directory synchronization"), message)
        XCTAssertEqual(syncProbe.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .contains { $0.eventType == "draft_generated" })
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

    // T-MTD-29. Expected RED: selecting an authority after displaying reviewed
    // binding A must not silently resolve the same authority ID to replacement
    // binding B at capture/generation time. The typed selection must retain and
    // revalidate the exact binding shown when the user selected the row.
    func testTMTD29DraftRejectsAuthoritySelectionWhenDisplayedReviewBindingChanged() async throws {
        let fixture = try makeFixture()
        let displayedExcerpt = "DISPLAYED_BINDING_A A motion to dismiss for failure to state a claim tests the legal sufficiency of the complaint."
        let replacementExcerpt = "REPLACEMENT_BINDING_B On a motion to dismiss for failure to state a claim, well-pleaded allegations are accepted as true but conclusory allegations are not."
        try fixture.store.authorities.updateOpinionText(
            authorityID: fixture.selectedAuthorityID,
            text: "\(displayedExcerpt)\n\n\(replacementExcerpt)"
        )
        let displayedReview = try fixture.store.authorities.reviewProposition(
            authorityID: fixture.selectedAuthorityID,
            groundKey: .failureToStateClaim,
            excerpt: displayedExcerpt,
            reviewedBy: "synthetic-motion-reviewer",
            reviewedAt: Date(timeIntervalSince1970: 1_785_513_700)
        )

        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        let displayedSource = try XCTUnwrap(
            controller.motionAuthoritySources(matterID: fixture.matterID)
                .first { $0.authorityID == fixture.selectedAuthorityID }
        )
        XCTAssertEqual(displayedSource.snippet, displayedExcerpt)
        XCTAssertEqual(displayedSource.bindingSHA256, displayedReview.bindingSHA256)
        var selectedInput = fixture.selectedInput
        selectedInput.selectedAuthorities = [
            MotionDraftAuthoritySourceSelection(
                authorityID: fixture.selectedAuthorityID,
                expectedBindingSHA256: displayedReview.bindingSHA256
            ),
        ]
        let displayedSnapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture, input: selectedInput)
        )
        XCTAssertEqual(displayedSnapshot.authorities.map(\.bindingSHA256), [displayedReview.bindingSHA256])

        // This input retains the exact binding from the row displayed above.
        let replacementReview = try fixture.store.authorities.reviewProposition(
            authorityID: fixture.selectedAuthorityID,
            groundKey: .failureToStateClaim,
            excerpt: replacementExcerpt,
            reviewedBy: "concurrent-motion-reviewer",
            reviewedAt: Date(timeIntervalSince1970: 1_785_513_800)
        )
        XCTAssertNotEqual(replacementReview.bindingSHA256, displayedReview.bindingSHA256)
        var replacementInput = fixture.selectedInput
        replacementInput.selectedAuthorities = [
            MotionDraftAuthoritySourceSelection(
                authorityID: fixture.selectedAuthorityID,
                expectedBindingSHA256: replacementReview.bindingSHA256
            ),
        ]
        let currentSnapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture, input: replacementInput)
        )
        XCTAssertEqual(currentSnapshot.authorities.map(\.bindingSHA256), [replacementReview.bindingSHA256])

        let readiness = controller.motionReadiness(input: selectedInput, matterID: fixture.matterID)
        XCTAssertFalse(readiness.canGenerate, "a changed reviewed binding must require reload and reselection")
        let result = await controller.draft(.motionToDismiss(selectedInput), matterID: fixture.matterID)
        assertFailure(result)
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-30. Expected RED: source rows currently fetch authority metadata and
    // reviewed evidence in separate database reads. A citation/review update
    // between them can display citation A with binding B, then allow capture to
    // substitute current citation B for the citation counsel actually saw.
    func testTMTD30AuthorityDisplayAndBindingComeFromOneDatabaseSnapshot() throws {
        let fixture = try makeFixture()
        let replacementCitation = "Fictional Marine, LLC v. Harbor Works, Inc., 346 So. 3d 111, 115 (Fla. 1st DCA 2025)"
        let reviewedExcerpt = "SELECTED_AUTHORITY_CANARY A motion to dismiss for failure to state a cause of action tests legal sufficiency, accepts well-pleaded allegations as true, and does not accept conclusory allegations."
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        var didInterleave = false
        controller.motionAuthoritySourceLoadCheckpoint = {
            guard !didInterleave else { return }
            didInterleave = true
            try fixture.store.authorities.updatePreferredCitation(
                authorityID: fixture.selectedAuthorityID,
                preferredCitation: replacementCitation
            )
            _ = try fixture.store.authorities.reviewProposition(
                authorityID: fixture.selectedAuthorityID,
                groundKey: .failureToStateClaim,
                excerpt: reviewedExcerpt,
                reviewedBy: "interleaving-reviewer",
                reviewedAt: Date(timeIntervalSince1970: 1_785_514_000)
            )
        }

        let displayed = try XCTUnwrap(
            controller.motionAuthoritySources(matterID: fixture.matterID)
                .first { $0.authorityID == fixture.selectedAuthorityID }
        )
        let binding = try XCTUnwrap(displayed.bindingSHA256)
        XCTAssertTrue(didInterleave)
        XCTAssertEqual(displayed.citation, replacementCitation)

        var input = fixture.selectedInput
        input.selectedAuthorities = [MotionDraftAuthoritySourceSelection(
            authorityID: displayed.authorityID,
            expectedBindingSHA256: binding
        )]
        let captured = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture, input: input)
        )
        XCTAssertEqual(captured.authorities.first?.citation, displayed.citation)
        XCTAssertEqual(captured.authorities.first?.bindingSHA256, displayed.bindingSHA256)
    }

    // T-MTD-31. Expected RED: the motion input currently retains only a fact
    // chunk ID. If exact excerpt bytes drift under the same chunk/revision IDs,
    // readiness and capture silently substitute B for displayed fact A.
    func testTMTD31DraftRejectsFactSelectionWhenDisplayedExcerptBindingChanged() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        let displayed = try XCTUnwrap(
            controller.motionFactSources(matterID: fixture.matterID)
                .first { $0.chunkID == fixture.selectedFact.chunkID }
        )
        XCTAssertEqual(displayed.text, fixture.selectedFact.text)
        let replacement = "REPLACEMENT_FACT_B The amended pleading now alleges a specific delivery date but no actionable breach."
        let part = DocumentPagePartRecord(
            documentID: fixture.selectedFact.documentID,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: replacement,
            charCount: replacement.count
        )
        let revision = DocumentPartRevisionRecord(
            documentID: fixture.selectedFact.documentID,
            partIndex: 0,
            derivationKey: "motion-drift:\(fixture.selectedFact.documentID)",
            origin: "parser",
            method: "synthetic-drift",
            text: replacement,
            charCount: replacement.count
        )
        let selection = DocumentPartSelectionRecord(
            documentID: fixture.selectedFact.documentID,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "motion-drift:\(fixture.selectedFact.documentID)",
            selectedBy: "policy",
            policyVersion: 1,
            decisionJSON: #"{"rule":"synthetic_drift"}"#
        )
        _ = try fixture.store.documentRevisions.replacePartsAndPersistLineage(
            documentID: fixture.selectedFact.documentID,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.selectedFact.documentID,
            chunks: [DocumentChunkRecord(
                id: fixture.selectedFact.chunkID,
                documentID: fixture.selectedFact.documentID,
                pagePartID: part.id,
                revisionID: revision.id,
                chunkIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                charStart: 0,
                charEnd: replacement.count,
                normalizedText: replacement,
                displayExcerpt: replacement,
                tokenCount: 24
            )]
        )

        let current = try XCTUnwrap(
            controller.motionFactSources(matterID: fixture.matterID)
                .first { $0.chunkID == fixture.selectedFact.chunkID }
        )
        XCTAssertEqual(current.text, replacement)
        XCTAssertFalse(
            controller.motionReadiness(input: fixture.selectedInput, matterID: fixture.matterID).canGenerate,
            "changed fact bytes must require reload and reselection"
        )
        assertFailure(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )
        try assertNoSuccessfulMotionSideEffects(fixture)
    }

    // T-MTD-32. Expected RED: documents, parts, and chunks are currently loaded
    // in separate Store reads. Replacing a part/revision/chunk after the part read
    // yields a mixed-time blocked row instead of one coherent current source row.
    func testTMTD32FactDisplayComesFromOneDatabaseSnapshot() throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        let replacement = "COHERENT_FACT_B The complaint alleges delivery while omitting a breached contractual duty."
        var replacementRevisionID: String?
        var didInterleave = false
        controller.motionFactSourceLoadCheckpoint = {
            guard !didInterleave else { return }
            didInterleave = true
            let documentID = fixture.selectedFact.documentID
            let part = DocumentPagePartRecord(
                documentID: documentID,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: replacement,
                charCount: replacement.count
            )
            let revision = DocumentPartRevisionRecord(
                documentID: documentID,
                partIndex: 0,
                derivationKey: "motion-replacement:\(documentID)",
                origin: "parser",
                method: "synthetic-interleaving",
                text: replacement,
                charCount: replacement.count
            )
            replacementRevisionID = revision.id
            let selection = DocumentPartSelectionRecord(
                documentID: documentID,
                partIndex: 0,
                selectedRevisionID: revision.id,
                selectionKey: "motion-replacement:\(documentID)",
                selectedBy: "policy",
                policyVersion: 1,
                decisionJSON: #"{"rule":"synthetic_interleaving"}"#
            )
            _ = try fixture.store.documentRevisions.replacePartsAndPersistLineage(
                documentID: documentID,
                parts: [part],
                revisions: [revision],
                selections: [selection]
            )
            try fixture.store.documentIndex.replaceChunks(
                documentID: documentID,
                chunks: [DocumentChunkRecord(
                    id: fixture.selectedFact.chunkID,
                    documentID: documentID,
                    pagePartID: part.id,
                    revisionID: revision.id,
                    chunkIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    charStart: 0,
                    charEnd: replacement.count,
                    normalizedText: replacement,
                    displayExcerpt: replacement,
                    tokenCount: 21
                )]
            )
        }

        let displayed = try XCTUnwrap(
            controller.motionFactSources(matterID: fixture.matterID)
                .first { $0.chunkID == fixture.selectedFact.chunkID }
        )

        XCTAssertTrue(didInterleave)
        XCTAssertTrue(displayed.isReady, displayed.blockingReason ?? "unexpected block")
        XCTAssertEqual(displayed.documentRevisionID, replacementRevisionID)
        XCTAssertEqual(displayed.text, replacement)
    }

    // T-MTD-33. Expected RED: the spelled-out Florida rule citation is not
    // recognized in attorney-composed slots, so generation can create a file,
    // artifact intent, and success audit. Readiness must reject both common rule
    // forms in every composed slot without rejecting the same citation inside
    // exact selected evidence.
    func testTMTD33ReadinessRejectsCitationShapedComposedSlotsButAllowsSelectedFactCitations() async throws {
        let mutatedInputs: [(String, (inout MotionToDismissDraftInput) -> Void)] = [
            ("abbreviated responding pleading", { $0.respondingTo = "Complaint under Fla. R. Civ. P. 1.140(b)(6)" }),
            ("abbreviated relief", { $0.reliefSought = "dismissal under Fla. R. Civ. P. 1.140(b)(6)" }),
            ("abbreviated represented party name", { $0.representedPartyName = "Gulf Works, Inc., Fla. R. Civ. P. 1.140(b)(6)" }),
            ("abbreviated represented role", { $0.partyRepresented = "Defendant under Fla. R. Civ. P. 1.140(b)(6)" }),
            ("spelled-out responding pleading", { $0.respondingTo = "Complaint under Florida Rule of Civil Procedure 1.140(b)(6)" }),
            ("spelled-out relief", { $0.reliefSought = "dismissal under Florida Rule of Civil Procedure 1.140(b)(6)" }),
            ("spelled-out represented party name", { $0.representedPartyName = "Gulf Works, Inc., Florida Rule of Civil Procedure 1.140(b)(6)" }),
            ("spelled-out represented role", { $0.partyRepresented = "Defendant under Florida Rule of Civil Procedure 1.140(b)(6)" }),
        ]
        for (label, mutate) in mutatedInputs {
            let fixture = try makeFixture()
            let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
            var input = fixture.selectedInput
            mutate(&input)
            let readiness = controller.motionReadiness(input: input, matterID: fixture.matterID)
            XCTAssertFalse(readiness.canGenerate, "citation-shaped \(label) must fail before generation")
            XCTAssertTrue(
                readiness.blockingReasons.contains { $0.localizedCaseInsensitiveContains("citation") },
                "citation-shaped \(label) needs an actionable readiness reason"
            )
            assertFailure(
                await controller.draft(.motionToDismiss(input), matterID: fixture.matterID)
            )
            try assertNoSuccessfulMotionSideEffects(fixture)
        }

        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        let citedFact = try insertFact(
            store: fixture.store,
            matterID: fixture.matterID,
            name: "Citation-bearing complaint excerpt.txt",
            text: "The complaint invokes Florida Rule of Civil Procedure 1.140(b)(6) and identifies no other breached duty."
        )
        var selectedEvidence = fixture.selectedInput
        selectedEvidence.selectedFacts = [factSelection(citedFact)]
        XCTAssertTrue(
            controller.motionReadiness(input: selectedEvidence, matterID: fixture.matterID).canGenerate,
            "an exact citation-bearing fact excerpt remains eligible selected evidence"
        )
    }

    func testTMTD34InteractiveReadinessUsesCachedSourcesAndFreshPreflightRescans() throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store, storage: fixture.storage)
        var factLoads = 0
        var authorityLoads = 0
        controller.motionFactSourceLoadCheckpoint = { factLoads += 1 }
        controller.motionAuthoritySourceLoadCheckpoint = { authorityLoads += 1 }
        let facts = controller.motionFactSources(matterID: fixture.matterID)
        let authorities = controller.motionAuthoritySources(matterID: fixture.matterID)
        XCTAssertEqual(factLoads, 1)
        XCTAssertEqual(authorityLoads, 1)

        let cached = controller.motionReadiness(
            input: fixture.selectedInput,
            matterID: fixture.matterID,
            factSources: facts,
            authoritySources: authorities
        )
        XCTAssertTrue(cached.canGenerate, cached.blockingReasons.joined(separator: " "))
        XCTAssertEqual(factLoads, 1, "interactive readiness must not rescan fact sources")
        XCTAssertEqual(authorityLoads, 1, "interactive readiness must not rescan authorities")

        let fresh = controller.motionReadiness(input: fixture.selectedInput, matterID: fixture.matterID)
        XCTAssertTrue(fresh.canGenerate, fresh.blockingReasons.joined(separator: " "))
        XCTAssertEqual(factLoads, 2, "generation preflight must refresh fact sources")
        XCTAssertEqual(authorityLoads, 2, "generation preflight must refresh authorities")
    }

    // T-MTD-35: a crash-relaunch path must revalidate the motion snapshot, not
    // merely recognize exact DOCX bytes. A drifted source preserves the public
    // file for recovery and never receives a success audit.
    func testTMTD35RelaunchPreservesExactMotionWhenSavedSourceSnapshotDrifted() async throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "reconcile-source" }
        )
        let generated = try successArtifact(
            await controller.draft(.motionToDismiss(fixture.selectedInput), matterID: fixture.matterID)
        )
        let output = try Data(contentsOf: generated.fileURL)
        let baselineAuditCount = try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .filter { $0.eventType == "draft_generated" }.count
        let snapshot = try fixture.store.draftingSources.captureMotionSnapshot(
            snapshotRequest(for: fixture)
        )
        let intent = try fixture.store.draftArtifacts.prepareMotionIntent(
            snapshot: snapshot,
            fileName: "Motion-to-Dismiss-interrupted.docx",
            output: output,
            auditInput: MotionDraftAuditInput(
                canonicalRequest: Data("canonical interrupted request".utf8),
                canonicalCaption: Data("canonical interrupted caption".utf8),
                canonicalEffectiveStyle: Data("canonical interrupted style".utf8),
                groundContractIdentity: DraftArtifactIntentRepository.motionGroundContractIdentity,
                assemblerIdentity: DraftArtifactIntentRepository.motionAssemblerIdentity,
                verificationReceipt: MotionDraftVerificationReceiptInput(
                    status: .passed,
                    scope: .motionSelectedSourceReproductionAndStructure,
                    supportedPropositionIDs:
                        snapshot.facts.map { "motion.fact.\($0.chunkID)" }
                        + snapshot.authorities.map { "motion.authority.\($0.authorityID)" },
                    verifierIdentity: DraftArtifactIntentRepository.motionVerifierIdentity,
                    gateIdentity: DraftArtifactIntentRepository.motionGateIdentity,
                    rendererIdentity: DraftArtifactIntentRepository.motionRendererIdentity
                )
            ),
            id: "interrupted-motion-source-drift"
        )
        let publicURL = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent(intent.fileName)
        try DurableFileWriter().writeNew(output, to: publicURL) {
            try DocumentExportValidator.validate($0, as: .docx)
        }
        var changedProfile = completeProfile()
        changedProfile.organization = "Changed Before Relaunch LLP"
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: changedProfile)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: publicURL), output)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertEqual(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .filter { $0.eventType == "draft_generated" }.count,
            baselineAuditCount
        )
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // T-MTD-36. A nonthrowing audit checkpoint can still race with another
    // process replacing the public path. Finalization must authenticate the
    // post-checkpoint file and preserve bytes it no longer owns.
    func testTMTD36CheckpointReplacementIsPreservedWithoutCompletedIntentOrAudit() async throws {
        let fixture = try makeFixture()
        let destination = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent("Motion-to-Dismiss-checkpoint-race.docx")
        let replacement = Data("concurrent reviewed motion replacement".utf8)
        var intentID: String?
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileStampProvider: { "checkpoint-race" },
            motionAuditCommitter: { event, _ in
                intentID = String(event.id.dropFirst("draft-artifact-".count))
                try replacement.write(to: destination, options: .atomic)
            }
        )

        let result = await controller.draft(
            .motionToDismiss(fixture.selectedInput),
            matterID: fixture.matterID
        )

        if case .success = result {
            XCTFail("a replaced public motion must not be reported as finalized")
        }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let intent = try XCTUnwrap(
            try fixture.store.draftArtifacts.intent(id: XCTUnwrap(intentID))
        )
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .contains { $0.eventType == "draft_generated" }
        )
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
        let federalFalsePositiveAuthorityID: String
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
        let federalFalsePositiveAuthorityID = try insertAuthority(
            store: store,
            matterID: matter.id,
            sessionID: session.id,
            queryID: query.id,
            caseName: "Florida Supply Corp. v. Example Holdings",
            citation: "Florida Supply Corp. v. Example Holdings, 123 F. Supp. 3d 456 (S.D.N.Y. 2020)",
            supportText: "A federal court discussed the sufficiency of fictional allegations."
        )
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("MotionFiles-\(UUID().uuidString)", isDirectory: true)
        )
        let selectedAuthority = try authoritySelection(
            store: store,
            authorityID: selectedAuthorityID
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
            selectedFacts: [factSelection(selectedFact)],
            selectedAuthorities: [selectedAuthority]
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
            federalFalsePositiveAuthorityID: federalFalsePositiveAuthorityID,
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

    private func factSelection(_ fact: IndexedFact) -> MotionDraftFactSourceSelection {
        MotionDraftFactSourceSelection(
            chunkID: fact.chunkID,
            expectedRevisionID: fact.revisionID,
            expectedExcerptSHA256: DocumentStorage.sha256Hex(of: Data(fact.text.utf8))
        )
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

    private func authoritySelection(
        store: SupraStore,
        authorityID: String
    ) throws -> MotionDraftAuthoritySourceSelection {
        let bindingSHA256: String
        switch try store.authorities.reviewedPropositionState(
            authorityID: authorityID,
            groundKey: .failureToStateClaim
        ) {
        case let .ready(reviewed):
            bindingSHA256 = reviewed.bindingSHA256
        case .notReviewed, .blocked:
            bindingSHA256 = String(repeating: "0", count: 64)
        }
        return MotionDraftAuthoritySourceSelection(
            authorityID: authorityID,
            expectedBindingSHA256: bindingSHA256
        )
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

    private func snapshotRequest(
        for fixture: Fixture,
        input: MotionToDismissDraftInput? = nil
    ) -> MotionDraftSnapshotRequest {
        let input = input ?? fixture.selectedInput
        return MotionDraftSnapshotRequest(
            matterID: fixture.matterID,
            factSelections: input.selectedFacts.map {
                MotionDraftFactSelection(
                    chunkID: $0.chunkID,
                    expectedRevisionID: $0.expectedRevisionID,
                    expectedExcerptSHA256: $0.expectedExcerptSHA256
                )
            },
            authoritySelections: input.selectedAuthorities.map {
                MotionDraftAuthoritySelection(
                    authorityID: $0.authorityID,
                    groundKey: .failureToStateClaim,
                    expectedBindingSHA256: $0.expectedBindingSHA256
                )
            },
            assistantProfileSettingKey: AssistantProfile.profileKey,
            firmStyleProfileSettingKey: FirmStyleProfile.profileKey
        )
    }

    private func setCourt(_ court: String, fixture: Fixture) async throws {
        try await fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET court = ? WHERE id = ?",
                arguments: [court, fixture.matterID]
            )
        }
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
        let intentCount = try fixture.store.database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM draft_artifact_intents WHERE matter_id = ?",
                arguments: [fixture.matterID]
            ) ?? -1
        }
        XCTAssertEqual(
            intentCount,
            0,
            "blocking input created a draft artifact intent",
            file: file,
            line: line
        )
    }
}

private final class CapturingMotionRenderer: Renderer, @unchecked Sendable {
    let identity = CompositeRenderer().identity
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

private final class InvocationCountingBlockingMotionVerifier: Verifier, @unchecked Sendable {
    let identity = DraftComponentIdentity(id: "test.invocation-counting-motion-verifier", version: "1")
    private(set) var verifyCount = 0

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        verifyCount += 1
        return VerificationResult(
            failures: [GateFailure(
                gate: .contract,
                detail: "Unsupported court reached motion verification.",
                repair: .deterministicFix
            )],
            followUps: []
        )
    }
}

private final class CapturingDelegatingMotionVerifier: Verifier, @unchecked Sendable {
    private let delegate = DraftVerifier()
    private(set) var factSourceIDs: [String] = []
    var identity: DraftComponentIdentity { delegate.identity }

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        if case let .motion(_, evidence) = unit {
            factSourceIDs = evidence.facts.map(\.sourceID)
        }
        return await delegate.verify(unit, kind: kind, style: style)
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
