import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// P0 safety net (backup plan) — the migrator must never auto-erase real data on
/// a schema mismatch. Reproduces the 2026-07-10 data-loss incident: a build whose
/// migration registry didn't match the database's applied migrations tripped GRDB's
/// `eraseDatabaseOnSchemaChange` and wiped the store.
final class BackupSafetyNetTests: XCTestCase {

    /// T-ERASE-01 (incident reproduction, through the real open path).
    ///
    /// Expected RED before the fix: `#if DEBUG` is defined under `swift test`, so
    /// today's `eraseDatabaseOnSchemaChange = true` is active. Reopening a database
    /// that carries an unknown applied migration (`applied ⊄ known`) erases it →
    /// the sentinel is gone → `XCTAssertEqual(nil, 42)` fails.
    func testUnknownAppliedMigrationDoesNotEraseRealData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P0Erase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("SupraAI.sqlite")

        do {
            let store = try SupraStore(url: url)
            try store.appSettings.setSetting("p0.sentinel", value: 42)
            // Simulate a database that carries a migration THIS build's registry does
            // not know — e.g. one applied by a feature-branch build. This is the exact
            // condition that made GRDB's erase-on-schema-change wipe the user's data.
            try store.database.writer.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999_feature_branch')")
            }
        }

        // Reopen through the real store path — the same path the app launches through.
        let reopened = try SupraStore(url: url)
        let sentinel = try reopened.appSettings.getSetting("p0.sentinel", as: Int.self)
        XCTAssertEqual(
            sentinel, 42,
            "reopening a database that carries an unknown migration must NOT erase real data"
        )
    }

    /// T-ERASE-02 (standing guard, independent of the ambient DEBUG flag).
    ///
    /// Expected RED before the fix: under `swift test` the `#if DEBUG` block sets the
    /// flag true, so this assertion fails. Pins the flag off forever — fails loudly if
    /// anyone re-adds `eraseDatabaseOnSchemaChange = true` to the shipping migrator.
    func testShippingMigratorNeverAutoErasesOnSchemaChange() {
        XCTAssertFalse(
            SupraMigrator.makeMigrator().eraseDatabaseOnSchemaChange,
            "the shipping migrator must never auto-erase on schema drift (it wiped real data on 2026-07-10)"
        )
    }
}
