import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

/// P2 backup destination + scheduling gates (plan I8).
///
/// Expected RED for this file: `BackupController`, `BackupDestination`,
/// `SecurityScopedBackupDestination`, and their value types do not exist yet,
/// so the test target fails to compile before production code is added.
@MainActor
final class BackupControllerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_788_969_600) // 2026-09-09T00:00:00Z

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SupraStore(url: directory.appendingPathComponent("SupraAI.sqlite"))
    }

    private func makeController(
        store: SupraStore,
        clock: TestClock,
        destination: FakeBackupDestination,
        runner: @escaping BackupController.BackupRunner,
        sourceBytes: Int64 = 1_024
    ) -> BackupController {
        BackupController(
            store: store,
            blobsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-blobs", isDirectory: true),
            appVersion: "9.8.7",
            appBuild: "654",
            destinationFactory: { data in
                destination.receivedBookmarkData = data
                return destination
            },
            backupRunner: runner,
            sourceSizeProvider: { sourceBytes },
            now: { clock.now }
        )
    }

    // MARK: - T-P2-DEST-01: security scope is load-bearing (I8 wire-proof)

    func testBackupRunsInsideResolvedDestinationAccessAndPersistsSuccess() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Volumes/Encrypted Legal Archive", isDirectory: true)
        let destination = FakeBackupDestination(url: destinationURL)
        var runnerURLs: [URL] = []
        let controller = makeController(
            store: store,
            clock: clock,
            destination: destination,
            runner: { url in
                guard destination.isAccessing else { throw TestFailure.runnerEscapedScope }
                runnerURLs.append(url)
                return BackupRunSummary(
                    snapshotBytes: 8_765_432,
                    copiedBlobCount: 7,
                    referencedBlobCount: 11
                )
            }
        )
        let bookmark = Data([0xA1, 0xB2, 0xC3])
        XCTAssertTrue(controller.configureDestination(bookmarkData: bookmark, url: destinationURL))

        let didBackUp = await controller.backUpNow()
        XCTAssertTrue(didBackUp)

        XCTAssertEqual(destination.accessCount, 1)
        XCTAssertFalse(destination.isAccessing, "security scope must be released after the run")
        XCTAssertEqual(destination.receivedBookmarkData, bookmark)
        XCTAssertEqual(runnerURLs, [destinationURL])
        XCTAssertEqual(controller.state, .succeeded)
        XCTAssertEqual(controller.configuration?.lastSuccessAt, baseDate)
        XCTAssertEqual(controller.configuration?.lastSnapshotBytes, 8_765_432)
        XCTAssertEqual(controller.configuration?.lastCopiedBlobCount, 7)
        XCTAssertEqual(controller.configuration?.lastReferencedBlobCount, 11)
        XCTAssertNil(controller.configuration?.lastErrorDescription)

        let stored = try store.appSettings.getSetting(
            BackupController.storageKey, as: BackupConfiguration.self
        )
        XCTAssertEqual(stored, controller.configuration)
    }

    // MARK: - T-P2-DEST-02: no destination is never a silent skip

    func testManualBackupWithoutDestinationSurfacesConfigurationPrompt() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destination = FakeBackupDestination(url: URL(fileURLWithPath: "/unused"))
        var runCount = 0
        let controller = makeController(
            store: store,
            clock: clock,
            destination: destination,
            runner: { _ in
                runCount += 1
                return BackupRunSummary(snapshotBytes: 1, copiedBlobCount: 0, referencedBlobCount: 0)
            }
        )

        let didBackUp = await controller.backUpNow()
        XCTAssertFalse(didBackUp)

        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertEqual(controller.statusMessage, "Choose a backup folder to get started.")
    }

    // MARK: - T-P2-DEST-03: stale bookmark -> explicit re-pick

    func testStaleBookmarkRequiresRepickAndNeverInvokesRunner() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Supra Backups")
        let destination = FakeBackupDestination(url: destinationURL, failure: .staleBookmark)
        var runCount = 0
        let controller = makeController(
            store: store,
            clock: clock,
            destination: destination,
            runner: { _ in
                runCount += 1
                return BackupRunSummary(snapshotBytes: 1, copiedBlobCount: 0, referencedBlobCount: 0)
            }
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x01]), url: destinationURL))

        let didBackUp = await controller.backUpNow()
        XCTAssertFalse(didBackUp)

        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(controller.state, .needsDestinationRepick)
        XCTAssertTrue(controller.configuration?.requiresDestinationRepick == true)
        XCTAssertNotNil(controller.configuration?.lastErrorDescription)
        let reloaded = makeController(
            store: store, clock: clock, destination: destination,
            runner: { _ in throw TestFailure.runnerShouldNotRun }
        )
        XCTAssertEqual(reloaded.state, .needsDestinationRepick)
    }

    // MARK: - T-P2-CONFIG-01: bookmark metadata survives relaunch

    func testConfiguredDestinationPersistsAndReplacementClearsOldRunMetadata() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let firstURL = URL(fileURLWithPath: "/Volumes/First Backup", isDirectory: true)
        let destination = FakeBackupDestination(url: firstURL)
        let runner: BackupController.BackupRunner = { _ in
            BackupRunSummary(snapshotBytes: 55, copiedBlobCount: 2, referencedBlobCount: 3)
        }
        let controller = makeController(
            store: store, clock: clock, destination: destination, runner: runner
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x11]), url: firstURL))
        let firstBackupSucceeded = await controller.backUpNow()
        XCTAssertTrue(firstBackupSucceeded)
        XCTAssertNotNil(controller.configuration?.lastSuccessAt)

        let cloudURL = URL(fileURLWithPath:
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Supra AI Backups",
            isDirectory: true
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x22]), url: cloudURL))

        XCTAssertEqual(controller.configuration?.destinationPath, cloudURL.path)
        XCTAssertEqual(controller.configuration?.bookmarkData, Data([0x22]))
        XCTAssertTrue(controller.configuration?.isICloudDrive == true)
        XCTAssertNil(controller.configuration?.lastSuccessAt, "a new folder has no successful backup yet")
        XCTAssertNil(controller.configuration?.lastSnapshotBytes)
        let reloaded = makeController(
            store: store, clock: clock, destination: destination, runner: runner
        )
        XCTAssertEqual(reloaded.configuration, controller.configuration)
        XCTAssertEqual(reloaded.state, .ready)
    }

    // MARK: - T-P2-SCHED-01/02: exact 24-hour on-launch threshold

    func testLaunchBackupRunsAtExactlyTwentyFourHours() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        let destination = FakeBackupDestination(url: destinationURL)
        var runCount = 0
        let runner: BackupController.BackupRunner = { _ in
            runCount += 1
            return BackupRunSummary(snapshotBytes: 9, copiedBlobCount: 0, referencedBlobCount: 1)
        }
        let controller = makeController(
            store: store, clock: clock, destination: destination, runner: runner
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x33]), url: destinationURL))
        let firstBackupSucceeded = await controller.backUpNow()
        XCTAssertTrue(firstBackupSucceeded)
        XCTAssertEqual(runCount, 1)

        clock.now = baseDate.addingTimeInterval(BackupController.staleInterval)
        let launchOutcome = await controller.backUpOnLaunchIfStale()
        XCTAssertEqual(launchOutcome, .completed)

        XCTAssertEqual(runCount, 2)
        XCTAssertEqual(controller.configuration?.lastSuccessAt, clock.now)
    }

    func testLaunchBackupSkipsAtTwentyFourHoursMinusOneSecond() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        let destination = FakeBackupDestination(url: destinationURL)
        var runCount = 0
        let runner: BackupController.BackupRunner = { _ in
            runCount += 1
            return BackupRunSummary(snapshotBytes: 9, copiedBlobCount: 0, referencedBlobCount: 1)
        }
        let controller = makeController(
            store: store, clock: clock, destination: destination, runner: runner
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x44]), url: destinationURL))
        let firstBackupSucceeded = await controller.backUpNow()
        XCTAssertTrue(firstBackupSucceeded)

        clock.now = baseDate.addingTimeInterval(BackupController.staleInterval - 1)
        let launchOutcome = await controller.backUpOnLaunchIfStale()
        XCTAssertEqual(launchOutcome, .notDue)

        XCTAssertEqual(runCount, 1, "a fresh launch must not create a redundant DB snapshot")
        XCTAssertEqual(controller.configuration?.lastSuccessAt, baseDate)
    }

    // MARK: - T-P2-STATUS-01: failure is persisted without erasing last success

    func testFailedRunPreservesLastSuccessAndPersistsActionableFailure() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        let destination = FakeBackupDestination(url: destinationURL)
        let failureSwitch = FailureSwitch()
        let runner: BackupController.BackupRunner = { _ in
            if failureSwitch.shouldFail { throw TestFailure.diskFull }
            return BackupRunSummary(snapshotBytes: 100, copiedBlobCount: 4, referencedBlobCount: 5)
        }
        let controller = makeController(
            store: store, clock: clock, destination: destination, runner: runner
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x55]), url: destinationURL))
        let firstBackupSucceeded = await controller.backUpNow()
        XCTAssertTrue(firstBackupSucceeded)
        let priorSuccess = controller.configuration?.lastSuccessAt

        failureSwitch.shouldFail = true
        clock.now = baseDate.addingTimeInterval(100)
        let secondBackupSucceeded = await controller.backUpNow()
        XCTAssertFalse(secondBackupSucceeded)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.configuration?.lastSuccessAt, priorSuccess)
        XCTAssertEqual(controller.configuration?.lastAttemptAt, clock.now)
        XCTAssertEqual(controller.configuration?.lastSnapshotBytes, 100)
        XCTAssertTrue(controller.configuration?.lastErrorDescription?.contains("disk is full") == true)
        XCTAssertTrue(controller.statusMessage?.contains("disk is full") == true)
    }

    // MARK: - T-P2-SIZE-01: first-run warning is pinned at 5 GiB

    func testLargeSourceWarningAppearsOnlyBeforeFirstSuccessfulBackup() async throws {
        let store = try makeStore()
        let clock = TestClock(baseDate)
        let destinationURL = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        let destination = FakeBackupDestination(url: destinationURL)
        let sourceBytes = BackupController.firstBackupWarningBytes + 17
        let controller = makeController(
            store: store,
            clock: clock,
            destination: destination,
            runner: { _ in
                BackupRunSummary(snapshotBytes: 42, copiedBlobCount: 1, referencedBlobCount: 1)
            },
            sourceBytes: sourceBytes
        )
        XCTAssertTrue(controller.configureDestination(bookmarkData: Data([0x66]), url: destinationURL))

        await controller.refreshEstimatedSourceSize()
        XCTAssertEqual(controller.estimatedSourceBytes, sourceBytes)
        XCTAssertTrue(controller.shouldWarnAboutLargeFirstBackup)

        let didBackUp = await controller.backUpNow()
        XCTAssertTrue(didBackUp)
        XCTAssertFalse(controller.shouldWarnAboutLargeFirstBackup)
    }

    // MARK: - T-P2-DEST-04: invalid real bookmark never enters the body

    func testInvalidSecurityScopedBookmarkFailsBeforeAccessBody() async {
        let destination = SecurityScopedBackupDestination(bookmarkData: Data([0xDE, 0xAD]))
        var bodyRan = false
        do {
            _ = try await destination.withAccess { _ in
                bodyRan = true
                return 1
            }
            XCTFail("an invalid bookmark must not resolve")
        } catch {
            XCTAssertEqual(error as? BackupDestinationError, .invalidBookmark)
        }
        XCTAssertFalse(bodyRan)
    }
}

private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class FailureSwitch {
    var shouldFail = false
}

private final class FakeBackupDestination: BackupDestination {
    let url: URL
    let failure: BackupDestinationError?
    var isAccessing = false
    var accessCount = 0
    var receivedBookmarkData: Data?

    init(url: URL, failure: BackupDestinationError? = nil) {
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

private enum TestFailure: LocalizedError {
    case runnerEscapedScope
    case runnerShouldNotRun
    case diskFull

    var errorDescription: String? {
        switch self {
        case .runnerEscapedScope: "Backup runner escaped the destination scope."
        case .runnerShouldNotRun: "Backup runner should not run."
        case .diskFull: "The backup disk is full."
        }
    }
}
