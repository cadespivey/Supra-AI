import Foundation
import GRDB
import SupraCore
import SupraDrafting
import SupraDraftingCore
import SupraExports
import SupraRuntimeInterface
@testable import SupraSessions
@testable import SupraDocuments
import SupraStore
import XCTest

/// End-to-end coverage for the chat document-drafting integration: profile→firm
/// projection, the intent parser, and the controller producing a real downloadable
/// `.docx` — including the firewall guarantees (no invented identity, blocking
/// prompts when data is missing).
final class MatterDraftingControllerTests: XCTestCase {

    private enum PersistenceFailure: Error { case stop }

    private struct DirectorySyncFailure: LocalizedError {
        var errorDescription: String? { "injected directory synchronization failure" }
    }

    private final class DirectorySyncProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let failOnCall: Int?
        private var directories: [URL] = []

        init(failOnCall: Int? = nil) {
            self.failOnCall = failOnCall
        }

        var callCount: Int {
            lock.withLock { directories.count }
        }

        var synchronizedDirectories: [URL] {
            lock.withLock { directories }
        }

        func synchronize(_ directory: URL) throws {
            let call = lock.withLock {
                directories.append(directory.standardizedFileURL)
                return directories.count
            }
            if call == failOnCall {
                throw DirectorySyncFailure()
            }
        }
    }

    // MARK: - Helpers

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    private func makeStorage() -> DocumentStorage {
        DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("DraftFiles-\(UUID().uuidString)"))
    }

    private func completeProfile() -> AssistantProfile {
        var p = AssistantProfile()
        p.fullName = "Harvey Specter"
        p.organization = "Pearson Specter Litt"
        p.barNumber = "100847"
        p.officeStreet = "200 West Forsyth Street"
        p.officeSuite = "Suite 1400"
        p.officeCity = "Jacksonville"
        p.officeState = "Florida"
        p.officeZip = "32202"
        p.officePhone = "(904) 555-0142"
        p.officeFax = "(904) 555-0143"
        p.primaryEmail = "hspecter@pearsonspecterlitt.example"
        p.secondaryEmails = ["litdocket@pearsonspecterlitt.example"]
        return p
    }

    private func sampleParties() -> [PartyLine] {
        [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
         PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")]
    }

    private func sampleRecipients() -> [ServiceRecipient] {
        [ServiceRecipient(name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                          address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                               city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                          emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")]
    }

    // MARK: - Profile → FirmProfile projection

    func testProfileProjectsToFirmProfileSlotsOnly() {
        let firm = MatterDraftingController.firmProfile(from: completeProfile())
        XCTAssertEqual(firm.firmName, "Pearson Specter Litt")
        XCTAssertEqual(firm.signingAttorney, "Harvey Specter")
        XCTAssertEqual(firm.barNumber, "100847")
        XCTAssertEqual(firm.office.suite, "Suite 1400")
        XCTAssertEqual(firm.office.fax, "(904) 555-0143")
        XCTAssertEqual(firm.secondaryEmails, ["litdocket@pearsonspecterlitt.example"])
    }

    func testEmptyOptionalOfficeFieldsBecomeNilNotEmptyString() {
        var p = completeProfile()
        p.officeSuite = ""
        p.officeFax = ""
        let firm = MatterDraftingController.firmProfile(from: p)
        XCTAssertNil(firm.office.suite)
        XCTAssertNil(firm.office.fax)
    }

    // MARK: - Drafting identity readiness

    func testProfileMissingIdentityIsNotDraftReady() {
        var p = AssistantProfile()
        p.fullName = "Harvey Specter"   // only the name
        XCTAssertFalse(p.hasDraftingIdentity)
        XCTAssertTrue(p.missingDraftingIdentityFields.contains("bar number"))
        XCTAssertTrue(p.missingDraftingIdentityFields.contains("office street"))
    }

    func testCompleteProfileIsDraftReady() {
        XCTAssertTrue(completeProfile().hasDraftingIdentity)
        XCTAssertTrue(completeProfile().missingDraftingIdentityFields.isEmpty)
    }

    // MARK: - End-to-end: produces a real downloadable .docx

    @MainActor
    func testDraftNoticeProducesOpenableDocxOnDisk() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "CV-G",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients(),
            serviceDate: DateOnly(year: 2026, month: 6, day: 25)
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .kind(.noticeAppearance))
            XCTAssertEqual(artifact.format, .docx)
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
            XCTAssertEqual(artifact.fileURL.pathExtension, "docx")
            let data = try Data(contentsOf: artifact.fileURL)
            XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "must be a valid OPC zip")
            XCTAssertFalse(artifact.hasBlocking, "a complete notice should raise no blocking follow-ups")
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }

        // Audit event recorded.
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(events.contains { $0.eventType == "draft_generated" })
    }

    // ACR-EXPORT-013. Expected RED: live generic publication creates managed
    // directories with FileManager, which follows a preexisting exports or
    // matter-directory symlink and writes the draft outside managed storage.
    @MainActor
    func testGenericDraftRejectsStaticSymlinkedExportsAndMatterParents() async throws {
        for symlinkExportsDirectory in [true, false] {
            let store = try makeStore()
            let matter = try store.matters.createMatter(name: "Symlink containment matter")
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("DraftSymlinkContainment-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: fixtureRoot) }
            let storage = DocumentStorage(
                root: fixtureRoot.appendingPathComponent("managed", isDirectory: true)
            )
            let external = fixtureRoot.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

            let externalDestination: URL
            if symlinkExportsDirectory {
                try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: storage.exportsDirectory,
                    withDestinationURL: external
                )
                externalDestination = external
                    .appendingPathComponent(matter.id, isDirectory: true)
                    .appendingPathComponent("Symlink-outline-static-parent-link.md")
            } else {
                try FileManager.default.createDirectory(
                    at: storage.exportsDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: storage.exportsDirectory(forMatterID: matter.id),
                    withDestinationURL: external
                )
                externalDestination = external
                    .appendingPathComponent("Symlink-outline-static-parent-link.md")
            }
            let controller = MatterDraftingController(
                store: store,
                storage: storage,
                fileStampProvider: { "static-parent-link" }
            )

            let result = await controller.draftCustomDescription(
                matterID: matter.id,
                input: .init(
                    title: "Symlink outline",
                    description: "Keep this draft inside managed storage."
                )
            )

            if case .success = result {
                XCTFail("a static managed-parent symlink must block generic publication")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: externalDestination.path))
            XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
            let intentStatuses = try await store.database.writer.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT status FROM draft_artifact_intents WHERE matter_id = ? ORDER BY created_at, id",
                    arguments: [matter.id]
                )
            }
            XCTAssertEqual(intentStatuses, [DraftArtifactIntentStatus.aborted.rawValue])
            XCTAssertTrue(try store.draftArtifacts.pendingIntents().isEmpty)
        }
    }

    // MARK: - Multi-kind request layer

    @MainActor
    func testAvailableDraftKindsEnablesWiredNoticeAndMotionWithReasons() throws {
        let store = try makeStore()
        let controller = MatterDraftingController(store: store, storage: makeStorage())
        let kinds = controller.availableDraftKinds()

        XCTAssertEqual(kinds.count, DraftKindID.allCases.count)
        let notice = kinds.first { $0.id == .noticeAppearance }
        XCTAssertEqual(notice?.isEnabled, true)
        XCTAssertNil(notice?.disabledReason)
        let motion = kinds.first { $0.id == .motionToDismiss }
        XCTAssertEqual(motion?.isEnabled, true)
        XCTAssertNil(motion?.disabledReason)
        let letter = kinds.first { $0.id == .letterDemand }
        XCTAssertEqual(letter?.isEnabled, false)
        XCTAssertNotNil(letter?.disabledReason)
    }

    @MainActor
    func testCustomDescriptionWritesLabeledMarkdownArtifact() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail", docketNumber: "2026-CA-001847")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draft(
            .customDescription(CustomDraftDescriptionInput(
                title: "Reply brief outline",
                description: "Outline a reply addressing the statute-of-frauds defense.",
                instructions: "Keep it to three points."
            )),
            matterID: matter.id
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .customDescription)
            XCTAssertEqual(artifact.format, .markdown)
            XCTAssertEqual(artifact.fileURL.pathExtension, "md")
            XCTAssertFalse(artifact.hasBlocking)
            // The artifact is clearly labeled as a description, not a filing, and carries
            // the user's words + matter context (no invented content).
            let body = try String(contentsOf: artifact.fileURL, encoding: .utf8)
            XCTAssertTrue(body.contains("not a court-ready filing"))
            XCTAssertTrue(body.contains("statute-of-frauds defense"))
            XCTAssertTrue(body.contains("2026-CA-001847"))
            XCTAssertTrue(body.contains("Keep it to three points."))
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }
    }

    @MainActor
    func testCustomDescriptionRequiresNonEmptyDescription() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "M")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draft(
            .customDescription(CustomDraftDescriptionInput(title: "Untitled", description: "   ")),
            matterID: matter.id
        )

        guard case .failure(.emptyDescription) = result else {
            return XCTFail("expected .emptyDescription, got \(result)")
        }
    }

    // ACR-EXPORT-009: drafting persistence uses the same atomic writer and does
    // not audit a draft whose validated file was never installed.
    @MainActor
    func testDraftPersistenceFailurePreservesCanaryAndWritesNoAudit() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Atomic matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Atomic-outline-fixed.md")
        let canary = Data("reviewed-canary".utf8)
        try canary.write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw PersistenceFailure.stop }
        }
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Atomic outline", description: "Preserve the old file.")
        )
        guard case .failure = result else { return XCTFail("expected persistence failure") }
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    // ACR-EXPORT-010: a required audit failure is explicitly compensated after
    // a create-only collision allocation, leaving the preexisting draft untouched.
    @MainActor
    func testDraftAuditFailureRestoresCanary() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Atomic matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Atomic-outline-fixed.md")
        let allocatedDestination = directory.appendingPathComponent("Atomic-outline-fixed-2.md")
        let canary = Data("reviewed-canary".utf8)
        try canary.write(to: destination)
        var auditObservedInstalledFile = false
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileStampProvider: { "fixed" },
            auditRecorder: { event in
                auditObservedInstalledFile = event.eventType == "draft_generated"
                    && event.summary.contains("(\(allocatedDestination.lastPathComponent))")
                    && (try? DocumentExportValidator.validate(allocatedDestination, as: .markdown)) != nil
                throw PersistenceFailure.stop
            }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Atomic outline", description: "Install then compensate.")
        )
        guard case .failure = result else { return XCTFail("expected audit failure") }
        XCTAssertTrue(auditObservedInstalledFile)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: allocatedDestination.path))
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-012. The audit callback is a process-boundary seam. If another
    // process replaces the installed path while that callback runs, Store must
    // never finalize from bytes read before the callback or remove the replacement.
    @MainActor
    func testGenericDraftCheckpointReplacementIsPreservedWithoutCompletedIntentOrAudit() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Checkpoint replacement matter")
        let storage = makeStorage()
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Checkpoint-replacement-race.md")
        let replacement = Data("concurrent reviewed replacement".utf8)
        var intentID: String?
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileStampProvider: { "race" },
            auditRecorder: { event in
                intentID = String(event.id.dropFirst("draft-artifact-".count))
                try replacement.write(to: destination, options: .atomic)
            }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(
                title: "Checkpoint replacement",
                description: "Authenticate the final installed bytes."
            )
        )

        if case .success = result {
            XCTFail("a replaced public artifact must not be reported as finalized")
        }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let intent = try XCTUnwrap(try store.draftArtifacts.intent(id: XCTUnwrap(intentID)))
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // Expected RED: interrupted items had only a global count; the matter draft
    // surface exposed neither affected filenames nor an explicit resolution.
    @MainActor
    func testInterruptedDraftRecoveryListsFilenameAndAcknowledgesWithoutDeletingBytes() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Interrupted recovery matter")
        let storage = makeStorage()
        let output = Data("# Preserved interrupted draft\n".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Interrupted-review.md",
            output: output,
            id: "interrupted-review-intent"
        )
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)
        let publicURL = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent(intent.fileName)
        try FileManager.default.createDirectory(
            at: publicURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.write(to: publicURL)
        let controller = MatterDraftingController(store: store, storage: storage)

        controller.refreshDraftReviewState(matterID: matter.id)

        XCTAssertEqual(controller.interruptedDraftRecoveries.map(\.fileName), [intent.fileName])
        XCTAssertEqual(controller.interruptedDraftRecoveries.map(\.fileURL), [publicURL])
        controller.confirmInterruptedDraftArtifactsReviewed(matterID: matter.id)
        XCTAssertTrue(controller.interruptedDraftRecoveries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: publicURL), output)
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue,
            "acknowledgment resolves the review item but retains historical intent state"
        )
        XCTAssertNil(
            try store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // Expected RED: the controller applied the repository's global 500-row
    // limit before filtering by matter and recovery kind. A newer interrupted
    // publication could therefore be announced globally but remain absent from
    // the only matter surface that can reveal or acknowledge it.
    @MainActor
    func testInterruptedDraftRecoveryScopesByMatterBeforeApplyingLimit() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Late interrupted recovery")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Late-interrupted.md",
            output: Data("# Preserved late draft\n".utf8),
            id: "late-interrupted-intent"
        )
        let oldDate = Date(timeIntervalSinceReferenceDate: 1)
        try store.database.writer.write { db in
            for index in 0..<500 {
                try RemediationRecoveryItemRecord(
                    id: String(format: "old-recovery-%04d", index),
                    kind: .legacyStructuredOutput,
                    matterID: nil,
                    relatedTable: "structured_outputs",
                    relatedID: String(format: "old-output-%04d", index),
                    createdAt: oldDate
                ).insert(db)
            }
        }
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        controller.refreshDraftReviewState(matterID: matter.id)

        XCTAssertEqual(controller.interruptedDraftRecoveries.map(\.intentID), [intent.id])
        controller.confirmInterruptedDraftArtifactsReviewed(matterID: matter.id)
        XCTAssertNil(
            try store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // Expected RED: compact-mapping invalid intent rows hid a permanent pending
    // recovery item; revealing the raw tampered filename would be unsafe.
    @MainActor
    func testTamperedInterruptedRecoveryStaysVisibleButCannotRevealAPath() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Corrupt interrupted recovery")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Original.md",
            output: Data("# Original\n".utf8),
            id: "corrupt-visible-recovery"
        )
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET file_name = ? WHERE id = ?",
                arguments: ["../../outside.md", intent.id]
            )
        }
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        controller.refreshDraftReviewState(matterID: matter.id)

        let recovery = try XCTUnwrap(controller.interruptedDraftRecoveries.first)
        XCTAssertNil(recovery.fileName)
        XCTAssertNil(recovery.fileURL)
        XCTAssertEqual(recovery.intentID, intent.id)
    }

    // ACR-EXPORT-009 follow-on. Expected RED: a replacement install whose
    // parent-directory sync fails currently leaves a new, unaudited markdown
    // artifact visible instead of rolling the namespace change back durably.
    @MainActor
    func testCustomDraftDirectorySyncFailureLeavesNoNewArtifactOrAudit() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Directory-sync matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        let destination = directory.appendingPathComponent("Sync-outline-fixed.md")
        let syncProbe = DirectorySyncProbe(failOnCall: 1)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try syncProbe.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Sync outline", description: "Do not publish an unsynchronized draft.")
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected directory-sync persistence failure, got \(result)")
        }
        XCTAssertTrue(message.contains("directory synchronization"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(syncProbe.callCount, 2, "install rollback must also synchronize the parent directory")
        XCTAssertEqual(Set(syncProbe.synchronizedDirectories), [directory.standardizedFileURL])
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-009/011 follow-on. Expected RED: a failed parent-directory
    // sync after a notice install currently replaces a reviewed canary even
    // though draft generation reports failure and records no success audit.
    @MainActor
    func testNoticeDirectorySyncFailurePreservesCanaryAndWritesNoAudit() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "Directory-sync filing",
            court: "IN THE CIRCUIT COURT OF DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Notice-of-Appearance-fixed.docx")
        let canary = Data("previous-reviewed-docx".utf8)
        try canary.write(to: destination)
        let syncProbe = DirectorySyncProbe(failOnCall: 1)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try syncProbe.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected directory-sync persistence failure, got \(result)")
        }
        XCTAssertTrue(message.contains("directory synchronization"), message)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [destination.lastPathComponent]
        )
        XCTAssertEqual(syncProbe.callCount, 2, "failed new install rollback must also synchronize the parent")
        XCTAssertEqual(Set(syncProbe.synchronizedDirectories), [directory.standardizedFileURL])
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-010 follow-on. Expected RED: removing a newly installed
    // generic draft after its required audit fails currently omits the parent
    // directory sync and can report a rollback that is not durable.
    @MainActor
    func testGenericDraftAuditCompensationSynchronizesParentAfterRemoval() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Audit-compensation matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        let destination = directory.appendingPathComponent("Audit-outline-fixed.md")
        let syncProbe = DirectorySyncProbe()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try syncProbe.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" },
            auditRecorder: { _ in throw PersistenceFailure.stop }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Audit outline", description: "Install then compensate durably.")
        )

        guard case .failure = result else { return XCTFail("expected audit failure") }
        XCTAssertEqual(syncProbe.callCount, 2)
        XCTAssertEqual(Set(syncProbe.synchronizedDirectories), [directory.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-010 follow-on. Expected RED: a failed sync after generic audit
    // compensation currently cannot be surfaced as a partial rollback failure
    // because the parent directory is never synchronized after removal.
    @MainActor
    func testGenericDraftAuditCompensationSyncFailureReportsPartialRollback() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Partial-rollback matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        let destination = directory.appendingPathComponent("Partial-rollback-fixed.md")
        let syncProbe = DirectorySyncProbe(failOnCall: 2)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try syncProbe.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" },
            auditRecorder: { _ in throw PersistenceFailure.stop }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Partial rollback", description: "Surface rollback durability failure.")
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected a partial rollback failure, got \(result)")
        }
        XCTAssertTrue(message.contains("rollback also failed"), message)
        XCTAssertTrue(message.contains("directory synchronization"), message)
        XCTAssertEqual(syncProbe.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-010 ownership follow-on. Expected RED: generic audit
    // compensation currently unlinks by pathname, so a concurrent owner that
    // replaces the installed draft during the failed audit loses its file.
    @MainActor
    func testGenericDraftAuditCompensationPreservesConcurrentReplacement() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Concurrent compensation matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        let destination = directory.appendingPathComponent("Concurrent-outline-fixed.md")
        let concurrentCanary = Data("concurrent-owner-canary".utf8)
        var auditObservedInstalledDraft = false
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileStampProvider: { "fixed" },
            auditRecorder: { event in
                auditObservedInstalledDraft = event.eventType == "draft_generated"
                    && (try? DocumentExportValidator.validate(destination, as: .markdown)) != nil
                try FileManager.default.removeItem(at: destination)
                try concurrentCanary.write(to: destination)
                throw PersistenceFailure.stop
            }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "Concurrent outline", description: "Preserve a later path owner.")
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected a partial rollback failure, got \(result)")
        }
        XCTAssertTrue(auditObservedInstalledDraft)
        XCTAssertTrue(message.contains("rollback also failed"), message)
        XCTAssertTrue(message.contains("changed"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try? Data(contentsOf: destination), concurrentCanary)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-010 content-ownership follow-on. Expected RED: inode identity
    // alone is insufficient because another actor can truncate and rewrite the
    // installed inode in place. Compensation must require both install identity
    // and the original complete-file hash before deletion.
    @MainActor
    func testGenericDraftAuditCompensationPreservesInPlaceModifiedInstalledFile() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "In-place compensation matter")
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        let destination = directory.appendingPathComponent("In-place-outline-fixed.md")
        let modifiedCanary = Data("same-inode-foreign-content".utf8)
        var auditObservedInstalledDraft = false
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileStampProvider: { "fixed" },
            auditRecorder: { event in
                auditObservedInstalledDraft = event.eventType == "draft_generated"
                    && (try? DocumentExportValidator.validate(destination, as: .markdown)) != nil
                let handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: modifiedCanary)
                try handle.synchronize()
                try handle.close()
                throw PersistenceFailure.stop
            }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(title: "In-place outline", description: "Preserve modified installed bytes.")
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected a partial rollback failure, got \(result)")
        }
        XCTAssertTrue(auditObservedInstalledDraft)
        XCTAssertTrue(message.contains("rollback also failed"), message)
        XCTAssertTrue(message.contains("changed"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try? Data(contentsOf: destination), modifiedCanary)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-011: rendered DOCX drafts take the same validated temporary
    // path; an install fault cannot truncate a previously reviewed filing.
    @MainActor
    func testDOCXDraftInstallFailurePreservesCanaryAndWritesNoAudit() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "Atomic filing",
            court: "IN THE CIRCUIT COURT OF DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let storage = makeStorage()
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Notice-of-Appearance-fixed.docx")
        let canary = Data("previous-reviewed-docx".utf8)
        try canary.write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw PersistenceFailure.stop }
        }
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )
        guard case .failure = result else { return XCTFail("expected DOCX persistence failure") }
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    // MARK: - Demand Letter (LLM-backed)

    @MainActor
    func testLetterDemandEnabledOnlyWhenRuntimePresent() throws {
        let store = try makeStore()
        // No runtime → letter disabled-with-reason.
        let offline = MatterDraftingController(store: store, storage: makeStorage())
        let letterOffline = offline.availableDraftKinds().first { $0.id == .letterDemand }
        XCTAssertEqual(letterOffline?.isEnabled, false)
        XCTAssertNotNil(letterOffline?.disabledReason)
        // Runtime present → letter enabled.
        let online = MatterDraftingController(store: store, runtimeClient: StubRuntimeClient(), storage: makeStorage())
        let letterOnline = online.availableDraftKinds().first { $0.id == .letterDemand }
        XCTAssertEqual(letterOnline?.isEnabled, true)
        XCTAssertNil(letterOnline?.disabledReason)
    }

    @MainActor
    func testDraftLetterDemandProducesOpenableDocx() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let body = #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]},{"text":"Demand is made for $42,000 by July 15, 2026.","factLabels":["demandAmount","responseDeadline"],"citationLabels":[]},{"text":"Govern yourself accordingly.","factLabels":[],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            // The drafting model is invoked with the fact-scoped prompt.
            XCTAssertTrue(request.prompt.contains("untrustedText"))
            XCTAssertTrue(request.systemPrompt?.contains("SECURITY BOUNDARY") == true)
            return .events([
                .event(request, 0, .token, token: body),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = MatterDraftingController(store: store, runtimeClient: runtime, storage: makeStorage())

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.",
            recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville",
            recipientState: "Florida",
            recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000",
            responseDeadline: "July 15, 2026",
            tone: "firm"
        )
        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: input,
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .kind(.letterDemand))
            XCTAssertEqual(artifact.format, .docx)
            XCTAssertEqual(artifact.fileURL.pathExtension, "docx")
            let data = try Data(contentsOf: artifact.fileURL)
            XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "must be a valid OPC zip")
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testLetterBodyScanBlocksCitationsAndPlaceholdersWithoutSideEffects() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        // A non-compliant model reply: it cites a case and leaves a [fact?] placeholder.
        let body = "As held in Smith v. Jones, your client must pay.\n\nThe balance of [fact?] remains outstanding."
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: body), .event(request, 1, .generationCompleted)])
        })
        let storage = makeStorage()
        let renderer = StyleSpyRenderer()
        let controller = MatterDraftingController(
            store: store,
            runtimeClient: runtime,
            storage: storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(recipientName: "X", recipientStreet: "1 Main", recipientCity: "Jax",
                                    recipientState: "FL", recipientZip: "32202", claimSummary: "Unpaid balance"),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        guard case .failure(.verificationBlocked) = result else {
            return XCTFail("unsafe prose must return a typed block, not a file with review notes")
        }
        XCTAssertEqual(renderer.renderCount, 0, "unsafe prose reached the renderer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.exportsDirectory(forMatterID: matter.id).path))
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testStructuredUnsupportedLetterHasNoRenderFileOrAuditSideEffects() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        let response = #"{"paragraphs":[{"text":"The debtor committed fraud.","factLabels":["claim"],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: response), .event(request, 1, .generationCompleted)])
        })
        let storage = makeStorage()
        let renderer = StyleSpyRenderer()
        let controller = MatterDraftingController(
            store: store,
            runtimeClient: runtime,
            storage: storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(
                recipientName: "X", recipientStreet: "1 Main", recipientCity: "Jax",
                recipientState: "FL", recipientZip: "32202", claimSummary: "The invoice remains unpaid."
            ),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        guard case .failure(.verificationBlocked) = result else {
            return XCTFail("unsupported structured output must return a typed block")
        }
        XCTAssertEqual(renderer.renderCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.exportsDirectory(forMatterID: matter.id).path))
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testDraftLetterDemandRequiresClaim() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "M")
        let controller = MatterDraftingController(store: store, runtimeClient: StubRuntimeClient(), storage: makeStorage())

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(recipientName: "X", claimSummary: "   "),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )
        guard case .failure = result else {
            return XCTFail("expected failure when the claim is empty")
        }
    }

    // T-DRAFT-CANCEL-01. Expected RED: if cancellation arrives after the notice
    // renderer returns, the controller does not inspect it before persistence and
    // creates both a file and success audit.
    @MainActor
    func testCancelledNoticeLeavesNoArtifactOrSuccessAudit() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let storage = makeStorage()
        let renderer = CancellingDraftRenderer()
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            pipelineFactory: {
                DraftPipeline(verifier: DraftVerifier(), renderer: renderer)
            }
        )

        let task = Task {
            await controller.draftNoticeOfAppearance(
                matterID: matter.id,
                parties: sampleParties(),
                partyRepresented: "Defendant",
                representedPartyName: "Liberty Rail, LLC",
                recipients: sampleRecipients()
            )
        }
        let result = await task.value

        guard case .failure(.cancelled) = result else {
            return XCTFail("cancelled notice must return the typed cancellation result, got \(result)")
        }
        XCTAssertEqual(renderer.renderCount, 1, "fixture must cancel only after producing valid render bytes")
        let exports = storage.exportsDirectory(forMatterID: matter.id)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty) ?? true)
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id)
            .contains { $0.eventType == "draft_generated" })
    }

    // T-DRAFT-CANCEL-02. Expected RED: the letter controller has the same unchecked
    // renderer-to-persistence boundary and can create a file and success audit after
    // cancellation.
    @MainActor
    func testCancelledLetterGenerationLeavesNoArtifactOrSuccessAudit() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let body = #"{"paragraphs":[{"text":"The invoice remains unpaid under the supply agreement.","factLabels":["claim"],"citationLabels":[]}] }"#
        let runtime = StubRuntimeClient(outcome: { request in
            return .events([
                .event(request, 0, .token, token: body),
                .event(request, 1, .generationCompleted)
            ])
        })
        let storage = makeStorage()
        let renderer = CancellingDraftRenderer()
        let controller = MatterDraftingController(
            store: store,
            runtimeClient: runtime,
            storage: storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )
        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.",
            recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville",
            recipientState: "Florida",
            recipientZip: "32202",
            claimSummary: "The invoice remains unpaid under the supply agreement."
        )

        let task = Task {
            await controller.draftLetterDemand(
                matterID: matter.id,
                input: input,
                modelID: ModelID(),
                route: ModelRouter().route(for: .drafting)
            )
        }
        let result = await task.value

        guard case .failure(.cancelled) = result else {
            return XCTFail("cancelled letter must return the typed cancellation result, got \(result)")
        }
        XCTAssertEqual(renderer.renderCount, 1, "fixture must cancel only after producing valid render bytes")
        let exports = storage.exportsDirectory(forMatterID: matter.id)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty) ?? true)
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id)
            .contains { $0.eventType == "draft_generated" })
    }

    // MARK: - Firewall: never invents identity

    @MainActor
    func testIncompleteFirmProfileBlocksWithPreciseFieldsNotInvention() async throws {
        let store = try makeStore()
        var partial = AssistantProfile()
        partial.fullName = "Harvey Specter"
        partial.organization = "Pearson Specter Litt"
        // bar number + office deliberately missing
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: partial)
        let matter = try store.matters.createMatter(name: "M", docketNumber: "2026-CA-001847")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .incompleteFirmProfile(missing) = error else { return XCTFail("expected incompleteFirmProfile, got \(error)") }
        XCTAssertTrue(missing.contains("bar number"))
        // No file was written.
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertFalse(events.contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testMissingCaseNumberBlocksRatherThanGuessing() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "No docket matter")  // no docketNumber
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case .missingCaptionField = error else { return XCTFail("expected missingCaptionField, got \(error)") }
    }

    @MainActor
    func testEmptyServiceRecipientsBlockBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: []
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("service recipients"))
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertFalse(events.contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testIncompleteCaptionBlocksBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "")],
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("complete caption parties"))
        XCTAssertTrue(missing.contains("caption party 1 designation"))
    }

    @MainActor
    func testInvalidRecipientEmailBlocksBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        var recipients = sampleRecipients()
        recipients[0].emails = ["not-an-email"]
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: recipients
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("valid service recipient 1 service e-mail"))
    }

    @MainActor
    func testNonFloridaNoticeDraftingIsBlocked() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "Texas Matter",
            jurisdiction: "Texas",
            court: "IN THE DISTRICT COURT OF TRAVIS COUNTY, TEXAS",
            docketNumber: "2026-CI-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case .unsupportedJurisdiction = error else {
            return XCTFail("expected unsupportedJurisdiction, got \(error)")
        }
    }

    // MARK: - Intent parser

    func testParserRecognizesExplicitSlashCommand() {
        let match = DraftRequestParser.parse("/draft notice of appearance")
        XCTAssertEqual(match?.kind, .noticeAppearance)
        XCTAssertEqual(match?.isExplicitCommand, true)
    }

    func testParserRecognizesNaturalLanguageDraftRequest() {
        XCTAssertEqual(DraftRequestParser.parse("Please draft a notice of appearance for this matter")?.kind, .noticeAppearance)
        XCTAssertEqual(DraftRequestParser.parse("prepare a motion to dismiss")?.kind, .motionToDismiss)
        XCTAssertEqual(DraftRequestParser.parse("generate a demand letter")?.kind, .letterDemand)
    }

    func testParserDoesNotFireOnAQuestionAboutTheDocument() {
        // A question, no drafting verb → must not trigger a file generation.
        XCTAssertNil(DraftRequestParser.parse("what is a notice of appearance?"))
        XCTAssertNil(DraftRequestParser.parse("does the motion to dismiss standard apply here"))
    }

    func testParserReturnsNilForNonDraftingChat() {
        XCTAssertNil(DraftRequestParser.parse("summarize the deposition transcript"))
        XCTAssertNil(DraftRequestParser.parse(""))
    }

    // MARK: - M1-T7: effectiveStyle() + firmStyleProfile injection (controller wiring)

    // T-CTRL-01 — no profile ⇒ effectiveStyle() is exactly .defaultFL (invariant 5).
    // RED: undefined member `effectiveStyle` / `firmStyleProfile`.
    @MainActor
    func testEffectiveStyleWithoutProfileIsDefaultFL() throws {
        let store = try makeStore()
        let controller = MatterDraftingController(store: store, storage: makeStorage())
        XCTAssertEqual(controller.effectiveStyle(), HouseStyleSheet.defaultFL)
    }

    // T-CTRL-04 — a below-floor profile is clamped to 24/1440 through the controller (invariant 1).
    @MainActor
    func testBelowFloorProfileClampedThroughController() throws {
        let store = try makeStore()
        var p = FirmStyleProfile()
        p.pageFontHalfPoints = 20
        p.pageMarginTwips = EdgeInsets(top: 720, leading: 720, bottom: 720, trailing: 720)
        let controller = MatterDraftingController(store: store, storage: makeStorage(), firmStyleProfile: p)
        XCTAssertEqual(controller.effectiveStyle().page.fontHalfPoints, 24)
        XCTAssertNotEqual(controller.effectiveStyle().page.fontHalfPoints, 20)
        XCTAssertEqual(controller.effectiveStyle().page.marginTwips.leading, 1440)
    }

    // T-CTRL-05 — the APP path: with NO injected profile, effectiveStyle() falls back to the
    // profile PERSISTED in the store (FirmStyleProfileController's autosave target), read fresh
    // so Settings edits apply at the next draft without reconstructing the controller.
    // WIRE-PROOF at the fallback layer. RED: effectiveStyle() ignores the store ⇒ "CASE NO.: ".
    @MainActor
    func testEffectiveStyleFallsBackToStoredProfile() throws {
        let store = try makeStore()
        var p = FirmStyleProfile()
        p.captionCaseNumberLabel = "CASE NUMBER: "
        try store.appSettings.setSetting(FirmStyleProfile.profileKey, value: p)

        let controller = MatterDraftingController(store: store, storage: makeStorage()) // no injection
        XCTAssertEqual(controller.effectiveStyle().caption.caseNumberLabel, "CASE NUMBER: ")
        XCTAssertNotEqual(controller.effectiveStyle().caption.caseNumberLabel, "CASE NO.: ")
    }

    // T-CTRL-02 — the Notice path passes effectiveStyle() (not .defaultFL) into runNotice.
    // WIRE-PROOF: a non-default caseNumberLabel is captured by a spy renderer.
    @MainActor
    func testNoticePassesEffectiveStyleToRunNotice() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "CV-G",
            docketNumber: "2026-CA-001847"
        )
        let spy = StyleSpyRenderer()
        var p = FirmStyleProfile()
        p.captionCaseNumberLabel = "CASE NUMBER: "
        let controller = MatterDraftingController(
            store: store, storage: makeStorage(), firmStyleProfile: p,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: spy) })

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients(), serviceDate: DateOnly(year: 2026, month: 6, day: 25))
        if case let .failure(error) = result { XCTFail("draft failed before render: \(error)") }

        let captured = try XCTUnwrap(spy.captured, "renderer never received a style")
        XCTAssertEqual(captured.caption.caseNumberLabel, "CASE NUMBER: ")   // effectiveStyle reached the renderer
        XCTAssertNotEqual(captured.caption.caseNumberLabel, "CASE NO.: ")   // not the default sheet
    }

    // T-CTRL-03 — the Letter path passes effectiveStyle() into runLetter. WIRE-PROOF via tagline.
    @MainActor
    func testLetterPassesEffectiveStyleToRunLetter() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let body = #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: body), .event(request, 1, .generationCompleted)])
        })
        let spy = StyleSpyRenderer()
        var p = FirmStyleProfile()
        p.letterheadTagline = "Counselors at Law"
        let controller = MatterDraftingController(
            store: store, runtimeClient: runtime, storage: makeStorage(), firmStyleProfile: p,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: spy) })

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.", recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville", recipientState: "Florida", recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000", responseDeadline: "July 15, 2026", tone: "firm")
        let result = await controller.draftLetterDemand(
            matterID: matter.id, input: input, modelID: ModelID(),
            route: ModelRouter().route(for: .drafting))
        if case let .failure(error) = result { XCTFail("draft failed before render: \(error)") }

        let captured = try XCTUnwrap(spy.captured, "renderer never received a style")
        XCTAssertEqual(captured.letterhead?.headerBlock.tagline, "Counselors at Law")
        XCTAssertNotEqual(captured.letterhead?.headerBlock.tagline, "Attorneys at Law")
    }

    // MARK: - M4-T1: Track B voice (prose register only — never structure)

    // T-VOICE-01a — the register helper enriches from the saved AssistantProfile style surface;
    // an unconfigured profile yields exactly the canned tone phrase (prompt parity).
    // RED: undefined `MatterDraftingController.voiceRegister(tone:profile:)`.
    func testRegisterNotesEnrichedFromAssistantProfile() {
        var styled = completeProfile()
        styled.voiceNotes = "terse, aggressive"
        styled.formality = .plainSpoken
        let enriched = MatterDraftingController.voiceRegister(tone: "firm", profile: styled)
        XCTAssertTrue(enriched.contains("terse"))                          // voiceNotes present
        XCTAssertTrue(enriched.contains("firm but professional"))          // base tone kept

        let plain = MatterDraftingController.voiceRegister(tone: "firm", profile: .empty)
        XCTAssertEqual(plain, "firm but professional")                     // unconfigured ⇒ unchanged
        XCTAssertFalse(plain.contains("terse"))
    }

    // T-VOICE-01b — WIRE-PROOF through the real letter path: the drafting prompt the runtime
    // receives carries the attorney's voiceNotes cue. If the generation closure never fires,
    // the draft fails ("no letter body") and the XCTFail below trips — no silent skip.
    @MainActor
    func testLetterPromptCarriesEnrichedRegister() async throws {
        let store = try makeStore()
        var styled = completeProfile()
        styled.voiceNotes = "terse, aggressive"
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: styled)
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertTrue(request.prompt.contains("terse"),
                          "drafting prompt must carry the attorney's voiceNotes register cue")
            return .events([
                .event(request, 0, .token, token: #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]}]}"#),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = MatterDraftingController(store: store, runtimeClient: runtime, storage: makeStorage())

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.", recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville", recipientState: "Florida", recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000", responseDeadline: "July 15, 2026", tone: "firm")
        let result = await controller.draftLetterDemand(
            matterID: matter.id, input: input, modelID: ModelID(),
            route: ModelRouter().route(for: .drafting))
        if case let .failure(error) = result { XCTFail("draft failed: \(error)") }
    }

    // T-VOICE-02 — STANDING GUARD (GREEN from HEAD, no pre-implementation RED — justified in the
    // TESTPLAN): the voice carrier and the generation output must never grow a structural field.
    // Fails only if a future change adds one (invariant 3: no model-originated structure).
    func testVoiceCarriesNoStructure() {
        let voice = AssistantVoiceProfile(registerNotes: "x")
        XCTAssertEqual(Mirror(reflecting: voice).children.compactMap(\.label), ["registerNotes"])

        let letter = GeneratedLetter(paragraphProvenance: [])
        XCTAssertEqual(Mirror(reflecting: letter).children.compactMap(\.label),
                       ["paragraphProvenance"])
    }
}

/// Captures the `style:` argument the pipeline forwards to the renderer, so the controller
/// wiring tests can prove `effectiveStyle()` (not `.defaultFL`) reaches the render call. Returns
/// dummy bytes — the tests inspect the captured sheet, not the document. `@unchecked Sendable`
/// is safe here: the render happens on the controller's @MainActor and the test awaits it.
final class StyleSpyRenderer: Renderer, @unchecked Sendable {
    let identity = DraftComponentIdentity(id: "test.style-spy-renderer", version: "1")
    private(set) var captured: HouseStyleSheet?
    private(set) var renderCount = 0
    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        renderCount += 1
        captured = style
        return try CompositeRenderer().render(input, style: style)
    }
}

private final class CancellingDraftRenderer: Renderer, @unchecked Sendable {
    let identity = DraftComponentIdentity(id: "test.cancelling-draft-renderer", version: "1")
    private(set) var renderCount = 0

    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        renderCount += 1
        let data = try CompositeRenderer().render(input, style: style)
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return data
    }
}
