import Foundation
import GRDB
import XCTest
@testable import SupraStore

final class RestoreServiceTests: XCTestCase {
    private var fixture: RestoreTestFixture!
    private let migrations = ["m1", "m2"]

    override func setUpWithError() throws {
        fixture = try RestoreTestFixture()
    }

    override func tearDownWithError() throws {
        fixture.remove()
        fixture = nil
    }

    // T-RST-H01 expected RED: the public staging entry point accepts only a
    // layout, so a caller can stage while the app's live writer remains open.
    // The replacement API must bind the exact on-disk SupraDatabase, close it,
    // and preserve the caller's operation UUID before core staging begins.
    func testQuiescedStageClosesExactWriterBeforeSafetySnapshotAndUsesCallerOperationID() throws {
        try fixture.writeShippingLiveState(sentinel: "current canary")
        _ = try fixture.writeCompleteShippingSnapshot(sentinel: "selected canary")
        let candidate = try shippingCandidate()
        let liveDatabase = try SupraDatabase(url: fixture.liveDatabaseURL)
        let operationID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        var observedClosedWriter = false
        let operations = RecordingRestoreFileOperations(
            safetySnapshotProbe: {
                XCTAssertThrowsError(try liveDatabase.writer.read { _ in () })
                observedClosedWriter = true
            }
        )

        let result = try RestoreService.stageQuiescedRestore(
            candidate: candidate,
            liveDatabase: liveDatabase,
            liveLayout: liveLayout(),
            operationID: operationID,
            knownMigrationIdentifiers: SupraMigrator.makeMigrator().migrations,
            operations: operations
        )

        XCTAssertTrue(observedClosedWriter, "the safety snapshot seam must execute after close")
        XCTAssertEqual(result.intent.operationID, operationID.uuidString.lowercased())
        XCTAssertThrowsError(try liveDatabase.writer.read { _ in () })
    }

    // T-RST-H02 expected RED: core staging cannot currently prove that the
    // writer it is about to close owns RestoreLiveLayout.databaseURL.
    func testQuiescedStageRejectsDifferentCanonicalDatabaseWithoutClosingWriter() throws {
        try fixture.writeShippingLiveState(sentinel: "current canary")
        _ = try fixture.writeCompleteShippingSnapshot(sentinel: "selected canary")
        let candidate = try shippingCandidate()
        let liveDatabase = try SupraDatabase(url: fixture.liveDatabaseURL)
        let mismatchedLayout = RestoreLiveLayout(
            databaseURL: fixture.root.appendingPathComponent("different.sqlite"),
            blobsDirectory: fixture.liveBlobsDirectory,
            stagingRootDirectory: fixture.stagingRootDirectory
        )

        XCTAssertThrowsError(try RestoreService.stageQuiescedRestore(
            candidate: candidate,
            liveDatabase: liveDatabase,
            liveLayout: mismatchedLayout,
            operationID: UUID(),
            knownMigrationIdentifiers: SupraMigrator.makeMigrator().migrations
        )) { error in
            XCTAssertEqual(error as? RestoreStageError, .liveDatabasePathMismatch)
        }

        XCTAssertNoThrow(try liveDatabase.writer.read { _ in () })
        try liveDatabase.writer.close()
    }

