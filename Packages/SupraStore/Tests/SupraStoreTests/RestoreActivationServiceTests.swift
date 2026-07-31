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

    // T-RST-20/T-RST-38: selected managed blobs install at cold start while
    // unrelated live content remains untouched.
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

    // T-RST-22/T-RST-41: a consumed marker makes every later launch a no-op.
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
        XCTAssertEqual(result.recoveryDatabaseURL, staged.safetyDatabaseURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.markerURL.path))
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
        XCTAssertEqual(result.recoveryDatabaseURL, staged.safetyDatabaseURL)
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
        XCTAssertNil(result.recoveryDatabaseURL)
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
    }

    // T-RST-40...42 expected RED: the launch service has no durable,
    // content-free outcome record whose bytes remain stable on a second launch.
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
        let outcomeURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        let firstOutcomeData = try Data(contentsOf: outcomeURL)
        let outcome = try RestoreOutcomeRecord.decode(firstOutcomeData)
        XCTAssertEqual(outcome.schemaVersion, RestoreOutcomeRecord.currentSchemaVersion)
        XCTAssertEqual(outcome.status, .activated)
        XCTAssertEqual(outcome.operationID, staged.intent.operationID)
        XCTAssertEqual(outcome.snapshotIdentifier, staged.intent.selectedSnapshotIdentifier)
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
        openDatabase: ((URL) throws -> SupraDatabase)? = nil
    ) -> RestoreActivationResult {
        RestoreActivationService.activatePendingRestore(
            liveLayout: liveLayout(),
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

    private func liveLayout() -> RestoreLiveLayout {
        RestoreLiveLayout(
            databaseURL: fixture.liveDatabaseURL,
            blobsDirectory: fixture.liveBlobsDirectory,
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
    }

    private let system = SystemRestoreActivationFileOperations()
    private let failures: Set<Event>
    private(set) var events: [Event] = []

    init(failures: Set<Event> = []) {
        self.failures = failures
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
        if failures.contains(event) { throw ActivationTestError.selectedOpen }
        try system.copyItem(from: source, to: target)
    }

    func synchronizeItem(at url: URL) throws {
        if url.lastPathComponent == "RestoreStaging" {
            events.append(.synchronizeMarkerDirectory)
            if failures.contains(.synchronizeMarkerDirectory) {
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
        if failures.contains(event) { throw ActivationTestError.selectedOpen }
        try system.atomicallyReplaceItem(at: destination, withItemAt: prepared)
    }

    func removeItem(at url: URL) throws {
        if url.lastPathComponent == RestoreIntent.pendingFileName {
            events.append(.removeMarker)
            if failures.contains(.removeMarker) { throw ActivationTestError.selectedOpen }
        }
        try system.removeItem(at: url)
    }
}
