import Foundation
import XCTest
@testable import SupraStore

final class RestoreActivationServiceTests: XCTestCase {
    private var fixture: RestoreTestFixture!
    private let migrations = ["m1", "m2"]

    override func setUpWithError() throws {
        fixture = try RestoreTestFixture()
    }

    override func tearDownWithError() throws {
        fixture.remove()
        fixture = nil
    }

    // T-RST-19 expected RED: no launch-only activation seam exists, so the
    // selected database cannot be proven live before the first migrated open.
    func testColdStartReplacesDatabaseBeforeOpeningThroughSupraDatabase() throws {
        try fixture.writeShippingLiveState(sentinel: "current canary")
        _ = try fixture.writeCompleteShippingSnapshot(sentinel: "selected canary")
        let shippingMigrations = SupraMigrator.makeMigrator().migrations
        let staged = try stageCandidate(knownMigrations: shippingMigrations)
        let operations = RecordingRestoreActivationOperations()
        for suffix in ["-journal", "-wal", "-shm"] {
            try Data("STALE SQLITE SIDECAR".utf8).write(
                to: URL(fileURLWithPath: fixture.liveDatabaseURL.path + suffix)
            )
        }

        let result = RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: shippingMigrations,
            operations: operations
        ) { databaseURL in
            operations.record(.openSelectedDatabase)
            XCTAssertEqual(try self.fixture.sentinel(in: databaseURL), "selected canary")
            for suffix in ["-journal", "-wal", "-shm"] {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: databaseURL.path + suffix
                ))
            }
            return try SupraDatabase(url: databaseURL)
        }

        XCTAssertEqual(result.status, .activated)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "selected canary")
        XCTAssertLessThan(
            try XCTUnwrap(operations.events.firstIndex(of: .replaceSelectedDatabase)),
            try XCTUnwrap(operations.events.firstIndex(of: .openSelectedDatabase))
        )
        XCTAssertLessThan(
            try XCTUnwrap(operations.events.firstIndex(of: .openSelectedDatabase)),
            try XCTUnwrap(operations.events.firstIndex(of: .removeMarker))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
    }

    // T-RST-20/T-RST-38 expected RED: selected blobs are not installed at cold
    // start, so the selected managed blob is absent from the live tree.
    func testActivationInstallsSelectedBlobsAndPreservesUnrelatedLiveObjects() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(
            currentBlobs: [currentBlob],
            selectedBlobs: [selectedBlob]
        )
        let operations = RecordingRestoreActivationOperations()

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .activated)
        XCTAssertEqual(
            try Data(contentsOf: fixture.liveBlobsDirectory.appendingPathComponent(currentBlob.relativePath)),
            currentBlob.bytes
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.liveBlobsDirectory.appendingPathComponent(selectedBlob.relativePath)),
            selectedBlob.bytes
        )
        XCTAssertTrue(operations.events.contains(.copySelectedBlob))
    }

    // expected RED: first-use blob installation publishes the outcome and
    // consumes the marker without synchronizing the new live blob-root parent.
    func testActivationPublishesNewLiveBlobRootBeforeOutcomeAndMarkerConsumption() throws {
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(selectedBlobs: [selectedBlob])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.liveBlobsDirectory.path))
        let operations = RecordingRestoreActivationOperations()

        XCTAssertEqual(activate(operations: operations).status, .activated)

        let parentSync = try XCTUnwrap(
            operations.events.firstIndex(of: .synchronizeLiveBlobParent)
        )
        XCTAssertLessThan(
            parentSync,
            try XCTUnwrap(operations.events.firstIndex(of: .writeOutcome))
        )
        XCTAssertLessThan(
            parentSync,
            try XCTUnwrap(operations.events.firstIndex(of: .removeMarker))
        )
    }

    // expected RED: failure to synchronize the new live blob-root parent is
    // ignored, so activation reports success and consumes the pending marker.
    func testActivationFailsClosedWhenNewLiveBlobRootParentSyncFails() throws {
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(selectedBlobs: [selectedBlob])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.liveBlobsDirectory.path))
        let operations = RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeLiveBlobParent: 1]
        )

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .failedAndRolledBack)
        XCTAssertEqual(result.activationFailure, .blobInstallationFailed)
        XCTAssertTrue(operations.events.contains(.synchronizeLiveBlobParent))
    }

    // expected RED: once the blob root is visible after a failed parent sync,
    // retry skips the publication proof and writes terminal evidence first.
    func testLiveBlobRootPublicationRetriesWhenVisibleAfterSyncFailure() throws {
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(selectedBlobs: [selectedBlob])
        let first = activate(operations: RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeLiveBlobParent: 1]
        ))
        XCTAssertEqual(first.status, .failedAndRolledBack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.liveBlobsDirectory.path))
        try RestoreSidecarStore.acknowledgeActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        )
        _ = try stageCandidate(knownMigrations: migrations)
        let retryOperations = RecordingRestoreActivationOperations()

        XCTAssertEqual(activate(operations: retryOperations).status, .activated)

        XCTAssertLessThan(
            try XCTUnwrap(retryOperations.events.firstIndex(of: .synchronizeLiveBlobParent)),
            try XCTUnwrap(retryOperations.events.firstIndex(of: .writeOutcome))
        )
    }

    // expected RED: retry of a two-level MatterDocuments/blobs root does not
    // publish through the known live-database parent before terminal evidence.
    func testTwoLevelBlobRootRetryPublishesThroughLiveDatabaseParent() throws {
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(selectedBlobs: [selectedBlob])
        let nestedBlobsDirectory = fixture.liveDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent("MatterDocuments/blobs", isDirectory: true)
        let first = activate(
            operations: RecordingRestoreActivationOperations(
                failureCounts: [.synchronizeLiveBlobParent: 1]
            ),
            liveBlobsDirectory: nestedBlobsDirectory
        )
        XCTAssertEqual(first.status, .failedAndRolledBack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedBlobsDirectory.path))
        try RestoreSidecarStore.acknowledgeActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        )
        _ = try stageCandidate(knownMigrations: migrations)
        let retryOperations = RecordingRestoreActivationOperations()

        XCTAssertEqual(activate(
            operations: retryOperations,
            liveBlobsDirectory: nestedBlobsDirectory
        ).status, .activated)

        XCTAssertLessThan(
            try XCTUnwrap(retryOperations.events.firstIndex(of: .synchronizeLiveBlobParent)),
            try XCTUnwrap(retryOperations.events.firstIndex(of: .writeOutcome))
        )
    }

    // T-RST-21 expected RED: blob installation has no idempotent reuse rule.
    func testActivationReusesAlreadyCorrectSelectedBlobWithoutOverwritingIt() throws {
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try stage(selectedBlobs: [selectedBlob])
        let existing = fixture.liveBlobsDirectory.appendingPathComponent(selectedBlob.relativePath)
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try selectedBlob.bytes.write(to: existing)
        let originalFingerprint = try fixture.fingerprint(existing)
        let operations = RecordingRestoreActivationOperations()

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .activated)
        XCTAssertEqual(try fixture.fingerprint(existing), originalFingerprint)
        XCTAssertFalse(operations.events.contains(.copySelectedBlob))
    }

    // T-RST-22/T-RST-41 expected RED: a consumed marker cannot yet be proven a
    // no-op, so a later launch can attempt selected-state mutation again.
    func testActivationIsNoOpAfterSuccessfulMarkerConsumption() throws {
        _ = try stage()
        let operations = RecordingRestoreActivationOperations()
        XCTAssertEqual(activate(operations: operations).status, .activated)
        let eventCount = operations.events.count

        let second = activate(operations: operations)

        XCTAssertEqual(second.status, .noPendingRestore)
        XCTAssertEqual(operations.events.count, eventCount)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "selected canary")
    }

    // T-RST-H04 expected RED: successful activation consumes the marker but
    // leaves the authenticated selected and safety trees indefinitely.
    func testActivatedOutcomeRemovesItsOperationTreeDurably() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations()

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .activated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertTrue(operations.events.contains(.removeOperationTree))
        XCTAssertTrue(operations.events.contains(.synchronizeOperationsDirectory))
    }

    // T-RST-23 expected RED: replacement failure has no verified safety rollback.
    func testSelectedReplacementFailureRollsBackExactPriorCanary() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations(failures: [.replaceSelectedDatabase])

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .failedAndRolledBack)
        XCTAssertEqual(result.activationFailure, .databaseReplacementFailed)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
        XCTAssertTrue(operations.events.contains(.replaceSafetyDatabase))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(operations.events.contains(.synchronizeMarkerDirectory))
    }

    // A verified rollback consumes the failed request. Replaying that request
    // on every later cold launch could eventually replace newer live work.
    func testVerifiedRollbackConsumesIntentAndSecondActivationIsNoOp() throws {
        let staged = try stage()
        let firstOperations = RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase]
        )

        let first = activate(operations: firstOperations)

        XCTAssertEqual(first.status, .failedAndRolledBack)
        XCTAssertEqual(first.activationFailure, .databaseReplacementFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
        let secondOperations = RecordingRestoreActivationOperations()

        let second = activate(operations: secondOperations)

        XCTAssertEqual(second.status, .noPendingRestore)
        XCTAssertTrue(secondOperations.events.isEmpty)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
    }

    // T-RST-H05 expected RED: verified rollback is terminal, but its operation
    // tree is retained even though recovery no longer depends on it.
    func testFailedAndRolledBackOutcomeRemovesItsOperationTreeDurably() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase]
        )

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .failedAndRolledBack)
        XCTAssertNil(result.recoverySafetyDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertTrue(operations.events.contains(.removeOperationTree))
        XCTAssertTrue(operations.events.contains(.synchronizeOperationsDirectory))
    }

    // T-RST-H06 expected RED: a terminal cleanup failure has no durable retry
    // key once its pending marker has already been consumed.
    func testTerminalCleanupFailureRetriesFromDurableOutcomeOnNextLaunch() throws {
        let staged = try stage()
        let firstOperations = RecordingRestoreActivationOperations(
            failures: [.removeOperationTree]
        )

        let first = activate(operations: firstOperations)

        XCTAssertEqual(first.status, .activated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        let firstOutcome = try XCTUnwrap(RestoreSidecarStore.readActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
        XCTAssertEqual(firstOutcome.operationID, staged.intent.operationID)
        XCTAssertEqual(firstOutcome.status, .activated)
        let secondOperations = RecordingRestoreActivationOperations()

        let second = activate(operations: secondOperations)

        XCTAssertEqual(second.status, .noPendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertTrue(secondOperations.events.contains(.removeOperationTree))
        XCTAssertTrue(secondOperations.events.contains(.synchronizeOperationsDirectory))
    }

    // T-RST-H06 expected RED: if unlink succeeds but the containing-directory
    // sync fails, the next launch does not republish that removal because the
    // operation directory is already absent in the running filesystem view.
    func testTerminalCleanupRetriesDirectorySyncAfterUnlinkAlreadySucceeded() throws {
        let staged = try stage()
        let firstOperations = RecordingRestoreActivationOperations(
            failures: [.synchronizeOperationsDirectory]
        )

        let first = activate(operations: firstOperations)

        XCTAssertEqual(first.status, .activated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertTrue(firstOperations.events.contains(.synchronizeOperationsDirectory))
        let secondOperations = RecordingRestoreActivationOperations()

        let second = activate(operations: secondOperations)

        XCTAssertEqual(second.status, .noPendingRestore)
        XCTAssertTrue(secondOperations.events.contains(.synchronizeOperationsDirectory))
    }

    // T-RST-24 expected RED: first-open failure can leave selected data live.
    func testSelectedOpenFailureRollsBackExactPriorCanary() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations()
        var openCount = 0

        let result = activate(operations: operations) { _ in
            openCount += 1
            if openCount == 1 {
                operations.record(.openSelectedDatabase)
                throw ActivationTestError.selectedOpen
            }
            operations.record(.openSafetyDatabase)
            return try SupraDatabase.inMemory()
        }

        XCTAssertEqual(result.status, .failedAndRolledBack)
        XCTAssertEqual(result.activationFailure, .databaseOpenFailed)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
        XCTAssertTrue(operations.events.contains(.openSafetyDatabase))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
    }

    // T-RST-25 expected RED: migration failure has no automatic rollback path.
    func testSelectedMigrationFailureRollsBackExactPriorCanary() throws {
        _ = try stage()
        let operations = RecordingRestoreActivationOperations()
        var openCount = 0

        let result = activate(operations: operations) { _ in
            openCount += 1
            if openCount == 1 {
                throw SupraDatabaseOpenError.migrationFailed(
                    snapshotURL: nil,
                    reason: "synthetic migration fault"
                )
            }
            return try SupraDatabase.inMemory()
        }

        XCTAssertEqual(result.status, .failedAndRolledBack)
        XCTAssertEqual(result.activationFailure, .databaseOpenFailed)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
    }

    // T-RST-26 expected RED: activation and rollback replacement double failure
    // can incorrectly fall through to a normal store shell.
    func testActivationAndRollbackReplacementFailureRequiresRecovery() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase, .replaceSafetyDatabase]
        )

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .databaseReplacementFailed)
        XCTAssertEqual(result.rollbackFailure, .databaseReplacementFailed)
        XCTAssertEqual(
            result.recoverySafetyDirectoryURL,
            staged.safetyDatabaseURL.deletingLastPathComponent()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertFalse(operations.events.contains(.removeOperationTree))
    }

    // T-RST-H08 expected RED: recovery exposes only the safety database, so the
    // sibling managed-blob tree can be omitted from the item offered for preservation.
    func testRecoveryRequiredExposesCompleteSafetyDirectoryForManualPreservation() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        let staged = try stage(
            currentBlobs: [currentBlob],
            selectedBlobs: [selectedBlob]
        )
        try FileManager.default.removeItem(
            at: fixture.liveBlobsDirectory.appendingPathComponent(currentBlob.relativePath)
        )
        let operations = RecordingRestoreActivationOperations(failures: [.copySafetyBlob])

        let result = activate(operations: operations) { _ in
            operations.record(.openSelectedDatabase)
            throw ActivationTestError.selectedOpen
        }

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .databaseOpenFailed)
        XCTAssertEqual(result.rollbackFailure, .blobInstallationFailed)
        let recoveryDirectory = try XCTUnwrap(result.recoverySafetyDirectoryURL)
        XCTAssertEqual(recoveryDirectory, staged.safetyDatabaseURL.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryDirectory.appendingPathComponent("restore-safety.sqlite").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryDirectory
                .appendingPathComponent("blobs", isDirectory: true)
                .appendingPathComponent(currentBlob.relativePath)
                .path
        ))
    }

    // expected RED: a durable recovery-required outcome is ignored on the next
    // launch, which retries selected-state mutation instead of freezing replay.
    func testDurableRecoveryOutcomeFreezesSecondLaunchBeforeMutation() throws {
        let staged = try stage()
        let firstOperations = RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase, .replaceSafetyDatabase]
        )

        let first = activate(operations: firstOperations)

        XCTAssertEqual(first.status, .recoveryRequired)
        let outcomeURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        let durableOutcome = try Data(contentsOf: outcomeURL)
        let secondOperations = RecordingRestoreActivationOperations()

        let second = activate(operations: secondOperations)

        XCTAssertEqual(second.status, .recoveryRequired)
        XCTAssertEqual(second.activationFailure, first.activationFailure)
        XCTAssertEqual(second.rollbackFailure, first.rollbackFailure)
        XCTAssertEqual(second.operationID, staged.intent.operationID)
        XCTAssertEqual(second.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertEqual(
            second.recoverySafetyDirectoryURL,
            staged.safetyDatabaseURL.deletingLastPathComponent()
        )
        XCTAssertTrue(secondOperations.events.isEmpty)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertEqual(try Data(contentsOf: outcomeURL), durableOutcome)
    }

    // expected RED: activation and rollback consume the pending marker before
    // the terminal outcome sidecar has been written durably.
    func testTerminalOutcomeIsDurableBeforePendingMarkerConsumption() throws {
        _ = try stage()
        let activationOperations = RecordingRestoreActivationOperations()

        XCTAssertEqual(activate(operations: activationOperations).status, .activated)
        XCTAssertLessThan(
            try XCTUnwrap(activationOperations.events.firstIndex(of: .writeOutcome)),
            try XCTUnwrap(activationOperations.events.firstIndex(of: .removeMarker))
        )

        fixture.remove()
        fixture = try RestoreTestFixture()
        _ = try stage()
        let rollbackOperations = RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase]
        )

        XCTAssertEqual(activate(operations: rollbackOperations).status, .failedAndRolledBack)
        XCTAssertLessThan(
            try XCTUnwrap(rollbackOperations.events.firstIndex(of: .writeOutcome)),
            try XCTUnwrap(rollbackOperations.events.firstIndex(of: .removeMarker))
        )
    }

    // expected RED: marker-removal retry failure returns recovery without the
    // authenticated operation, snapshot, and verified safety-database context.
    func testTerminalOutcomeMarkerRetryFailureRetainsAuthenticatedRecoveryContext() throws {
        let staged = try stage()
        let terminal = RestoreActivationResult.failedAndRolledBack(
            .databaseReplacementFailed,
            intent: staged.intent
        )
        _ = try RestoreSidecarStore.recordActivationOutcome(
            terminal,
            stagingRootDirectory: fixture.stagingRootDirectory,
            completedAt: Date(timeIntervalSince1970: 1_788_969_600),
            fileManager: .default,
            operations: SystemRestoreActivationFileOperations()
        )
        let operations = RecordingRestoreActivationOperations(failures: [.removeMarker])

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .databaseReplacementFailed)
        XCTAssertEqual(result.rollbackFailure, .markerRemovalFailed)
        XCTAssertEqual(result.operationID, staged.intent.operationID)
        XCTAssertEqual(result.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertEqual(
            result.recoverySafetyDirectoryURL,
            staged.safetyDatabaseURL.deletingLastPathComponent()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertFalse(operations.events.contains(.replaceSelectedDatabase))
        XCTAssertFalse(operations.events.contains(.replaceSafetyDatabase))
    }

    // expected RED: an outcome-sidecar write fault consumes the pending marker
    // or loses authenticated context, silently discarding replay and cleanup state.
    func testOutcomeWriteFailureKeepsPendingMarkerAndBlocksLaunch() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations(failures: [.writeOutcome])

        let result = activate(operations: operations)

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .outcomePersistenceFailed)
        XCTAssertEqual(result.operationID, staged.intent.operationID)
        XCTAssertEqual(result.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
        XCTAssertFalse(operations.events.contains(.removeMarker))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.stagingRootDirectory
                .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName).path
        ))
    }

    // T-RST-27 expected RED: rollback open/validation double failure can be
    // mistaken for a successful rollback.
    func testActivationAndRollbackOpenFailureRequiresRecovery() throws {
        let staged = try stage()
        let operations = RecordingRestoreActivationOperations()

        let result = activate(operations: operations) { _ in
            if operations.events.contains(.openSelectedDatabase) {
                operations.record(.openSafetyDatabase)
                throw ActivationTestError.safetyOpen
            }
            operations.record(.openSelectedDatabase)
            throw ActivationTestError.selectedOpen
        }

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .databaseOpenFailed)
        XCTAssertEqual(result.rollbackFailure, .databaseOpenFailed)
        XCTAssertEqual(
            result.recoverySafetyDirectoryURL,
            staged.safetyDatabaseURL.deletingLastPathComponent()
        )
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
    }

    // An invalid safety database cannot be offered as a verified manual-recovery
    // artifact when activation stops before selected-state mutation.
    func testInvalidSafetyStateExposesNoRecoveryDatabase() throws {
        let staged = try stage()
        try Data("CORRUPT SAFETY DATABASE".utf8).write(to: staged.safetyDatabaseURL)

        let result = activate(operations: RecordingRestoreActivationOperations())

        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.activationFailure, .safetyStateInvalid)
        XCTAssertEqual(result.rollbackFailure, .safetyStateInvalid)
        XCTAssertNil(result.recoverySafetyDirectoryURL)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
    }

    // T-RST-28: if the selected-state marker cannot be durably consumed even
    // after rollback, launch must stop in recovery instead of replaying it.
    func testMarkerRemovalFailureAfterVerifiedRollbackRequiresRecovery() throws {
        let staged = try stage()
        let failingOperations = RecordingRestoreActivationOperations(failures: [.removeMarker])

        let failed = activate(operations: failingOperations)

        XCTAssertEqual(failed.status, .recoveryRequired)
        XCTAssertEqual(failed.activationFailure, .markerRemovalFailed)
        XCTAssertEqual(failed.rollbackFailure, .markerRemovalFailed)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertLessThan(
            try XCTUnwrap(failingOperations.events.firstIndex(of: .openSelectedDatabase)),
            try XCTUnwrap(failingOperations.events.firstIndex(of: .removeMarker))
        )
        XCTAssertEqual(
            failingOperations.events.filter { $0 == .removeMarker }.count,
            2
        )
    }

    func testMarkerDurabilityFailureAfterVerifiedRollbackRequiresRecovery() throws {
        let staged = try stage()
        let failingOperations = RecordingRestoreActivationOperations(
            failures: [.synchronizeMarkerDirectory]
        )

        let failed = activate(operations: failingOperations)

        XCTAssertEqual(failed.status, .recoveryRequired)
        XCTAssertEqual(failed.activationFailure, .markerRemovalFailed)
        XCTAssertEqual(failed.rollbackFailure, .markerRemovalFailed)
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current canary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertEqual(
            failingOperations.events.filter { $0 == .synchronizeMarkerDirectory }.count,
            2
        )

        let replayOperations = RecordingRestoreActivationOperations()
        let replay = activate(operations: replayOperations)

        XCTAssertEqual(replay.status, .recoveryRequired)
        XCTAssertEqual(replay.activationFailure, failed.activationFailure)
        XCTAssertEqual(replay.rollbackFailure, failed.rollbackFailure)
        XCTAssertEqual(replay.operationID, staged.intent.operationID)
        XCTAssertEqual(replay.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertEqual(
            replay.recoverySafetyDirectoryURL,
            staged.safetyDatabaseURL.deletingLastPathComponent()
        )
        XCTAssertTrue(replayOperations.events.isEmpty)
    }

    // expected RED: markerless recovery trusts tampered operation-local intent
    // and can re-enter live-state mutation instead of failing closed.
    func testMarkerlessRecoveryRejectsTamperedOperationIntentWithoutLiveMutation() throws {
        let staged = try stage()
        let failed = activate(operations: RecordingRestoreActivationOperations(
            failures: [.synchronizeMarkerDirectory]
        ))
        XCTAssertEqual(failed.status, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.markerURL.path))
        try Data("{}".utf8).write(
            to: staged.operationDirectoryURL
                .appendingPathComponent(RestoreIntent.operationFileName),
            options: .atomic
        )
        let liveFingerprint = try fixture.fingerprint(fixture.liveDatabaseURL)
        let replayOperations = RecordingRestoreActivationOperations()

        let replay = activate(operations: replayOperations)

        XCTAssertEqual(replay.status, .recoveryRequired)
        XCTAssertEqual(replay.activationFailure, .safetyStateInvalid)
        XCTAssertEqual(replay.rollbackFailure, .safetyStateInvalid)
        XCTAssertNil(replay.recoverySafetyDirectoryURL)
        XCTAssertEqual(try fixture.fingerprint(fixture.liveDatabaseURL), liveFingerprint)
        XCTAssertTrue(replayOperations.events.isEmpty)
    }

    // T-RST-40...42 expected RED: the launch service has no durable,
    // content-free outcome record whose bytes remain stable on a second launch.
    // T-RST-H09 expected RED: the authenticated scheduling timestamp is lost
    // when activation replaces the database that contains restore_scheduled.
    func testTRST40Through42OutcomeIsContentFreeIdempotentAndLeavesBackupUntouched() throws {
        try fixture.writeShippingLiveState(sentinel: "current private canary")
        let source = try fixture.writeCompleteShippingSnapshot(
            sentinel: "selected private canary"
        )
        let sourceFingerprint = try [source.snapshot, source.manifest].map(fixture.fingerprint)
        let shippingMigrations = SupraMigrator.makeMigrator().migrations
        let staged = try stageCandidate(knownMigrations: shippingMigrations)

        let first = RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: shippingMigrations
        )

        XCTAssertEqual(first.status, .activated)
        XCTAssertEqual(first.operationID, staged.intent.operationID)
        XCTAssertEqual(first.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertEqual(first.scheduledAt, staged.intent.createdAt)
        let outcomeURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        let firstOutcomeData = try Data(contentsOf: outcomeURL)
        let outcome = try RestoreOutcomeRecord.decode(firstOutcomeData)
        XCTAssertEqual(outcome.schemaVersion, RestoreOutcomeRecord.currentSchemaVersion)
        XCTAssertEqual(outcome.status, .activated)
        XCTAssertEqual(outcome.operationID, staged.intent.operationID)
        XCTAssertEqual(outcome.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
        XCTAssertEqual(outcome.scheduledAt, staged.intent.createdAt)
        XCTAssertNil(outcome.activationFailure)
        XCTAssertNil(outcome.rollbackFailure)

        let serialized = try XCTUnwrap(String(data: firstOutcomeData, encoding: .utf8))
        XCTAssertFalse(serialized.contains(fixture.root.path))
        XCTAssertFalse(serialized.contains(source.snapshot.path))
        XCTAssertFalse(serialized.contains("private canary"))

        let second = RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: shippingMigrations
        )

        XCTAssertEqual(second.status, .noPendingRestore)
        XCTAssertEqual(try Data(contentsOf: outcomeURL), firstOutcomeData)
        XCTAssertEqual(
            try [source.snapshot, source.manifest].map(fixture.fingerprint),
            sourceFingerprint
        )
    }

    // T-RST-H07 expected RED: activation writes a display-safe outcome, but
    // clients must read and unlink its raw file themselves.
    func testActivationOutcomeReadAndAcknowledgeAPI() throws {
        try fixture.writeShippingLiveState(sentinel: "current canary")
        _ = try fixture.writeCompleteShippingSnapshot(sentinel: "selected canary")
        let shippingMigrations = SupraMigrator.makeMigrator().migrations
        let staged = try stageCandidate(knownMigrations: shippingMigrations)

        let result = RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: shippingMigrations
        )

        XCTAssertEqual(result.status, .activated)
        let record = try XCTUnwrap(RestoreSidecarStore.readActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
        XCTAssertEqual(record.operationID, staged.intent.operationID)
        XCTAssertEqual(record.status, .activated)

        try RestoreSidecarStore.acknowledgeActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        )

        XCTAssertNil(try RestoreSidecarStore.readActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
    }

    // expected RED: after outcome unlink succeeds but directory sync fails, a
    // retry sees no sidecar and omits the outstanding removal durability proof.
    func testActivationOutcomeAcknowledgementRetriesAfterUnlinkSyncFailure() throws {
        _ = try stage()
        XCTAssertEqual(
            activate(operations: RecordingRestoreActivationOperations()).status,
            .activated
        )
        let failingOperations = RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeMarkerDirectory: 1]
        )

        XCTAssertThrowsError(try RestoreSidecarStore.acknowledgeActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: failingOperations
        ))

        let replayOperations = RecordingRestoreActivationOperations()
        XCTAssertNil(try RestoreSidecarStore.readActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: replayOperations
        ))
        XCTAssertTrue(replayOperations.events.contains(.synchronizeMarkerDirectory))
    }

    // expected RED: after staging-failure unlink succeeds but directory sync
    // fails, a retry sees no sidecar and omits the outstanding durability proof.
    func testStagingFailureAcknowledgementRetriesAfterUnlinkSyncFailure() throws {
        let operationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        _ = try RestoreSidecarStore.recordStagingFailure(
            operationID: operationID,
            reason: .stagingIOFailed,
            stagingRootDirectory: fixture.stagingRootDirectory
        )
        let failingOperations = RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeMarkerDirectory: 1]
        )

        XCTAssertThrowsError(try RestoreSidecarStore.acknowledgeStagingFailure(
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: failingOperations
        ))

        let replayOperations = RecordingRestoreActivationOperations()
        XCTAssertNil(try RestoreSidecarStore.readStagingFailure(
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: replayOperations
        ))
        XCTAssertTrue(replayOperations.events.contains(.synchronizeMarkerDirectory))
    }

    // expected RED: first-use failure-sidecar creation does not durably publish
    // the staging root through its parent or retry that proof after failure.
    func testFirstUseStagingFailureSidecarPublishesParentAndRetriesProof() throws {
        let operationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let stagingParent = fixture.stagingRootDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stagingParent,
            withIntermediateDirectories: true
        )
        let failingOperations = RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeStagingParent: 1],
            stagingParentURL: stagingParent
        )

        XCTAssertThrowsError(try RestoreSidecarStore.recordStagingFailure(
            operationID: operationID,
            reason: .stagingIOFailed,
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: failingOperations
        ))

        let retryOperations = RecordingRestoreActivationOperations(
            stagingParentURL: stagingParent
        )
        XCTAssertEqual(try RestoreSidecarStore.readStagingFailure(
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: retryOperations
        )?.operationID, operationID.uuidString.lowercased())
        XCTAssertTrue(retryOperations.events.contains(.synchronizeStagingParent))
    }

    // expected RED: acknowledging a recovery-required outcome removes its
    // durable freeze even though the marker and recovery operation tree remain.
    func testRecoveryOutcomeAcknowledgementPreservesDurableFreezeAndOperationTree() throws {
        let staged = try stage()
        let result = activate(operations: RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase, .replaceSafetyDatabase]
        ))
        XCTAssertEqual(result.status, .recoveryRequired)
        let outcomeURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        let outcomeData = try Data(contentsOf: outcomeURL)

        try RestoreSidecarStore.acknowledgeActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        )

        XCTAssertEqual(try Data(contentsOf: outcomeURL), outcomeData)
        XCTAssertEqual(
            try RestoreSidecarStore.readActivationOutcome(
                stagingRootDirectory: fixture.stagingRootDirectory
            )?.status,
            .recoveryRequired
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.operationDirectoryURL.path))
    }

    // expected RED: no bounded cleanup seam removes only the exact unclaimed
    // interrupted operation while preserving unrelated operation trees.
    func testInterruptedStagingCleanupRemovesOnlyExactUnclaimedOperation() throws {
        let interruptedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let unrelatedID = "44444444-4444-4444-4444-444444444444"
        let operationsDirectory = fixture.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let interruptedDirectory = operationsDirectory.appendingPathComponent(
            interruptedID.uuidString.lowercased(),
            isDirectory: true
        )
        let unrelatedDirectory = operationsDirectory.appendingPathComponent(
            unrelatedID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: interruptedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelatedDirectory,
            withIntermediateDirectories: true
        )

        let removed = try RestoreSidecarStore.cleanupInterruptedStagingOperation(
            operationID: interruptedID,
            stagingRootDirectory: fixture.stagingRootDirectory
        )

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }

    // expected RED: interrupted cleanup returns early when the child is already
    // absent, skipping the operations-directory sync still owed after unlink.
    func testInterruptedStagingCleanupRetriesOperationsSyncWhenTreeAlreadyAbsent() throws {
        let interruptedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let operationDirectory = fixture.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
            .appendingPathComponent(interruptedID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: true
        )
        let firstOperations = RecordingRestoreActivationOperations(
            failureCounts: [.synchronizeOperationsDirectory: 1]
        )

        XCTAssertThrowsError(try RestoreSidecarStore.cleanupInterruptedStagingOperation(
            operationID: interruptedID,
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: firstOperations
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationDirectory.path))

        let retryOperations = RecordingRestoreActivationOperations()
        XCTAssertTrue(try RestoreSidecarStore.cleanupInterruptedStagingOperation(
            operationID: interruptedID,
            stagingRootDirectory: fixture.stagingRootDirectory,
            fileManager: .default,
            operations: retryOperations
        ))
        XCTAssertEqual(
            retryOperations.events.filter { $0 == .synchronizeOperationsDirectory }.count,
            1
        )
    }

    // expected RED: interrupted cleanup has no durable claim check and can
    // remove an operation still owned by a pending marker or recovery outcome.
    func testInterruptedStagingCleanupPreservesMarkerAndRecoveryClaimedTrees() throws {
        let markerClaimed = try stage()
        let markerOperationID = try XCTUnwrap(UUID(uuidString: markerClaimed.intent.operationID))

        XCTAssertFalse(try RestoreSidecarStore.cleanupInterruptedStagingOperation(
            operationID: markerOperationID,
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerClaimed.operationDirectoryURL.path))

        let recovery = activate(operations: RecordingRestoreActivationOperations(
            failures: [.replaceSelectedDatabase, .replaceSafetyDatabase]
        ))
        XCTAssertEqual(recovery.status, .recoveryRequired)
        XCTAssertFalse(try RestoreSidecarStore.cleanupInterruptedStagingOperation(
            operationID: markerOperationID,
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerClaimed.operationDirectoryURL.path))
    }

    // T-RST-H07 expected RED: raw outcome decoding accepts a path-like snapshot
    // identifier even though the sidecar is documented as content-free.
    func testActivationOutcomeReadRejectsPathLikeSnapshotIdentifier() throws {
        try FileManager.default.createDirectory(
            at: fixture.stagingRootDirectory,
            withIntermediateDirectories: true
        )
        let outcomeURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        let unsafeOutcome = """
        {"schemaVersion":1,"operationID":"11111111-2222-3333-4444-555555555555","snapshotIdentifier":"/Users/private/client.sqlite","status":"activated","completedAt":"2024-09-23T00:00:00Z"}
        """
        try Data(unsafeOutcome.utf8).write(to: outcomeURL, options: .atomic)

        XCTAssertThrowsError(try RestoreSidecarStore.readActivationOutcome(
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
    }

    private func stage(
        currentBlobs: [RestoreTestBlob] = [],
        selectedBlobs: [RestoreTestBlob] = [],
        currentSentinel: String = "current canary",
        selectedSentinel: String = "selected canary"
    ) throws -> RestoreStagingResult {
        try fixture.writeLiveState(blobs: currentBlobs, sentinel: currentSentinel)
        _ = try fixture.writeCompleteSnapshot(
            blobs: selectedBlobs,
            sentinel: selectedSentinel
        )
        return try stageCandidate(knownMigrations: migrations)
    }

    private func stageCandidate(knownMigrations: [String]) throws -> RestoreStagingResult {
        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: knownMigrations
        ).first)
        return try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: knownMigrations
        )
    }

    private func activate(
        operations: RecordingRestoreActivationOperations,
        liveBlobsDirectory: URL? = nil,
        openDatabase: ((URL) throws -> SupraDatabase)? = nil
    ) -> RestoreActivationResult {
        RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(blobsDirectory: liveBlobsDirectory),
            knownMigrationIdentifiers: migrations,
            operations: operations,
            openDatabase: openDatabase ?? { url in
                let sentinel = try self.fixture.sentinel(in: url)
                operations.record(
                    sentinel == "selected canary" ? .openSelectedDatabase : .openSafetyDatabase
                )
                return try SupraDatabase.inMemory()
            }
        )
    }

    private func liveLayout(blobsDirectory: URL? = nil) -> RestoreLiveLayout {
        RestoreLiveLayout(
            databaseURL: fixture.liveDatabaseURL,
            blobsDirectory: blobsDirectory ?? fixture.liveBlobsDirectory,
            stagingRootDirectory: fixture.stagingRootDirectory
        )
    }
}