    // T-RST-H03 expected RED: once the live writer is closed, staging failures
    // have no durable database-independent handoff or acknowledgement API.
    func testStagingFailureSidecarIsContentFreeReadableAndAcknowledgedDurably() throws {
        let operationID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let failedAt = Date(timeIntervalSince1970: 1_727_000_000)

        let written = try RestoreSidecarStore.recordStagingFailure(
            operationID: operationID,
            reason: .liveStateInvalid,
            stagingRootDirectory: fixture.stagingRootDirectory,
            failedAt: failedAt
        )

        XCTAssertEqual(written.operationID, operationID.uuidString.lowercased())
        XCTAssertEqual(written.reason, .liveStateInvalid)
        XCTAssertEqual(
            try RestoreSidecarStore.readStagingFailure(
                stagingRootDirectory: fixture.stagingRootDirectory
            ),
            written
        )
        let sidecarURL = fixture.stagingRootDirectory
            .appendingPathComponent(RestoreStagingFailureRecord.lastFailureFileName)
        let serialized = try XCTUnwrap(String(data: Data(contentsOf: sidecarURL), encoding: .utf8))
        XCTAssertFalse(serialized.contains(fixture.root.path))
        XCTAssertFalse(serialized.contains("current canary"))

        try RestoreSidecarStore.acknowledgeStagingFailure(
            stagingRootDirectory: fixture.stagingRootDirectory
        )

        XCTAssertNil(try RestoreSidecarStore.readStagingFailure(
            stagingRootDirectory: fixture.stagingRootDirectory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // T-RST-10...12 expected RED: RestoreService has no safety capture,
    // selected staging tree, durable marker, or ordering seam.
    func testStageCapturesVerifiedCurrentDatabaseAndReferencedBlobs() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        try fixture.writeLiveState(blobs: [currentBlob], sentinel: "current row")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try fixture.writeCompleteSnapshot(blobs: [selectedBlob], sentinel: "selected row")
        let candidate = try compatibleCandidate()

        let result = try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations
        )

        XCTAssertEqual(try fixture.sentinel(in: result.safetyDatabaseURL), "current row")
        XCTAssertEqual(
            try String(
                contentsOf: result.safetyBlobsDirectory.appendingPathComponent("aa/current.bin"),
                encoding: .utf8
            ),
            "CURRENT BLOB"
        )
        XCTAssertEqual(result.intent.safetyBlobCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markerURL.path))
    }

    // Expected RED: selected-state staging and source/live immutability are not implemented.
    func testStageCopiesSelectedStateWithoutMutatingLiveOrBackupSource() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        try fixture.writeLiveState(blobs: [currentBlob], sentinel: "current row")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        let pair = try fixture.writeCompleteSnapshot(blobs: [selectedBlob], sentinel: "selected row")
        let sourceFingerprint = try fixture.fingerprint(pair.snapshot)
        let liveFingerprint = try fixture.fingerprint(fixture.liveDatabaseURL)
        let candidate = try compatibleCandidate()

