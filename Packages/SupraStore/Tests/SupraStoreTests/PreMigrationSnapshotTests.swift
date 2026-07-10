import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// P0 safety net (backup plan) — before a genuine upgrade mutates an existing
/// database, a consistent pre-migration snapshot is captured so a bad/destructive
/// migration is recoverable. Expected RED for every test here: `PreMigrationSnapshot`
/// does not exist yet → compile error ("cannot find 'PreMigrationSnapshot' in scope").
final class PreMigrationSnapshotTests: XCTestCase {

    // A DB migrated to {m1,m2}; the "next release" registry adds m3.
    private func migratorV2() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("m1_t1") { db in try db.create(table: "t1") { $0.column("id", .integer) } }
        m.registerMigration("m2_t2") { db in try db.create(table: "t2") { $0.column("id", .integer) } }
        return m
    }

    private func migratorV3() -> DatabaseMigrator {
        var m = migratorV2()
        m.registerMigration("m3_t3") { db in try db.create(table: "t3") { $0.column("id", .integer) } }
        return m
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P0Snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A DB migrated to {m1,m2} with one row in t1, at `<dir>/SupraAI.sqlite`.
    private func seedV2Database(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("SupraAI.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migratorV2().migrate(queue)
        try queue.write { db in try db.execute(sql: "INSERT INTO t1 (id) VALUES (7)") }
        return url
    }

    private func snapshotCount(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sqlite" }.count
    }

    // T-SNAP-01: a genuine upgrade writes a snapshot of the PRE-migration state.
    func testUpgradeWritesPreMigrationSnapshot() throws {
        let dir = try makeDir()
        let dbURL = try seedV2Database(in: dir)
        let snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)

        let snapURL = try XCTUnwrap(PreMigrationSnapshot.captureIfUpgrading(
            databaseURL: dbURL, migrator: migratorV3(), snapshotDirectory: snapDir
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapURL.path))
        let snap = try DatabaseQueue(path: snapURL.path)
        try snap.read { db in
            XCTAssertTrue(try db.tableExists("t1"))
            XCTAssertFalse(try db.tableExists("t3"), "snapshot must capture the PRE-migration schema (no m3 table)")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t1"), 1, "snapshot must contain the pre-migration data")
        }
    }

    // T-SNAP-02: an up-to-date database writes no snapshot.
    func testNoSnapshotWhenUpToDate() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("SupraAI.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migratorV3().migrate(queue)
        let snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)

        let result = try PreMigrationSnapshot.captureIfUpgrading(
            databaseURL: url, migrator: migratorV3(), snapshotDirectory: snapDir
        )
        XCTAssertNil(result)
        XCTAssertEqual(snapshotCount(snapDir), 0)
    }

    // T-SNAP-02b: a first-create (nothing applied yet) is not an upgrade — no snapshot.
    func testNoSnapshotOnFirstCreate() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("SupraAI.sqlite")
        _ = try DatabaseQueue(path: url.path) // empty DB, no migrations applied
        let snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)

        let result = try PreMigrationSnapshot.captureIfUpgrading(
            databaseURL: url, migrator: migratorV3(), snapshotDirectory: snapDir
        )
        XCTAssertNil(result, "an empty first-create DB is not an upgrade")
        XCTAssertEqual(snapshotCount(snapDir), 0)
    }

    // T-SNAP-03: retention keeps the newest `keep`, prunes older.
    func testRetentionKeepsNewest() throws {
        let dir = try makeDir()
        let dbURL = try seedV2Database(in: dir)
        let snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<6 {
            _ = try PreMigrationSnapshot.captureIfUpgrading(
                databaseURL: dbURL, migrator: migratorV3(), snapshotDirectory: snapDir,
                keep: 5, now: { base.addingTimeInterval(Double(i)) }
            )
        }
        XCTAssertEqual(snapshotCount(snapDir), 5, "retention must keep the newest 5 and prune the oldest")
    }

    // T-SNAP-04: the snapshot is internally consistent.
    func testSnapshotIsConsistent() throws {
        let dir = try makeDir()
        let dbURL = try seedV2Database(in: dir)
        let snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)

        let snapURL = try XCTUnwrap(PreMigrationSnapshot.captureIfUpgrading(
            databaseURL: dbURL, migrator: migratorV3(), snapshotDirectory: snapDir
        ))
        let snap = try DatabaseQueue(path: snapURL.path)
        try snap.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t1"), 1, "row counts must match the source at snapshot time")
        }
    }
}
