import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class RestoreControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_969_600)
    private let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // T-RST-29: a blocked candidate is visible but cannot enter confirmation or staging.
    func testInvalidCandidateCannotBeSelectedConfirmedOrStaged() async throws {
        let fixture = try makeFixture()
        let invalid = candidate(
            identifier: "SupraAI-20260731-090000-000",
            incompatibility: .databaseIntegrityFailed
        )
        var stageCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [invalid] },
            stager: { _, _, _ in
                stageCount += 1
                return self.stageSummary(for: invalid)
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertEqual(controller.restoreState, .incompatible)
        XCTAssertEqual(controller.restoreSnapshots.single?.incompatibility, .databaseIntegrityFailed)
        XCTAssertFalse(controller.selectRestoreSnapshot(id: invalid.identifier))
        XCTAssertFalse(controller.prepareRestoreConfirmation())
        let didStage = await controller.stageConfirmedRestore()
        XCTAssertFalse(didStage)
        XCTAssertEqual(stageCount, 0)
    }

    // T-RST-30: the @MainActor controller is a single-flight owner for both operations.
    func testBackupAndRestoreRejectConcurrentCrossOperationRuns() async throws {
        let fixture = try makeFixture()
        let valid = candidate(identifier: "SupraAI-20260731-090100-000")
        let backupGate = AsyncGate()
        let restoreGate = AsyncGate()
        let controller = makeController(
            fixture: fixture,
            backupRunner: { _ in
                await backupGate.wait()
                return BackupRunSummary(snapshotBytes: 1, copiedBlobCount: 0, referencedBlobCount: 0)
            },
            inspector: { _ in
                await restoreGate.wait()
                return [valid]
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let backup = Task { await controller.backUpNow() }
        await waitUntil { controller.state == .backingUp }
        let rejectedInspection = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(rejectedInspection)
        XCTAssertEqual(controller.restoreState, .failed)
        backupGate.open()
        let backupResult = await backup.value
        XCTAssertTrue(backupResult)

        let inspection = Task { await controller.inspectRestoreSnapshots() }
        await waitUntil { controller.restoreState == .inspecting }
        let rejectedBackup = await controller.backUpNow()
        XCTAssertFalse(rejectedBackup)
        XCTAssertEqual(controller.state, .succeeded, "a rejected backup must not corrupt prior backup state")
        restoreGate.open()
        let inspectionResult = await inspection.value
        XCTAssertTrue(inspectionResult)
        XCTAssertEqual(controller.restoreState, .ready)
    }

    func testDestinationCannotChangeWhileABackupOrRestoreOperationOwnsTheController() async throws {
        let fixture = try makeFixture()
        let backupGate = AsyncGate()
        let controller = makeController(
            fixture: fixture,
            backupRunner: { _ in
                await backupGate.wait()
                return BackupRunSummary(
                    snapshotBytes: 1,
                    copiedBlobCount: 0,
                    referencedBlobCount: 0
                )
            },
            inspector: { _ in [] }
        )
        configure(controller, destination: fixture.destinationURL)
        let originalPath = controller.destinationPath

        let backup = Task { await controller.backUpNow() }
        await waitUntil { controller.state == .backingUp }
        let replacement = fixture.root.appendingPathComponent("Replacement", isDirectory: true)
        let didReplace = controller.configureDestination(
            bookmarkData: Data([0xBA, 0xD0]),
            url: replacement
        )

        XCTAssertFalse(didReplace)
        XCTAssertEqual(controller.destinationPath, originalPath)
        backupGate.open()
        let backupSucceeded = await backup.value
        XCTAssertTrue(backupSucceeded)
    }

    // T-RST-31: restore uses the same stale-bookmark fail-closed path as backup.
    func testRestoreStaleBookmarkPersistsDestinationRepickRequirement() async throws {
        let fixture = try makeFixture(destinationFailure: .staleBookmark)
        var inspectCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                inspectCount += 1
                return []
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(didInspect)
        XCTAssertEqual(inspectCount, 0)
        XCTAssertEqual(controller.state, .needsDestinationRepick)
        XCTAssertEqual(controller.restoreState, .needsDestinationRepick)
        XCTAssertTrue(controller.configuration?.requiresDestinationRepick == true)

        let reloaded = makeController(fixture: fixture, inspector: { _ in [] })
        XCTAssertEqual(reloaded.restoreState, .needsDestinationRepick)
    }

    // T-RST-32/T-RST-40: persisted failures are actionable but never persist paths or content.
    func testRestoreInspectionErrorPersistsContentFreeFailure() async throws {
        let fixture = try makeFixture()
        let secretPath = fixture.destinationURL.appendingPathComponent("Client Alpha/privileged memo.txt").path
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                throw NSError(
                    domain: "RestoreControllerTests",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read \(secretPath)"]
                )
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(didInspect)
        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertFalse(try XCTUnwrap(controller.restoreStatusMessage).contains(secretPath))

        let persisted = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        let persistedJSON = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(persistedJSON.contains(fixture.root.path))
        XCTAssertFalse(persistedJSON.contains("Client Alpha"))

        let reloaded = makeController(fixture: fixture, inspector: { _ in [] })
        XCTAssertEqual(reloaded.restoreState, .failed)
        XCTAssertEqual(reloaded.restoreStatusMessage, controller.restoreStatusMessage)
    }

    // T-RST-33: confirmation freezes identity; a same-name replacement requires reselection.
    func testConfirmedSnapshotMustMatchFreshlyInspectedIdentity() async throws {
        let fixture = try makeFixture()
        let original = candidate(
            identifier: "SupraAI-20260731-090200-000",
            databaseSHA256: String(repeating: "a", count: 64)
        )
        let replacement = candidate(
            identifier: original.identifier,
            databaseSHA256: String(repeating: "b", count: 64)
        )
        var discoveryCount = 0
        var stageCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                discoveryCount += 1
                return discoveryCount == 1 ? [original] : [replacement]
            },
            stager: { _, _, _ in
                stageCount += 1
                return self.stageSummary(for: original)
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: original.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())
        XCTAssertEqual(controller.restoreConfirmation?.snapshotIdentifier, original.identifier)

        let didStage = await controller.stageConfirmedRestore()
        XCTAssertFalse(didStage)
        XCTAssertEqual(stageCount, 0)
        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertNil(controller.restoreConfirmation)
        XCTAssertTrue(controller.restoreStatusMessage?.contains("changed") == true)
    }

    // T-RST-34...36/R-06: scheduling is durable before the live writer is
    // quiesced, and invoking that boundary always requests process exit.
    func testSuccessfulStagePersistsScheduleBeforeRunnerAndRequestsExitExactlyOnce() async throws {
        let fixture = try makeFixture()
        let valid = candidate(identifier: "SupraAI-20260731-090300-000")
        let summary = stageSummary(for: valid, operationID: operationID)
        var events: [String] = []
        var discoveryCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                discoveryCount += 1
                if discoveryCount == 2 { events.append("fresh-identity") }
                return [valid]
            },
            stager: { refreshed, layout, receivedOperationID in
                events.append("runner")
                XCTAssertEqual(refreshed.identifier, valid.identifier)
                XCTAssertEqual(layout, fixture.liveLayout)
                XCTAssertEqual(receivedOperationID, self.operationID)
                let scheduled = try XCTUnwrap(
                    fixture.store.appSettings.getSetting(
                        BackupController.restoreStatusStorageKey,
                        as: RestoreStatusRecord.self
                    )
                )
                XCTAssertEqual(scheduled.state, .staging)
                XCTAssertEqual(scheduled.operationID, self.operationID.uuidString)
                XCTAssertEqual(scheduled.snapshotIdentifier, valid.identifier)
                XCTAssertNotNil(
                    try fixture.store.auditEvents.fetchEvents(
                        relatedTable: "backup_snapshots",
                        relatedID: valid.identifier,
                        eventType: "restore_scheduled"
                    ).single
                )
                return summary
            },
            requestProcessExit: { events.append("exit") }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())
        let didStage = await controller.stageConfirmedRestore()
        XCTAssertTrue(didStage)

        XCTAssertEqual(events, ["fresh-identity", "runner", "exit"])
        XCTAssertTrue(controller.restoreProcessIsTerminal)
        XCTAssertNil(controller.restoreConfirmation)
        let persisted = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(persisted.state, .staging)
        XCTAssertEqual(persisted.operationID, summary.operationID)
        XCTAssertEqual(persisted.snapshotIdentifier, valid.identifier)

        let audit = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(
                relatedTable: "backup_snapshots",
                relatedID: valid.identifier,
                eventType: "restore_scheduled"
            ).single
        )
        let auditText = [audit.summary, audit.relatedID, audit.metadataJSON]
            .compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(auditText.contains(fixture.root.path))
        XCTAssertFalse(auditText.contains(fixture.destinationURL.path))
        XCTAssertTrue(auditText.contains(summary.operationID))
    }

    func testRestoreProcessIsTerminalWhileQuiescedRunnerIsInFlight() async throws {
        let fixture = try makeFixture()
        let valid = candidate(identifier: "SupraAI-20260731-090400-000")
        let stageGate = AsyncGate()
        var backupCount = 0
        var inspectionCount = 0
        var exitCount = 0
        let controller = makeController(
            fixture: fixture,
            backupRunner: { _ in
                backupCount += 1
                return BackupRunSummary(
                    snapshotBytes: 1,
                    copiedBlobCount: 0,
                    referencedBlobCount: 0
                )
            },
            inspector: { _ in
                inspectionCount += 1
                return [valid]
            },
            stager: { selected, _, operationID in
                await stageGate.wait()
                return self.stageSummary(for: selected, operationID: operationID)
            },
            requestProcessExit: { exitCount += 1 }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())
        let staging = Task { await controller.stageConfirmedRestore() }
        await waitUntil { controller.restoreProcessIsTerminal }
        XCTAssertEqual(controller.restoreState, .staging)
        XCTAssertTrue(controller.isAnyBackupOperationBusy)
        stageGate.open()
        let didStage = await staging.value
        XCTAssertTrue(didStage)
        XCTAssertEqual(exitCount, 1)
        XCTAssertEqual(inspectionCount, 2, "staging must re-inspect the frozen selection")

        let stagedMessage = controller.restoreStatusMessage
        let stagedDestination = controller.destinationPath
        XCTAssertFalse(
            controller.configureDestination(
                bookmarkData: Data([0xBA, 0xD0]),
                url: fixture.root.appendingPathComponent("Replacement", isDirectory: true)
            )
        )
        let didBackUp = await controller.backUpNow()
        let didReinspect = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(didBackUp)
        XCTAssertFalse(didReinspect)
        XCTAssertFalse(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertFalse(controller.prepareRestoreConfirmation())

        XCTAssertEqual(backupCount, 0)
        XCTAssertEqual(inspectionCount, 2)
        XCTAssertEqual(controller.destinationPath, stagedDestination)
        XCTAssertTrue(controller.restoreProcessIsTerminal)
        XCTAssertEqual(controller.restoreStatusMessage, stagedMessage)
        XCTAssertTrue(controller.isAnyBackupOperationBusy)

        let persisted = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(persisted.state, .staging)
    }

    func testChangedCandidateNeverEntersTerminalModeOrRequestsExit() async throws {
        let fixture = try makeFixture()
        let original = candidate(
            identifier: "SupraAI-20260731-090500-000",
            databaseSHA256: String(repeating: "a", count: 64)
        )
        let replacement = candidate(
            identifier: original.identifier,
            databaseSHA256: String(repeating: "b", count: 64)
        )
        var discoveryCount = 0
        var runnerCount = 0
        var exitCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                discoveryCount += 1
                return discoveryCount == 1 ? [original] : [replacement]
            },
            stager: { _, _, _ in
                runnerCount += 1
                throw ControllerTestError.stageShouldNotRun
            },
            requestProcessExit: { exitCount += 1 }
        )
        configure(controller, destination: fixture.destinationURL)
        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: original.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())

        let didStage = await controller.stageConfirmedRestore()
        XCTAssertFalse(didStage)
        XCTAssertEqual(runnerCount, 0)
        XCTAssertEqual(exitCount, 0)
        XCTAssertFalse(controller.restoreProcessIsTerminal)
        XCTAssertEqual(controller.restoreState, .failed)
    }

    func testRunnerFailureAfterWriterCloseStillExitsWithoutPostCloseStoreWrites() async throws {
        let fixture = try makeFixture()
        let valid = candidate(identifier: "SupraAI-20260731-090600-000")
        var exitCount = 0
        var inspectionCount = 0
        var runnerCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                inspectionCount += 1
                return [valid]
            },
            stager: { _, _, _ in
                runnerCount += 1
                try fixture.store.database.writer.close()
                throw ControllerTestError.stagingFailedAfterClose
            },
            requestProcessExit: { exitCount += 1 }
        )
        configure(controller, destination: fixture.destinationURL)
        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())

        let didStage = await controller.stageConfirmedRestore()
        XCTAssertFalse(didStage)
        XCTAssertEqual(exitCount, 1)
        XCTAssertTrue(controller.restoreProcessIsTerminal)
        XCTAssertEqual(controller.restoreState, .failed)
        let terminalMessage = controller.restoreStatusMessage

        let didReinspect = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(didReinspect)
        XCTAssertFalse(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertFalse(controller.prepareRestoreConfirmation())
        let didRestage = await controller.stageConfirmedRestore()
        XCTAssertFalse(didRestage)
        controller.cancelRestoreConfirmation()
        XCTAssertEqual(inspectionCount, 2)
        XCTAssertEqual(runnerCount, 1)
        XCTAssertEqual(exitCount, 1)
        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertEqual(controller.restoreStatusMessage, terminalMessage)

        let reopened = try SupraStore(url: fixture.liveLayout.databaseURL)
        let durable = try XCTUnwrap(
            reopened.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .staging)
        XCTAssertEqual(durable.operationID, operationID.uuidString)
        XCTAssertEqual(durable.snapshotIdentifier, valid.identifier)
    }

    func testStrandedStagingStatusBecomesInterruptedFailureOnNextLaunch() throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090700-000"
        let operationsDirectory = fixture.liveLayout.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let orphanDirectory = operationsDirectory.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        let unrelatedDirectory = operationsDirectory.appendingPathComponent(
            "22222222-2222-2222-2222-222222222222",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphanDirectory.appendingPathComponent("safety.tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("synthetic interrupted staging".utf8).write(
            to: orphanDirectory.appendingPathComponent("safety.tmp/partial.bin")
        )
        try FileManager.default.createDirectory(
            at: unrelatedDirectory,
            withIntermediateDirectories: true
        )
        try fixture.store.appSettings.setSetting(
            BackupController.restoreStatusStorageKey,
            value: RestoreStatusRecord(
                state: .staging,
                message: "Restore scheduled.",
                operationID: operationID.uuidString,
                snapshotIdentifier: snapshotID,
                updatedAt: now
            )
        )

        let controller = makeController(fixture: fixture, inspector: { _ in [] })

        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertTrue(controller.restoreStatusMessage?.localizedCaseInsensitiveContains("interrupted") == true)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .failed)
        XCTAssertEqual(durable.operationID, operationID.uuidString)
        XCTAssertEqual(durable.snapshotIdentifier, snapshotID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }

    func testInterruptedStagingCleanupFailureRetainsDurableRetryEvidence() throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090750-000"
        let operationsDirectory = fixture.liveLayout.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let claimedPath = operationsDirectory.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: operationsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: claimedPath,
            withDestinationURL: outsideDirectory
        )
        try fixture.store.appSettings.setSetting(
            BackupController.restoreStatusStorageKey,
            value: RestoreStatusRecord(
                state: .staging,
                message: "Restore scheduled.",
                operationID: operationID.uuidString,
                snapshotIdentifier: snapshotID,
                updatedAt: now
            )
        )

        let controller = makeController(fixture: fixture, inspector: { _ in [] })

        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertTrue(controller.restoreStatusMessage?.localizedCaseInsensitiveContains("retry") == true)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .staging)
        XCTAssertEqual(durable.operationID, operationID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }

    func testMatchingStagingFailureReplaysOnceAfterDurableStatusAndAudit() throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090800-000"
        try fixture.store.appSettings.setSetting(
            BackupController.restoreStatusStorageKey,
            value: RestoreStatusRecord(
                state: .staging,
                message: "Restore scheduled.",
                operationID: operationID.uuidString,
                snapshotIdentifier: snapshotID,
                updatedAt: now
            )
        )
        let failure = try RestoreSidecarStore.recordStagingFailure(
            operationID: operationID,
            reason: .liveDatabaseCloseFailed,
            stagingRootDirectory: fixture.liveLayout.stagingRootDirectory,
            failedAt: now
        )
        var acknowledgeCount = 0

        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [] },
            launchStagingFailure: failure,
            acknowledgeStagingFailure: { acknowledgeCount += 1 }
        )

        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertTrue(controller.restoreStatusMessage?.localizedCaseInsensitiveContains("close") == true)
        XCTAssertEqual(acknowledgeCount, 1)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .failed)
        XCTAssertEqual(durable.operationID?.lowercased(), failure.operationID)
        XCTAssertEqual(durable.snapshotIdentifier, snapshotID)
        XCTAssertNotNil(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "backup_snapshots",
                relatedID: snapshotID,
                eventType: "restore_staging_failed"
            ).single
        )
    }

    func testStagingFailureSidecarIsNotAcknowledgedUntilOrphanCleanupSucceeds() throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090850-000"
        let operationsDirectory = fixture.liveLayout.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let claimedPath = operationsDirectory.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: operationsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: claimedPath,
            withDestinationURL: outsideDirectory
        )
        try fixture.store.appSettings.setSetting(
            BackupController.restoreStatusStorageKey,
            value: RestoreStatusRecord(
                state: .staging,
                message: "Restore scheduled.",
                operationID: operationID.uuidString,
                snapshotIdentifier: snapshotID,
                updatedAt: now
            )
        )
        let failure = try RestoreSidecarStore.recordStagingFailure(
            operationID: operationID,
            reason: .liveDatabaseCloseFailed,
            stagingRootDirectory: fixture.liveLayout.stagingRootDirectory,
            failedAt: now
        )
        var acknowledgeCount = 0

        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [] },
            launchStagingFailure: failure,
            acknowledgeStagingFailure: { acknowledgeCount += 1 }
        )

        XCTAssertEqual(controller.restoreState, .failed)
        XCTAssertTrue(controller.restoreStatusMessage?.localizedCaseInsensitiveContains("retry") == true)
        XCTAssertEqual(acknowledgeCount, 0)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .staging)
        XCTAssertNotNil(try RestoreSidecarStore.readStagingFailure(
            stagingRootDirectory: fixture.liveLayout.stagingRootDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }

    func testDurableActivationOutcomeReplaysAndAcknowledgesAfterAudit() throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090900-000"
        let outcome = try activationOutcome(
            status: .activated,
            snapshotIdentifier: snapshotID
        )
        var acknowledgeCount = 0

        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [] },
            launchRestoreOutcome: outcome,
            acknowledgeRestoreOutcome: { acknowledgeCount += 1 }
        )

        XCTAssertEqual(controller.restoreState, .succeeded)
        XCTAssertEqual(acknowledgeCount, 1)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.updatedAt, outcome.completedAt)
        let audit = try XCTUnwrap(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "backup_snapshots",
                relatedID: snapshotID,
                eventType: "restore_activated"
            ).single
        )
        XCTAssertEqual(audit.timestamp, outcome.completedAt)
    }

    func testOutcomeAcknowledgementFailureBlocksAnotherRestoreUntilRelaunch() async throws {
        let fixture = try makeFixture()
        let snapshotID = "SupraAI-20260731-090950-000"
        let outcome = try activationOutcome(
            status: .activated,
            snapshotIdentifier: snapshotID
        )
        var inspectionCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in
                inspectionCount += 1
                return []
            },
            launchRestoreOutcome: outcome,
            acknowledgeRestoreOutcome: {
                throw ControllerTestError.acknowledgementFailed
            }
        )

        XCTAssertEqual(controller.restoreState, .succeeded)
        XCTAssertTrue(controller.restoreEvidenceRequiresAcknowledgement)
        XCTAssertTrue(controller.restoreStatusMessage?.localizedCaseInsensitiveContains("reopen") == true)
        XCTAssertTrue(controller.isAnyBackupOperationBusy)
        XCTAssertFalse(controller.configureDestination(
            bookmarkData: Data([0x01]),
            url: fixture.destinationURL
        ))
        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertFalse(didInspect)
        XCTAssertEqual(inspectionCount, 0)
        let durable = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(durable.state, .succeeded)
        XCTAssertEqual(durable.updatedAt, outcome.completedAt)
    }

    func testRecoveryRequiredOutcomeIsNotAcknowledged() throws {
        let fixture = try makeFixture()
        let outcome = try activationOutcome(
            status: .recoveryRequired,
            snapshotIdentifier: nil
        )
        var acknowledgeCount = 0

        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [] },
            launchRestoreOutcome: outcome,
            acknowledgeRestoreOutcome: { acknowledgeCount += 1 }
        )

        XCTAssertEqual(controller.restoreState, .recoveryRequired)
        XCTAssertEqual(acknowledgeCount, 0)
    }

    private func makeFixture(
        destinationFailure: BackupDestinationError? = nil
    ) throws -> ControllerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SupraStore(url: root.appendingPathComponent("SupraAI.sqlite"))
        let destinationURL = root.appendingPathComponent("Backups", isDirectory: true)
        let layout = RestoreLiveLayout(
            databaseURL: root.appendingPathComponent("SupraAI.sqlite"),
            blobsDirectory: root.appendingPathComponent("Documents/blobs", isDirectory: true),
            stagingRootDirectory: root.appendingPathComponent("RestoreStaging", isDirectory: true)
        )
        return ControllerFixture(
            root: root,
            store: store,
            destinationURL: destinationURL,
            destination: FakeRestoreDestination(url: destinationURL, failure: destinationFailure),
            liveLayout: layout
        )
    }

    private func makeController(
        fixture: ControllerFixture,
        backupRunner: @escaping BackupController.BackupRunner = { _ in
            BackupRunSummary(snapshotBytes: 1, copiedBlobCount: 0, referencedBlobCount: 0)
        },
        inspector: @escaping BackupController.RestoreInspector,
        stager: @escaping BackupController.RestoreRunner = { _, _, _ in
            throw ControllerTestError.stageShouldNotRun
        },
        requestProcessExit: @escaping @MainActor () -> Void = {},
        launchRestoreOutcome: RestoreOutcomeRecord? = nil,
        launchStagingFailure: RestoreStagingFailureRecord? = nil,
        acknowledgeRestoreOutcome: @escaping @MainActor () throws -> Void = {},
        acknowledgeStagingFailure: @escaping @MainActor () throws -> Void = {}
    ) -> BackupController {
        BackupController(
            store: fixture.store,
            blobsDirectory: fixture.liveLayout.blobsDirectory,
            appVersion: "9.8.7",
            appBuild: "654",
            destinationFactory: { bookmark in
                fixture.destination.receivedBookmarkData = bookmark
                return fixture.destination
            },
            backupRunner: backupRunner,
            sourceSizeProvider: { 0 },
            restoreLiveLayout: fixture.liveLayout,
            restoreInspector: inspector,
            restoreRunner: stager,
            restoreOperationIDProvider: { self.operationID },
            requestProcessExit: requestProcessExit,
            launchRestoreOutcome: launchRestoreOutcome,
            launchStagingFailure: launchStagingFailure,
            acknowledgeRestoreOutcome: acknowledgeRestoreOutcome,
            acknowledgeStagingFailure: acknowledgeStagingFailure,
            now: { self.now }
        )
    }

    private func configure(_ controller: BackupController, destination: URL) {
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0xFA, 0xCE]), url: destination))
    }

    private func candidate(
        identifier: String,
        databaseSHA256: String = String(repeating: "a", count: 64),
        incompatibility: RestoreIncompatibility? = nil
    ) -> RestoreSnapshotCandidate {
        let root = URL(fileURLWithPath: "/never-exposed/backup", isDirectory: true)
        let manifest = BackupManifest(
            appVersion: "2.3.2",
            appBuild: "391",
            schemaMigrationIdentifiers: ["m1"],
            createdAt: now,
            sourceDbBytes: 4_096,
            referencedBlobCount: 2
        )
        return RestoreSnapshotCandidate(
            identifier: identifier,
            backupDirectoryURL: root,
            snapshotURL: root.appendingPathComponent("db/\(identifier).sqlite"),
            manifestURL: root.appendingPathComponent("db/\(identifier).json"),
            manifest: manifest,
            summary: RestoreSnapshotSummary(
                createdAt: now,
                appVersion: manifest.appVersion,
                appBuild: manifest.appBuild,
                databaseBytes: manifest.sourceDbBytes,
                referencedBlobCount: manifest.referencedBlobCount
            ),
            databaseSHA256: databaseSHA256,
            referencedBlobs: [],
            incompatibility: incompatibility
        )
    }

    private func stageSummary(
        for candidate: RestoreSnapshotCandidate,
        operationID: UUID? = nil
    ) -> RestoreStageSummary {
        RestoreStageSummary(
            operationID: (operationID ?? self.operationID).uuidString,
            snapshotIdentifier: candidate.identifier,
            stagedAt: now
        )
    }

    private func activationOutcome(
        status: RestoreActivationStatus,
        snapshotIdentifier: String?
    ) throws -> RestoreOutcomeRecord {
        var object: [String: Any] = [
            "schemaVersion": RestoreOutcomeRecord.currentSchemaVersion,
            "status": status.rawValue,
            "completedAt": "2026-07-31T13:00:00Z",
        ]
        if status != .recoveryRequired {
            object["operationID"] = operationID.uuidString.lowercased()
            object["operationTreeCleanupPending"] = false
        }
        if let snapshotIdentifier {
            object["snapshotIdentifier"] = snapshotIdentifier
        }
        return try RestoreOutcomeRecord.decode(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

private struct ControllerFixture {
    let root: URL
    let store: SupraStore
    let destinationURL: URL
    let destination: FakeRestoreDestination
    let liveLayout: RestoreLiveLayout
}

@MainActor
private final class FakeRestoreDestination: BackupDestination {
    let url: URL
    let failure: BackupDestinationError?
    var receivedBookmarkData: Data?
    private(set) var accessCount = 0
    private(set) var isAccessing = false

    init(url: URL, failure: BackupDestinationError?) {
        self.url = url
        self.failure = failure
    }

    func withAccess<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T {
        if let failure { throw failure }
        accessCount += 1
        isAccessing = true
        defer { isAccessing = false }
        return try await operation(url)
    }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ControllerTestError: Error {
    case stageShouldNotRun
    case stagingFailedAfterClose
    case acknowledgementFailed
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