        let result = try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations
        )

        XCTAssertEqual(try fixture.sentinel(in: result.stagedDatabaseURL), "selected row")
        XCTAssertEqual(result.intent.stagedDatabaseSHA256, sourceFingerprint)
        XCTAssertEqual(
            try String(
                contentsOf: result.stagedBlobsDirectory.appendingPathComponent("bb/selected.bin"),
                encoding: .utf8
            ),
            "SELECTED BLOB"
        )
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current row")
        XCTAssertEqual(try fixture.fingerprint(fixture.liveDatabaseURL), liveFingerprint)
        XCTAssertEqual(try fixture.fingerprint(pair.snapshot), sourceFingerprint)
    }

    func testStageRejectsSnapshotReplacedAfterSelection() throws {
        try fixture.writeLiveState(sentinel: "current row")
        let original = try fixture.writeCompleteSnapshot(sentinel: "original selected row")
        let candidate = try compatibleCandidate()
        try FileManager.default.removeItem(at: original.snapshot)
        try FileManager.default.removeItem(at: original.manifest)
        _ = try fixture.writeCompleteSnapshot(sentinel: "replacement selected row")

        XCTAssertThrowsError(try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations
        )) { error in
            XCTAssertEqual(error as? RestoreStageError, .sourceSnapshotChanged)
        }

        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current row")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.stagingRootDirectory
                .appendingPathComponent(RestoreIntent.pendingFileName).path
        ))
    }

    // Expected RED: there is no marker-last, content-free staging handoff.
    func testIntentMarkerIsLastAndContainsNoAbsoluteSourcePaths() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        try fixture.writeLiveState(blobs: [currentBlob])
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try fixture.writeCompleteSnapshot(blobs: [selectedBlob])
        let candidate = try compatibleCandidate()
        let operations = RecordingRestoreFileOperations()

        let result = try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        )

        XCTAssertEqual(operations.events.last, .writeMarker)
        XCTAssertTrue(operations.markerObservedCompleteTrees)
        let safetyTreeSync = try XCTUnwrap(operations.events.lastIndex(of: .synchronizeSafetyTree))
        let safetyMove = try XCTUnwrap(operations.events.firstIndex(of: .moveSafetyTree))
        let selectedTreeSync = try XCTUnwrap(operations.events.lastIndex(of: .synchronizeSelectedTree))
        let selectedMove = try XCTUnwrap(operations.events.firstIndex(of: .moveSelectedTree))
        let operationDirectorySyncs = operations.events.indices.filter {
            operations.events[$0] == .synchronizeOperationDirectory
        }
        XCTAssertLessThan(safetyTreeSync, safetyMove)
        XCTAssertTrue(operationDirectorySyncs.contains { $0 > safetyMove && $0 < selectedTreeSync })
        XCTAssertLessThan(selectedTreeSync, selectedMove)
        XCTAssertTrue(operationDirectorySyncs.contains { $0 > selectedMove })
        XCTAssertEqual(
            Array(operations.events.suffix(3)),
            [.synchronizeOperationsRoot, .synchronizeStagingRoot, .writeMarker]
        )
        XCTAssertEqual(result.intent.schemaVersion, 1)
        XCTAssertEqual(result.intent.selectedBlobCount, 1)
        XCTAssertEqual(
            try RestoreIntent.decode(Data(contentsOf: result.markerURL)),
            result.intent
        )
        let markerText = try String(contentsOf: result.markerURL, encoding: .utf8)
        XCTAssertFalse(markerText.contains(fixture.root.path))
        XCTAssertFalse(markerText.contains(fixture.backupDirectory.path))
    }

    func testStagePersistsMatchingOperationIntentBeforePendingMarker() throws {
        try fixture.writeLiveState(sentinel: "current row")
        _ = try fixture.writeCompleteSnapshot(sentinel: "selected row")
        let operations = RecordingRestoreFileOperations()

        let result = try RestoreService.stageRestore(
            candidate: compatibleCandidate(),
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        )

        let operationIntentURL = result.operationDirectoryURL
            .appendingPathComponent(RestoreIntent.operationFileName)
        XCTAssertEqual(
            try Data(contentsOf: operationIntentURL),
            try Data(contentsOf: result.markerURL)
        )
        XCTAssertLessThan(
            try XCTUnwrap(operations.events.firstIndex(of: .writeOperationIntent)),
            try XCTUnwrap(operations.events.firstIndex(of: .writeMarker))
        )
    }

    // T-RST-13 expected RED: a failed safety database capture has no bounded
    // cleanup contract and no marker-last guarantee.
    func testSafetyDatabaseFailureRetainsLiveStateAndWritesNoMarker() throws {
        try assertInjectedFailure(.safetyDatabase)
    }

    // T-RST-14 expected RED: a partial safety blob copy can be mistaken for a
    // complete safety snapshot.
    func testSafetyBlobFailureRetainsLiveStateAndWritesNoMarker() throws {
        try assertInjectedFailure(.safetyBlob)
    }

    // T-RST-15 expected RED: a selected database copy failure is not isolated
    // from the live layout.
    func testSelectedDatabaseFailureRetainsLiveStateAndWritesNoMarker() throws {
        try assertInjectedFailure(.selectedDatabase)
    }

    // T-RST-16 expected RED: a selected blob copy failure has no fail-closed
    // staging boundary.
    func testSelectedBlobFailureRetainsLiveStateAndWritesNoMarker() throws {
        try assertInjectedFailure(.selectedBlob)
    }

    // T-RST-17 expected RED: durability failure can currently have no typed
    // stage result because the staging engine does not exist.
    func testSelectedDatabaseSynchronizationFailureWritesNoMarker() throws {
        try assertInjectedFailure(.selectedDatabaseSynchronization)
    }

    // T-RST-18 expected RED: marker publication is not injectable and cannot be
    // proven to leave the original state exact on failure.
    func testMarkerWriteFailureRetainsLiveStateAndCleansOnlyItsOperation() throws {
        try assertInjectedFailure(.markerWrite)
    }

    // T-RST-18: a marker writer may make the atomic rename visible and then
    // report a durability failure. Cleanup must synchronize both directory
    // mutations so a crash cannot resurrect either the pending marker or the
    // failed operation tree after the caller was told staging failed.
    func testMarkerWriteFailureDurablyPublishesCleanup() throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        try fixture.writeLiveState(blobs: [currentBlob], sentinel: "current row")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try fixture.writeCompleteSnapshot(blobs: [selectedBlob], sentinel: "selected row")
        let candidate = try compatibleCandidate()
        let operations = RecordingRestoreFileOperations(failurePoint: .markerWrite)

        XCTAssertThrowsError(try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        ))

        let markerFailure = try XCTUnwrap(operations.events.lastIndex(of: .writeMarker))
        XCTAssertEqual(
            Array(operations.events.suffix(from: operations.events.index(after: markerFailure))),
            [.synchronizeStagingRoot, .synchronizeOperationsRoot]
        )
    }

    func testMarkerCleanupFailurePreservesOperationUntilUnlinkIsDurable() throws {
        try fixture.writeLiveState(sentinel: "current row")
        _ = try fixture.writeCompleteSnapshot(sentinel: "selected row")
        let operations = RecordingRestoreFileOperations(
            failurePoint: .markerWriteAndCompensatingDirectorySynchronization
        )

        XCTAssertThrowsError(try RestoreService.stageRestore(
            candidate: compatibleCandidate(),
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        ))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.stagingRootDirectory
                .appendingPathComponent(RestoreIntent.pendingFileName).path
        ))
        let operationsDirectory = fixture.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: operationsDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: leftovers[0].appendingPathComponent(RestoreIntent.operationFileName).path
        ))
    }

    func testFirstUseStagingRootPublishesParentBeforeMarker() throws {
        try fixture.writeLiveState(sentinel: "current row")
        _ = try fixture.writeCompleteSnapshot(sentinel: "selected row")
        let operations = RecordingRestoreFileOperations()

        _ = try RestoreService.stageRestore(
            candidate: compatibleCandidate(),
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        )

        XCTAssertLessThan(
            try XCTUnwrap(operations.events.firstIndex(of: .synchronizeStagingParent)),
            try XCTUnwrap(operations.events.firstIndex(of: .writeMarker))
        )
    }

    func testFirstUseStagingParentSyncFailurePublishesNoMarker() throws {
        try fixture.writeLiveState(sentinel: "current row")
        _ = try fixture.writeCompleteSnapshot(sentinel: "selected row")
        let operations = RecordingRestoreFileOperations(
            failurePoint: .stagingRootParentSynchronization
        )

        XCTAssertThrowsError(try RestoreService.stageRestore(
            candidate: compatibleCandidate(),
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        )) { error in
            XCTAssertEqual(
                error as? InjectedRestoreFailure,
                .requested(.stagingRootParentSynchronization)
            )
        }
        XCTAssertFalse(operations.events.contains(.writeMarker))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.stagingRootDirectory
                .appendingPathComponent(RestoreIntent.pendingFileName).path
        ))
    }

    private func assertInjectedFailure(_ point: RecordingRestoreFileOperations.FailurePoint) throws {
        let currentBlob = RestoreTestBlob("aa/current.bin", "CURRENT BLOB")
        try fixture.writeLiveState(blobs: [currentBlob], sentinel: "current row")
        let selectedBlob = RestoreTestBlob("bb/selected.bin", "SELECTED BLOB")
        _ = try fixture.writeCompleteSnapshot(blobs: [selectedBlob], sentinel: "selected row")
        let candidate = try compatibleCandidate()
        let databaseFingerprint = try fixture.fingerprint(fixture.liveDatabaseURL)
        let blobFingerprint = try fixture.fingerprint(
            fixture.liveBlobsDirectory.appendingPathComponent("aa/current.bin")
        )
        let operations = RecordingRestoreFileOperations(failurePoint: point)

        XCTAssertThrowsError(try RestoreService.stageRestore(
            candidate: candidate,
            liveLayout: liveLayout(),
            knownMigrationIdentifiers: migrations,
            operations: operations
        )) { error in
            XCTAssertEqual(error as? InjectedRestoreFailure, .requested(point))
        }

        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current row")
        XCTAssertEqual(try fixture.fingerprint(fixture.liveDatabaseURL), databaseFingerprint)
        XCTAssertEqual(
            try fixture.fingerprint(fixture.liveBlobsDirectory.appendingPathComponent("aa/current.bin")),
            blobFingerprint
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.stagingRootDirectory
                .appendingPathComponent(RestoreIntent.pendingFileName).path
        ))
        let operationsDirectory = fixture.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: operationsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "only the failed operation's bounded directory may be cleaned")
    }

    private func compatibleCandidate() throws -> RestoreSnapshotCandidate {
        try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: migrations
        ).first)
    }

    private func shippingCandidate() throws -> RestoreSnapshotCandidate {
        try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: SupraMigrator.makeMigrator().migrations
        ).first)
    }

    private func liveLayout() -> RestoreLiveLayout {
        RestoreLiveLayout(
            databaseURL: fixture.liveDatabaseURL,
            blobsDirectory: fixture.liveBlobsDirectory,
            stagingRootDirectory: fixture.stagingRootDirectory
        )
    }
}

