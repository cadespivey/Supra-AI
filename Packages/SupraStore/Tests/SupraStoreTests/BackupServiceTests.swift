import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// P1 backup engine (backup plan T-BK-01…07). Layout under a destination:
/// `blobs/<rel>` is an ADD-ONLY shared pool (incremental); `db/SupraAI-<stamp>.sqlite`
/// is a consistent VACUUM INTO snapshot with a `db/SupraAI-<stamp>.json` manifest
/// written LAST (manifest-present == backup complete).
///
/// Expected RED for the whole file: `BackupService` / `BackupManifest` do not
/// exist yet → compile error ("cannot find 'BackupService' in scope").
final class BackupServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P1Backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func testMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m1") { db in
            try db.create(table: "t1") { $0.column("id", .integer) }
        }
        migrator.registerMigration("m2") { db in
            try db.create(table: "t2") { $0.column("id", .integer) }
        }
        return migrator
    }

    /// A file-backed source DB migrated to {m1,m2} with 3 rows in t1.
    private func makeSourceDatabase(in dir: URL) throws -> DatabaseQueue {
        let url = dir.appendingPathComponent("SupraAI.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try testMigrator().migrate(queue)
        try queue.write { db in
            for i in 0..<3 { try db.execute(sql: "INSERT INTO t1 (id) VALUES (?)", arguments: [i]) }
        }
        return queue
    }

    /// A source blobs tree with sha-sharded-style nested relative paths.
    private func makeBlobs(in dir: URL, files: [String: String]) throws -> URL {
        let blobs = dir.appendingPathComponent("blobs", isDirectory: true)
        for (rel, contents) in files {
            let url = blobs.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return blobs
    }

    private func poolFile(_ destination: URL, _ rel: String) -> URL {
        destination.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(rel)
    }

    private func writePair(stamp: String, in dbDirectory: URL) throws {
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let stem = dbDirectory.appendingPathComponent("SupraAI-\(stamp)")
        try Data("db".utf8).write(to: stem.appendingPathExtension("sqlite"))
        try Data("{}".utf8).write(to: stem.appendingPathExtension("json"))
    }

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    // MARK: - T-BK-01: snapshot consistency (I3), works with no blobs at all

    func testSnapshotIsConsistentAndBackupSucceedsWithoutBlobs() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let destination = dir.appendingPathComponent("dest", isDirectory: true)

        let result = try BackupService.runBackup(
            writer: queue, blobsDirectory: nil, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator()
        )

        XCTAssertEqual(result.copiedBlobCount, 0)
        XCTAssertEqual(result.referencedBlobCount, 0)
        XCTAssertEqual(result.snapshotURL.deletingLastPathComponent().lastPathComponent, "db")
        let snapshot = try DatabaseQueue(path: result.snapshotURL.path)
        try snapshot.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t1"), 3,
                "snapshot row counts must equal the source at snapshot time"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
    }

    // MARK: - T-BK-02: incremental pool (I4)

    func testSecondRunCopiesOnlyNewBlobs() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE", "b/two.bin": "TWO"])
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let base = utcDate(2026, 7, 10, 12, 0, 0)

        let first = try BackupService.runBackup(
            writer: queue, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(), now: { base }
        )
        XCTAssertEqual(first.copiedBlobCount, 2)
        XCTAssertEqual(first.referencedBlobCount, 2)

        try Data("THREE".utf8).write(
            to: blobs.appendingPathComponent("c", isDirectory: true).appendingPathComponent("three.bin"),
            options: .withoutOverwriting.union([]),
            creatingDirectoryFirst: true
        )

        let second = try BackupService.runBackup(
            writer: queue, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(),
            now: { base.addingTimeInterval(60) }
        )
        XCTAssertEqual(second.copiedBlobCount, 1, "only the blob added since the first run is copied")
        XCTAssertEqual(second.referencedBlobCount, 3)
        XCTAssertEqual(try String(contentsOf: poolFile(destination, "c/three.bin"), encoding: .utf8), "THREE")
        XCTAssertEqual(try String(contentsOf: poolFile(destination, "a/one.bin"), encoding: .utf8), "ONE")
    }

    // MARK: - T-BK-03 (wire-proof): the pool is add-only — no blind overwrite

    func testExistingPoolBlobIsNeverOverwritten() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE", "b/two.bin": "TWO"])
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        // Non-default state: the pool already holds a/one.bin with DIFFERENT bytes.
        let existing = poolFile(destination, "a/one.bin")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("TAMPERED".utf8).write(to: existing)

        let result = try BackupService.runBackup(
            writer: queue, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator()
        )

        XCTAssertEqual(result.copiedBlobCount, 1, "only the absent blob is copied")
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8), "TAMPERED",
            "an existing pool blob must be skipped, not overwritten (the source's ONE must be absent)"
        )
        XCTAssertEqual(try String(contentsOf: poolFile(destination, "b/two.bin"), encoding: .utf8), "TWO")
    }

    // MARK: - T-BK-04: ordering (blobs before DB) + manifest written last

    func testFailedSnapshotLeavesNoManifestButBlobsWereCopied() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE"])
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        // Pins the naming contract: stamp is yyyyMMdd-HHmmss-SSS (UTC, POSIX).
        let stamp = "20260710-120000-000"
        let dbDir = destination.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        // Pre-existing snapshot target → vacuum(into:) must throw, and the backup
        // must never overwrite an existing snapshot.
        try Data("occupied".utf8).write(to: dbDir.appendingPathComponent("SupraAI-\(stamp).sqlite"))

        XCTAssertThrowsError(try BackupService.runBackup(
            writer: queue, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(),
            now: { self.utcDate(2026, 7, 10, 12, 0, 0) }
        ))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dbDir.appendingPathComponent("SupraAI-\(stamp).json").path),
            "no manifest may exist for a failed backup — manifest-present means complete"
        )
        XCTAssertEqual(
            try String(contentsOf: poolFile(destination, "a/one.bin"), encoding: .utf8), "ONE",
            "blobs are mirrored before the DB snapshot, so they exist even when the snapshot fails"
        )
    }

    // MARK: - T-BK-05: retention (I5)

    func testRetentionKeepsNewestTenSnapshotPairs() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let base = utcDate(2026, 7, 10, 12, 0, 0)

        var newestSnapshot: URL?
        for i in 0..<11 {
            let result = try BackupService.runBackup(
                writer: queue, blobsDirectory: nil, destination: destination,
                appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(),
                now: { base.addingTimeInterval(Double(i)) }
            )
            newestSnapshot = result.snapshotURL
        }

        let dbDir = destination.appendingPathComponent("db", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: dbDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.filter { $0.pathExtension == "sqlite" }.count, 10)
        XCTAssertEqual(entries.filter { $0.pathExtension == "json" }.count, 10, "manifests prune with their snapshots")
        let newest = try XCTUnwrap(newestSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path), "the newest snapshot is never pruned")
        XCTAssertFalse(
            entries.contains { $0.lastPathComponent == "SupraAI-20260710-120000-000.sqlite" },
            "the oldest snapshot is pruned once retention is exceeded"
        )
    }

    // MARK: - T-BK-06: frozen manifest golden

    func testManifestEncodingMatchesFrozenGolden() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let manifest = BackupManifest(
            appVersion: "2.1.3",
            appBuild: "378",
            schemaMigrationIdentifiers: ["m1", "m2"],
            createdAt: createdAt,
            sourceDbBytes: 4096,
            referencedBlobCount: 2
        )
        // Hand-authored from the spec (sortedKeys + ISO8601) — NEVER regenerated
        // from the encoder under test.
        let golden = #"{"appBuild":"378","appVersion":"2.1.3","createdAt":"2026-07-10T12:00:00Z","referencedBlobCount":2,"schemaMigrationIdentifiers":["m1","m2"],"sourceDbBytes":4096}"#
        XCTAssertEqual(String(data: try BackupManifest.encode(manifest), encoding: .utf8), golden)
        XCTAssertEqual(try BackupManifest.decode(Data(golden.utf8)), manifest, "the golden must decode back to the same manifest")
    }

    // MARK: - T-BK-07: the manifest records the real store's applied migrations

    func testManifestRecordsAppliedMigrationsOfTheRealStore() throws {
        let dir = try makeDir()
        let store = try SupraStore(url: dir.appendingPathComponent("SupraAI.sqlite"))
        try store.appSettings.setSetting("p1.sentinel", value: 1)
        let destination = dir.appendingPathComponent("dest", isDirectory: true)

        let result = try BackupService.runBackup(
            writer: store.database.writer, blobsDirectory: nil, destination: destination,
            appVersion: "2.1.3", appBuild: "378"
        )

        let manifest = try BackupManifest.decode(Data(contentsOf: result.manifestURL))
        XCTAssertEqual(
            manifest.schemaMigrationIdentifiers, SupraMigrator.makeMigrator().migrations,
            "a fully-migrated store records its complete ordered migration list"
        )
        XCTAssertEqual(manifest.schemaMigrationIdentifiers.first, "v001_create_app_settings")

        // Standing guards added after the P1 adversarial review: these fields are
        // already emitted, but neither was wired to an assertion in the original
        // suite. A literal sourceDbBytes = 0 or an empty-but-valid real-store
        // snapshot must not stay green.
        let snapshotBytes = try XCTUnwrap(
            result.snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertEqual(manifest.sourceDbBytes, snapshotBytes)
        XCTAssertGreaterThan(manifest.sourceDbBytes, 0)
        let snapshotStore = try SupraStore(url: result.snapshotURL)
        XCTAssertEqual(
            try snapshotStore.appSettings.getSetting("p1.sentinel", as: Int.self), 1,
            "the real-store snapshot must contain the seeded pre-backup state"
        )
    }

    // MARK: - P1 adversarial-review regressions

    /// T-BK-R01. Expected RED: the original mirror-before-vacuum run never
    /// revisits a blob committed immediately before the live snapshot, so the
    /// second pool file is absent and referencedBlobCount remains 1.
    func testBlobCommittedBetweenMirrorAndSnapshotIsIncludedBeforeManifest() throws {
        let dir = try makeDir()
        let store = try SupraStore(url: dir.appendingPathComponent("SupraAI.sqlite"))
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE"])
        _ = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "one", byteSize: 3, originalExtension: "bin",
            managedRelativePath: "blobs/a/one.bin"
        ))
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let operations = TestBackupFileOperations()
        operations.beforeSnapshot = {
            let second = blobs.appendingPathComponent("b/two.bin")
            try FileManager.default.createDirectory(
                at: second.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("TWO".utf8).write(to: second)
            _ = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                sha256: "two", byteSize: 3, originalExtension: "bin",
                managedRelativePath: "blobs/b/two.bin"
            ))
        }

        let result = try BackupService.runBackup(
            writer: store.database.writer, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", operations: operations
        )

        XCTAssertEqual(
            try String(contentsOf: poolFile(destination, "b/two.bin"), encoding: .utf8), "TWO",
            "snapshot-referenced blobs added after the first mirror must be copied before completion"
        )
        XCTAssertEqual(result.copiedBlobCount, 2)
        XCTAssertEqual(result.referencedBlobCount, 2)
        XCTAssertEqual(
            try BackupManifest.decode(Data(contentsOf: result.manifestURL)).referencedBlobCount, 2
        )
    }

    /// T-BK-R02. Expected RED: the original implementation writes a manifest
    /// even when the snapshot's document_blobs table names an absent source file.
    func testSnapshotReferencedMissingBlobFailsClosedWithoutManifest() throws {
        let dir = try makeDir()
        let store = try SupraStore(url: dir.appendingPathComponent("SupraAI.sqlite"))
        let blobs = try makeBlobs(in: dir, files: [:])
        _ = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "missing", byteSize: 7, originalExtension: "bin",
            managedRelativePath: "blobs/ff/missing.bin"
        ))
        let destination = dir.appendingPathComponent("dest", isDirectory: true)

        XCTAssertThrowsError(try BackupService.runBackup(
            writer: store.database.writer, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378"
        )) { error in
            XCTAssertEqual(error as? BackupError, .referencedBlobMissing("blobs/ff/missing.bin"))
        }

        let dbDirectory = destination.appendingPathComponent("db", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dbDirectory, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(entries.filter { $0.pathExtension == "json" }.isEmpty)
        XCTAssertTrue(entries.filter { $0.pathExtension == "sqlite" }.isEmpty)
    }

    /// T-BK-R03. Expected RED: a failed VACUUM propagates after leaving the
    /// partial target in db/, where the original retention logic counts it.
    func testFailedSnapshotRemovesPartialDatabaseAndWritesNoManifest() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let operations = TestBackupFileOperations()
        operations.snapshotFailure = .afterWritingPartial
        let stamp = "20260710-120000-000"

        XCTAssertThrowsError(try BackupService.runBackup(
            writer: queue, blobsDirectory: nil, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(),
            now: { self.utcDate(2026, 7, 10, 12, 0, 0) }, operations: operations
        ))

        let dbDirectory = destination.appendingPathComponent("db", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dbDirectory.appendingPathComponent("SupraAI-\(stamp).sqlite").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dbDirectory.appendingPathComponent("SupraAI-\(stamp).json").path
        ))
    }

    /// T-BK-R04 (wire-proof). Expected RED: the original run has no injected
    /// durability operations, never syncs blob/snapshot files, and writes the
    /// completion manifest through plain Data.write.
    func testDurabilityGateSyncsBlobAndSnapshotBeforeAtomicManifest() throws {
        let dir = try makeDir()
        let queue = try makeSourceDatabase(in: dir)
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE"])
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let operations = TestBackupFileOperations()

        _ = try BackupService.runBackup(
            writer: queue, blobsDirectory: blobs, destination: destination,
            appVersion: "2.1.3", appBuild: "378", migrator: testMigrator(),
            operations: operations
        )

        XCTAssertEqual(
            operations.events,
            [.synchronizedBlob, .createdSnapshot, .synchronizedSnapshot, .wroteManifestAtomically],
            "the completion marker must follow durable blob and snapshot data"
        )
    }

    /// T-BK-R05. Expected RED: a present plain file is accepted as a blob root
    /// and silently produces a successful zero-blob backup.
    func testPresentNonDirectoryBlobRootThrows() throws {
        let dir = try makeDir()
        let sourceFile = dir.appendingPathComponent("not-a-directory")
        try Data("not blobs".utf8).write(to: sourceFile)
        let pool = dir.appendingPathComponent("pool", isDirectory: true)

        XCTAssertThrowsError(try BackupService.mirrorBlobs(
            from: sourceFile, toPoolAt: pool, fileManager: .default
        )) { error in
            XCTAssertEqual(error as? BackupError, .invalidBlobsDirectory(sourceFile))
        }
    }

    /// T-BK-R05b. Expected RED: the path-based enumerator silently skips an
    /// unreadable shard and returns a self-consistent but incomplete count.
    func testUnreadableBlobSubdirectoryFailsInsteadOfSilentlySkipping() throws {
        let dir = try makeDir()
        let blobs = try makeBlobs(in: dir, files: ["aa/secret.bin": "SECRET"])
        let unreadableShard = blobs.appendingPathComponent("aa", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: unreadableShard.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: unreadableShard.path
            )
        }

        XCTAssertThrowsError(try BackupService.mirrorBlobs(
            from: blobs,
            toPoolAt: dir.appendingPathComponent("pool", isDirectory: true),
            fileManager: .default
        )) { error in
            switch error as? BackupError {
            case let .blobEnumerationFailed(url):
                XCTAssertEqual(
                    url.resolvingSymlinksInPath().standardizedFileURL,
                    unreadableShard.resolvingSymlinksInPath().standardizedFileURL
                )
            default:
                XCTFail("expected blobEnumerationFailed, got \(error)")
            }
        }
    }

    /// T-BK-R06. Expected RED: copyItem sits outside the original cleanup
    /// catch, so its deliberately-created temporary survives the thrown error.
    func testFailedBlobCopyCleansTemporaryFile() throws {
        let dir = try makeDir()
        let blobs = try makeBlobs(in: dir, files: ["a/one.bin": "ONE"])
        let pool = dir.appendingPathComponent("pool", isDirectory: true)
        let fileManager = PartialCopyFailureFileManager()

        XCTAssertThrowsError(try BackupService.mirrorBlobs(
            from: blobs, toPoolAt: pool, fileManager: fileManager
        ))

        let shard = pool.appendingPathComponent("a", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: shard, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            entries.isEmpty,
            "a failed copy must not leak a uniquely-named .tmp file into the add-only pool"
        )
    }

    /// T-BK-R07. Expected RED: manifest-less sqlite files occupy retention
    /// slots and evict the two oldest valid pairs.
    func testRetentionCountsOnlyCompletePairs() throws {
        let dir = try makeDir()
        let dbDirectory = dir.appendingPathComponent("db", isDirectory: true)
        for second in 0..<10 {
            try writePair(stamp: String(format: "20260710-1200%02d-000", second), in: dbDirectory)
        }
        for second in 10..<12 {
            try Data("partial".utf8).write(to: dbDirectory.appendingPathComponent(
                String(format: "SupraAI-20260710-1200%02d-000.sqlite", second)
            ))
        }

        BackupService.pruneSnapshots(in: dbDirectory, keep: 10, fileManager: .default)

        let entries = try FileManager.default.contentsOfDirectory(
            at: dbDirectory, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(entries.filter { $0.pathExtension == "sqlite" }.count, 12)
        XCTAssertEqual(entries.filter { $0.pathExtension == "json" }.count, 10)
        XCTAssertTrue(entries.contains {
            $0.lastPathComponent == "SupraAI-20260710-120000-000.sqlite"
        }, "an incomplete newer snapshot must not evict the oldest complete pair")
        XCTAssertTrue(entries.contains {
            $0.lastPathComponent == "SupraAI-20260710-120010-000.sqlite"
        }, "pruning must not delete a manifest-less snapshot that another run may still be writing")
    }

    /// T-BK-R08 (boundary wire-proof). Expected RED: keep == 0 selects every
    /// snapshot for deletion, including the newest one.
    func testRetentionKeepZeroStillPreservesNewestPair() throws {
        let dir = try makeDir()
        let dbDirectory = dir.appendingPathComponent("db", isDirectory: true)
        try writePair(stamp: "20260710-120000-000", in: dbDirectory)
        try writePair(stamp: "20260710-120001-000", in: dbDirectory)

        BackupService.pruneSnapshots(in: dbDirectory, keep: 0, fileManager: .default)

        let entries = try FileManager.default.contentsOfDirectory(
            at: dbDirectory, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(entries.filter { $0.pathExtension == "sqlite" }.count, 1)
        XCTAssertEqual(entries.filter { $0.pathExtension == "json" }.count, 1)
        XCTAssertTrue(entries.contains {
            $0.lastPathComponent == "SupraAI-20260710-120001-000.sqlite"
        }, "retention may never prune the newest complete pair")
    }

    /// T-BK-R09. Expected RED: pruning removes sqlite before json, leaving a
    /// present-but-orphaned completeness marker if interrupted between calls.
    func testRetentionRemovesManifestBeforeItsSnapshot() throws {
        let dir = try makeDir()
        let dbDirectory = dir.appendingPathComponent("db", isDirectory: true)
        try writePair(stamp: "20260710-120000-000", in: dbDirectory)
        try writePair(stamp: "20260710-120001-000", in: dbDirectory)
        let fileManager = RemovalTrackingFileManager()

        BackupService.pruneSnapshots(in: dbDirectory, keep: 1, fileManager: fileManager)

        XCTAssertEqual(
            Array(fileManager.removedNames.prefix(2)),
            ["SupraAI-20260710-120000-000.json", "SupraAI-20260710-120000-000.sqlite"]
        )
    }
}

private final class TestBackupFileOperations: BackupFileOperations {
    enum Event: Equatable {
        case synchronizedBlob
        case createdSnapshot
        case synchronizedSnapshot
        case wroteManifestAtomically
    }

    enum SnapshotFailure {
        case afterWritingPartial
    }

    var beforeSnapshot: (() throws -> Void)?
    var snapshotFailure: SnapshotFailure?
    private(set) var events: [Event] = []

    func createSnapshot(writer: any DatabaseWriter, at url: URL) throws {
        try beforeSnapshot?()
        events.append(.createdSnapshot)
        if snapshotFailure == .afterWritingPartial {
            try Data("partial database".utf8).write(to: url)
            throw CocoaError(.fileWriteUnknown)
        }
        try writer.vacuum(into: url.path)
    }

    func synchronizeFile(at url: URL) throws {
        events.append(url.pathExtension == "sqlite" ? .synchronizedSnapshot : .synchronizedBlob)
    }

    func writeManifestAtomically(_ data: Data, to url: URL) throws {
        events.append(.wroteManifestAtomically)
        try data.write(to: url, options: .atomic)
    }
}

private final class PartialCopyFailureFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class RemovalTrackingFileManager: FileManager {
    private(set) var removedNames: [String] = []

    override func removeItem(at url: URL) throws {
        removedNames.append(url.lastPathComponent)
        try super.removeItem(at: url)
    }
}

private extension Data {
    /// Test helper: write, creating the parent directory first.
    func write(to url: URL, options: Data.WritingOptions, creatingDirectoryFirst: Bool) throws {
        if creatingDirectoryFirst {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try write(to: url, options: options)
    }
}