private enum ActivationTestError: Error {
    case selectedOpen
    case safetyOpen
    case markerSync
}

private final class RecordingRestoreActivationOperations: RestoreActivationFileOperations {
    enum Event: Equatable {
        case copySelectedDatabase
        case copySelectedBlob
        case replaceSelectedDatabase
        case openSelectedDatabase
        case copySafetyDatabase
        case copySafetyBlob
        case replaceSafetyDatabase
        case openSafetyDatabase
        case removeMarker
        case synchronizeMarkerDirectory
        case writeOutcome
        case removeOperationTree
        case synchronizeOperationsDirectory
        case synchronizeLiveBlobParent
        case synchronizeStagingParent
    }

    private let system = SystemRestoreActivationFileOperations()
    private let failures: Set<Event>
    private var remainingFailureCounts: [Event: Int]
    private let stagingParentURL: URL?
    private(set) var events: [Event] = []

    init(
        failures: Set<Event> = [],
        failureCounts: [Event: Int] = [:],
        stagingParentURL: URL? = nil
    ) {
        self.failures = failures
        self.remainingFailureCounts = failureCounts
        self.stagingParentURL = stagingParentURL?.standardizedFileURL
    }

    private func shouldFail(_ event: Event) -> Bool {
        if failures.contains(event) { return true }
        guard let remaining = remainingFailureCounts[event], remaining > 0 else { return false }
        remainingFailureCounts[event] = remaining - 1
        return true
    }