private enum InjectedRestoreFailure: Error, Equatable {
    case requested(RecordingRestoreFileOperations.FailurePoint)
}

private final class RecordingRestoreFileOperations: RestoreFileOperations {
    enum FailurePoint: Equatable {
        case safetyDatabase
        case safetyBlob
        case selectedDatabase
        case selectedBlob
        case selectedDatabaseSynchronization
        case markerWrite
        case markerWriteAndCompensatingDirectorySynchronization
        case stagingRootParentSynchronization
    }

    enum Event: Equatable {
        case createSafetyDatabase
        case synchronizeSafetyDatabase
        case copySafetyBlob
        case synchronizeSafetyBlob
        case synchronizeSafetyTree
        case moveSafetyTree
        case copySelectedDatabase
        case synchronizeSelectedDatabase
        case copySelectedBlob
        case synchronizeSelectedBlob
        case synchronizeSelectedTree
        case moveSelectedTree
        case synchronizeOperationDirectory
        case synchronizeOperationsRoot
        case synchronizeStagingRoot
        case synchronizeStagingParent
        case writeOperationIntent
        case writeMarker
    }

    private let system = SystemRestoreFileOperations()
    private let failurePoint: FailurePoint?
    private let safetySnapshotProbe: (() throws -> Void)?
    private(set) var events: [Event] = []
    private(set) var markerObservedCompleteTrees = false

