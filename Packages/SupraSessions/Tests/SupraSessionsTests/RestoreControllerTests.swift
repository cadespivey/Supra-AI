import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class RestoreControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_969_600)

    // T-RST-29: a blocked candidate is visible but cannot enter confirmation or staging.
    func testInvalidCandidateCannotBeSelectedConfirmedOrStaged() async throws {
        let fixture = try makeFixture()
        let invalid = candidate(
            identifier: "supra-20260731-090000-000",
            incompatibility: .databaseIntegrityFailed
        )
        var stageCount = 0
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [invalid] },
            stager: { _, _ in
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
        let valid = candidate(identifier: "supra-20260731-090100-000")
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
            identifier: "supra-20260731-090200-000",
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
            stager: { _, _ in
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

    // T-RST-34...36: success only schedules cold-start activation and emits content-free evidence.
    func testSuccessfulStageOffersRestartOnlyAndWritesContentFreeAuditAndStatus() async throws {
        let fixture = try makeFixture()
        let valid = candidate(identifier: "supra-20260731-090300-000")
        let summary = stageSummary(for: valid)
        let controller = makeController(
            fixture: fixture,
            inspector: { _ in [valid] },
            stager: { refreshed, layout in
                XCTAssertEqual(refreshed.identifier, valid.identifier)
                XCTAssertEqual(layout, fixture.liveLayout)
                return summary
            }
        )
        configure(controller, destination: fixture.destinationURL)

        let didInspect = await controller.inspectRestoreSnapshots()
        XCTAssertTrue(didInspect)
        XCTAssertTrue(controller.selectRestoreSnapshot(id: valid.identifier))
        XCTAssertTrue(controller.prepareRestoreConfirmation())
        let didStage = await controller.stageConfirmedRestore()
        XCTAssertTrue(didStage)

        XCTAssertEqual(controller.restoreState, .stagedRestartRequired)
        XCTAssertTrue(controller.requiresRestartForRestore)
        XCTAssertNil(controller.restoreConfirmation)
        let persisted = try XCTUnwrap(
            fixture.store.appSettings.getSetting(
                BackupController.restoreStatusStorageKey,
                as: RestoreStatusRecord.self
            )
        )
        XCTAssertEqual(persisted.state, .stagedRestartRequired)
        XCTAssertEqual(persisted.operationID, summary.operationID)
        XCTAssertEqual(persisted.snapshotIdentifier, valid.identifier)

        let audit = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(
                relatedTable: "backup_snapshots",
                relatedID: valid.identifier,
                eventType: "restore_staged"
            ).single
        )
        let auditText = [audit.summary, audit.relatedID, audit.metadataJSON]
            .compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(auditText.contains(fixture.root.path))
        XCTAssertFalse(auditText.contains(fixture.destinationURL.path))
        XCTAssertTrue(auditText.contains(summary.operationID))
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
        stager: @escaping BackupController.RestoreRunner = { _, _ in
            throw ControllerTestError.stageShouldNotRun
        }
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

    private func stageSummary(for candidate: RestoreSnapshotCandidate) -> RestoreStageSummary {
        RestoreStageSummary(
            operationID: "11111111-1111-1111-1111-111111111111",
            snapshotIdentifier: candidate.identifier,
            stagedAt: now
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
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