    func record(_ event: Event) {
        events.append(event)
    }

    func copyItem(from source: URL, to target: URL) throws {
        let event: Event
        if source.path.contains("/selected/blobs/") {
            event = .copySelectedBlob
        } else if source.path.contains("/safety/blobs/") {
            event = .copySafetyBlob
        } else if source.lastPathComponent == RestoreService.stagedDatabaseFileName {
            event = .copySelectedDatabase
        } else {
            event = .copySafetyDatabase
        }
        events.append(event)
        if shouldFail(event) { throw ActivationTestError.selectedOpen }
        try system.copyItem(from: source, to: target)
    }

    func synchronizeItem(at url: URL) throws {
        if let stagingParentURL, url.standardizedFileURL == stagingParentURL {
            events.append(.synchronizeStagingParent)
            if shouldFail(.synchronizeStagingParent) {
                throw ActivationTestError.markerSync
            }
        } else if url.lastPathComponent == "RestoreStaging" {
            events.append(.synchronizeMarkerDirectory)
            if shouldFail(.synchronizeMarkerDirectory) {
                throw ActivationTestError.markerSync
            }
        } else if url.lastPathComponent == "operations" {
            events.append(.synchronizeOperationsDirectory)
            if shouldFail(.synchronizeOperationsDirectory) {
                throw ActivationTestError.markerSync
            }
        } else if url.lastPathComponent == "Live",
                  !events.contains(.replaceSelectedDatabase),
                  !events.contains(.replaceSafetyDatabase) {
            events.append(.synchronizeLiveBlobParent)
            if shouldFail(.synchronizeLiveBlobParent) {
                throw ActivationTestError.markerSync
            }
        }
        try system.synchronizeItem(at: url)
    }

    func atomicallyReplaceItem(at destination: URL, withItemAt prepared: URL) throws {
        let event: Event = prepared.lastPathComponent.contains(".rollback-")
            ? .replaceSafetyDatabase
            : .replaceSelectedDatabase
        events.append(event)
        if shouldFail(event) { throw ActivationTestError.selectedOpen }
        try system.atomicallyReplaceItem(at: destination, withItemAt: prepared)
    }

    func removeItem(at url: URL) throws {
        if url.lastPathComponent == RestoreIntent.pendingFileName {
            events.append(.removeMarker)
            if shouldFail(.removeMarker) { throw ActivationTestError.selectedOpen }
        } else if url.deletingLastPathComponent().lastPathComponent == "operations" {
            events.append(.removeOperationTree)
            if shouldFail(.removeOperationTree) { throw ActivationTestError.selectedOpen }
        }
        try system.removeItem(at: url)
    }

    func writeOutcomeAtomically(_ data: Data, to url: URL) throws {
        events.append(.writeOutcome)
        if shouldFail(.writeOutcome) { throw ActivationTestError.markerSync }
        try SystemRestoreFileOperations().writeIntentAtomically(data, to: url)
    }
}