    init(
        failurePoint: FailurePoint? = nil,
        safetySnapshotProbe: (() throws -> Void)? = nil
    ) {
        self.failurePoint = failurePoint
        self.safetySnapshotProbe = safetySnapshotProbe
    }

    func createDatabaseSnapshot(from source: URL, to target: URL) throws {
        events.append(.createSafetyDatabase)
        try safetySnapshotProbe?()
        if failurePoint == .safetyDatabase { throw InjectedRestoreFailure.requested(.safetyDatabase) }
        try system.createDatabaseSnapshot(from: source, to: target)
    }

    func copyItem(from source: URL, to target: URL) throws {
        let event: Event
        let point: FailurePoint
        if target.path.contains("/safety.tmp/") {
            event = .copySafetyBlob
            point = .safetyBlob
        } else if target.lastPathComponent == RestoreService.stagedDatabaseFileName {
            event = .copySelectedDatabase
            point = .selectedDatabase
        } else {
            event = .copySelectedBlob
            point = .selectedBlob
        }
        events.append(event)
        if failurePoint == point { throw InjectedRestoreFailure.requested(point) }
        try system.copyItem(from: source, to: target)
    }

    func moveItem(from source: URL, to target: URL) throws {
        events.append(target.lastPathComponent == "safety" ? .moveSafetyTree : .moveSelectedTree)
        try system.moveItem(from: source, to: target)
    }

