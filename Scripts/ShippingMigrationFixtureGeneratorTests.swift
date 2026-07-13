import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// This file is copied into an immutable tag worktree by
/// `generate-shipping-migration-fixtures.sh`. It deliberately uses only APIs
/// that existed in the oldest supported release so each database is produced by
/// that release's real migration registry, not by a hand-maintained SQL sketch.
final class ShippingMigrationFixtureGeneratorTests: XCTestCase {
    func testGenerateSyntheticFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        let outputPath = try XCTUnwrap(environment["SUPRA_FIXTURE_OUTPUT"])
        let seedVersion = try XCTUnwrap(environment["SUPRA_FIXTURE_SEED_VERSION"])
        let stopAtMigration = environment["SUPRA_FIXTURE_STOP_AT_MIGRATION"]
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outputURL)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: outputURL.path, configuration: configuration)
        let migrator = SupraMigrator.makeMigrator()
        if let stopAtMigration, !stopAtMigration.isEmpty {
            try migrator.migrate(queue, upTo: stopAtMigration)
        } else {
            try migrator.migrate(queue)
        }

        let marker = "{\"seedVersion\":\"\(seedVersion)\",\"synthetic\":true}"
        let fixedDate = Date(timeIntervalSinceReferenceDate: 0)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: ["shippingFixture.seed", marker, fixedDate, fixedDate]
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        }
        _ = try queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }
}
