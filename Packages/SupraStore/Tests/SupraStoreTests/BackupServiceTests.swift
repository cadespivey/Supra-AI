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
        try write(to: url)
    }
}