    func synchronizeItem(at url: URL) throws {
        let event: Event
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        if url.lastPathComponent == RestoreService.safetyDatabaseFileName {
            event = .synchronizeSafetyDatabase
        } else if url.lastPathComponent == RestoreService.stagedDatabaseFileName {
            event = .synchronizeSelectedDatabase
        } else if directory, url.path.contains("/safety.tmp") {
            event = .synchronizeSafetyTree
        } else if directory, url.path.contains("/selected.tmp") {
            event = .synchronizeSelectedTree
        } else if url.lastPathComponent == "operations" {
            event = .synchronizeOperationsRoot
        } else if url.lastPathComponent == "RestoreStaging" {
            event = .synchronizeStagingRoot
        } else if FileManager.default.fileExists(
            atPath: url.appendingPathComponent(
                RestoreService.stagingDirectoryName,
                isDirectory: true
            ).path
        ) {
            event = .synchronizeStagingParent
        } else if url.path.contains("/safety.tmp/") {
            event = .synchronizeSafetyBlob
        } else if url.path.contains("/selected.tmp/") {
            event = .synchronizeSelectedBlob
        } else {
            event = .synchronizeOperationDirectory
        }
        events.append(event)
        if failurePoint == .markerWriteAndCompensatingDirectorySynchronization,
           event == .synchronizeStagingRoot,
           events.contains(.writeMarker) {
            throw InjectedRestoreFailure.requested(
                .markerWriteAndCompensatingDirectorySynchronization
            )
        }
        if failurePoint == .stagingRootParentSynchronization,
           event == .synchronizeStagingParent {
            throw InjectedRestoreFailure.requested(.stagingRootParentSynchronization)
        }
        if failurePoint == .selectedDatabaseSynchronization,
           event == .synchronizeSelectedDatabase {
            throw InjectedRestoreFailure.requested(.selectedDatabaseSynchronization)
        }
        try system.synchronizeItem(at: url)
    }

    func writeIntentAtomically(_ data: Data, to url: URL) throws {
        let isOperationIntent = url.lastPathComponent == RestoreIntent.operationFileName
        events.append(isOperationIntent ? .writeOperationIntent : .writeMarker)
        if isOperationIntent {
            try system.writeIntentAtomically(data, to: url)
            return
        }
        let operationDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("operations", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: operationDirectory, includingPropertiesForKeys: nil
        )) ?? []
        markerObservedCompleteTrees = entries.count == 1
            && FileManager.default.fileExists(
                atPath: entries[0].appendingPathComponent("safety", isDirectory: true).path
            )
            && FileManager.default.fileExists(
                atPath: entries[0].appendingPathComponent("selected", isDirectory: true).path
            )
            && !FileManager.default.fileExists(atPath: url.path)
        if failurePoint == .markerWrite
            || failurePoint == .markerWriteAndCompensatingDirectorySynchronization {
            try system.writeIntentAtomically(data, to: url)
            throw InjectedRestoreFailure.requested(failurePoint!)
        }
        try system.writeIntentAtomically(data, to: url)
    }
}
