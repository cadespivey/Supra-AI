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
            try String(contentsOf: result.safetyBlobsDirectory.appendingPathComponent("aa/current.bin")),
            "CURRENT BLOB"
        )
        XCTAssertEqual(result.intent.safetyBlobCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markerURL.path))
    }

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
        XCTAssertEqual(
            try String(contentsOf: result.stagedBlobsDirectory.appendingPathComponent("bb/selected.bin")),
            "SELECTED BLOB"
        )
        XCTAssertEqual(try fixture.sentinel(in: fixture.liveDatabaseURL), "current row")
        XCTAssertEqual(try fixture.fingerprint(fixture.liveDatabaseURL), liveFingerprint)
        XCTAssertEqual(try fixture.fingerprint(pair.snapshot), sourceFingerprint)
    }

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
        XCTAssertEqual(result.intent.schemaVersion, 1)
        XCTAssertEqual(result.intent.selectedBlobCount, 1)
        let markerText = try String(contentsOf: result.markerURL, encoding: .utf8)
        XCTAssertFalse(markerText.contains(fixture.root.path))
        XCTAssertFalse(markerText.contains(fixture.backupDirectory.path))
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
    }

    enum Event: Equatable {
        case createSafetyDatabase
        case synchronizeSafetyDatabase
        case copySafetyBlob
        case synchronizeSafetyBlob
        case moveSafetyTree
        case copySelectedDatabase
        case synchronizeSelectedDatabase
        case copySelectedBlob
        case synchronizeSelectedBlob
        case moveSelectedTree
        case synchronizeOperationDirectory
        case writeMarker
    }

    private let system = SystemRestoreFileOperations()
    private let failurePoint: FailurePoint?
    private(set) var events: [Event] = []
    private(set) var markerObservedCompleteTrees = false

    init(failurePoint: FailurePoint? = nil) {
        self.failurePoint = failurePoint
    }

    func createDatabaseSnapshot(from source: URL, to target: URL) throws {
        events.append(.createSafetyDatabase)
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
        if url.lastPathComponent == RestoreService.safetyDatabaseFileName {
            event = .synchronizeSafetyDatabase
        } else if url.lastPathComponent == RestoreService.stagedDatabaseFileName {
            event = .synchronizeSelectedDatabase
        } else if url.path.contains("/safety.tmp/") {
            event = .synchronizeSafetyBlob
        } else if url.path.contains("/selected.tmp/") {
            event = .synchronizeSelectedBlob
        } else {
            event = .synchronizeOperationDirectory
        }
        events.append(event)
        if failurePoint == .selectedDatabaseSynchronization,
           event == .synchronizeSelectedDatabase {
            throw InjectedRestoreFailure.requested(.selectedDatabaseSynchronization)
        }
        try system.synchronizeItem(at: url)
    }

    func writeIntentAtomically(_ data: Data, to url: URL) throws {
        events.append(.writeMarker)
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
        if failurePoint == .markerWrite { throw InjectedRestoreFailure.requested(.markerWrite) }
        try system.writeIntentAtomically(data, to: url)
    }
}
