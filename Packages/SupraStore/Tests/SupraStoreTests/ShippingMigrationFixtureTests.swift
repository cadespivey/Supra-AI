import CryptoKit
import Foundation
import GRDB
@testable import SupraStore
import XCTest

final class ShippingMigrationFixtureTests: XCTestCase {
    private static let supportedVersions = [
        "v1.4.1", "v1.5.2", "v1.8.0", "v2.0.0",
        "v2.1.0", "v2.1.3", "v2.2.0", "latest-minus-one",
    ]

    func testACRMIG001FixtureManifestCoversTheSupportedReleasePolicy() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.currentMigration, try XCTUnwrap(SupraMigrator.makeMigrator().migrations.last))
        XCTAssertEqual(manifest.supportedVersions, Self.supportedVersions)
        XCTAssertEqual(manifest.fixtures.map(\.seedVersion), Self.supportedVersions)
        XCTAssertTrue(manifest.syntheticDataDeclaration.contains("synthetic"))
        XCTAssertTrue(manifest.fixtures.allSatisfy(\.syntheticData))
        XCTAssertTrue(manifest.fixtures.allSatisfy { $0.sourceCommitSHA.count == 40 })
        XCTAssertTrue(manifest.fixtures.allSatisfy { !$0.schemaMigrationIdentifiers.isEmpty })
    }

    func testACRMIG002EveryAuthenticatedShippingFixtureUpgradesAndRemainsUsable() throws {
        let manifest = try loadManifest()
        for fixture in manifest.fixtures {
            try XCTContext.runActivity(named: fixture.seedVersion) { _ in
                let fixtureData = try authenticatedFixtureData(fixture)
                let directory = try temporaryDirectory(prefix: "ACR-MIG-")
                defer { try? FileManager.default.removeItem(at: directory) }
                let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
                try fixtureData.write(to: databaseURL)

                let seedQueue = try DatabaseQueue(path: databaseURL.path)
                try seedQueue.read { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
                    XCTAssertEqual(try appliedMigrations(db), fixture.schemaMigrationIdentifiers)
                    XCTAssertEqual(try fixtureSeedVersion(db), fixture.seedVersion)
                }

                let store = try SupraStore(url: databaseURL)
                let snapshotDirectory = directory.appendingPathComponent("PreMigrationSnapshots")
                let snapshots = try FileManager.default.contentsOfDirectory(
                    at: snapshotDirectory,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "sqlite" }
                XCTAssertEqual(snapshots.count, 1, "\(fixture.seedVersion) must capture one pre-upgrade snapshot")
                try assertHealthyCurrentStore(store, seedVersion: fixture.seedVersion)
                try assertHealthySnapshot(snapshots[0], fixture: fixture)

                let snapshotsBeforeSecondOpen = snapshots.count
                let reopened = try SupraStore(url: databaseURL)
                try assertHealthyCurrentStore(reopened, seedVersion: fixture.seedVersion)
                let snapshotsAfterSecondOpen = try FileManager.default.contentsOfDirectory(
                    at: snapshotDirectory,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "sqlite" }.count
                XCTAssertEqual(snapshotsAfterSecondOpen, snapshotsBeforeSecondOpen)
            }
        }
    }

    func testACRMIG003CorruptedPermanentFixtureIsRejectedBeforeOpen() throws {
        let fixture = try XCTUnwrap(loadManifest().fixtures.first)
        var compressed = try Data(contentsOf: fixtureResourceURL(fixture))
        compressed[compressed.startIndex] ^= 0xff

        XCTAssertThrowsError(try authenticatedFixtureData(fixture, compressedData: compressed)) { error in
            XCTAssertEqual(error as? FixtureAuthenticationError, .compressedDigestMismatch)
        }
    }

    func testACRMIG004SnapshotFailureBlocksSchemaMutation() throws {
        let directory = try temporaryDirectory(prefix: "ACR-MIG-snapshot-failure-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let oldMigrator = testMigrator(includeFailingUpgrade: false)
        let oldQueue = try DatabaseQueue(path: databaseURL.path)
        try oldMigrator.migrate(oldQueue)
        try oldQueue.write { db in try db.execute(sql: "INSERT INTO seed (value) VALUES ('canary')") }

        XCTAssertThrowsError(try SupraDatabase(
            url: databaseURL,
            migrator: testMigrator(includeFailingUpgrade: true),
            snapshotDirectory: directory.appendingPathComponent("snapshots"),
            snapshotCapture: { _, _, _ in throw SyntheticSnapshotFailure.noSpace }
        )) { error in
            guard case SupraDatabaseOpenError.snapshotFailed = error else {
                return XCTFail("Expected typed snapshot failure, got \(error)")
            }
        }

        let unchanged = try DatabaseQueue(path: databaseURL.path)
        try unchanged.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM seed"), "canary")
            XCTAssertFalse(try db.tableExists("upgrade_marker"))
            XCTAssertEqual(try appliedMigrations(db), ["m001_seed"])
        }
    }

    func testACRMIG005InterruptedMigrationRetainsOriginalAndOpenableSnapshot() throws {
        let directory = try temporaryDirectory(prefix: "ACR-MIG-interrupted-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let oldMigrator = testMigrator(includeFailingUpgrade: false)
        let oldQueue = try DatabaseQueue(path: databaseURL.path)
        try oldMigrator.migrate(oldQueue)
        try oldQueue.write { db in try db.execute(sql: "INSERT INTO seed (value) VALUES ('recoverable')") }

        var snapshotURL: URL?
        XCTAssertThrowsError(try SupraDatabase(
            url: databaseURL,
            migrator: testMigrator(includeFailingUpgrade: true),
            snapshotDirectory: directory.appendingPathComponent("snapshots"),
            snapshotCapture: PreMigrationSnapshot.captureIfUpgrading
        )) { error in
            guard case let SupraDatabaseOpenError.migrationFailed(snapshot, _) = error else {
                return XCTFail("Expected typed migration failure, got \(error)")
            }
            snapshotURL = snapshot
        }

        for recoverableURL in [databaseURL, try XCTUnwrap(snapshotURL)] {
            let queue = try DatabaseQueue(path: recoverableURL.path)
            try queue.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM seed"), "recoverable")
                XCTAssertFalse(try db.tableExists("upgrade_marker"))
                XCTAssertEqual(try appliedMigrations(db), ["m001_seed"])
            }
        }
    }

    private func assertHealthyCurrentStore(_ store: SupraStore, seedVersion: String) throws {
        try store.database.writer.write { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
            XCTAssertEqual(try appliedMigrations(db), SupraMigrator.makeMigrator().migrations)
            XCTAssertEqual(try fixtureSeedVersion(db), seedVersion)
            try db.execute(sql: "INSERT INTO document_chunk_fts(document_chunk_fts) VALUES ('integrity-check')")
        }

        let matter = try store.matters.createMatter(name: "Synthetic cascade \(seedVersion)")
        _ = try store.chats.createMatterChat(matterID: matter.id, title: "Synthetic child")
        try store.matters.permanentlyDeleteMatter(id: matter.id)
        try store.database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chats WHERE scope = ?",
                arguments: ["matter:\(matter.id)"]
            ), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        }
    }

    private func assertHealthySnapshot(_ url: URL, fixture: ShippingFixture) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
            XCTAssertEqual(try appliedMigrations(db), fixture.schemaMigrationIdentifiers)
            XCTAssertEqual(try fixtureSeedVersion(db), fixture.seedVersion)
        }
    }

    private func testMigrator(includeFailingUpgrade: Bool) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m001_seed") { db in
            try db.create(table: "seed") { table in table.column("value", .text).notNull() }
        }
        if includeFailingUpgrade {
            migrator.registerMigration("m002_interrupted") { db in
                try db.create(table: "upgrade_marker") { table in table.column("id", .integer) }
                throw SyntheticMigrationFailure.interrupted
            }
        }
        return migrator
    }

    private func loadManifest() throws -> ShippingFixtureManifest {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: "ShippingMigrations"
            )
        )
        return try JSONDecoder().decode(ShippingFixtureManifest.self, from: Data(contentsOf: url))
    }

    private func fixtureResourceURL(_ fixture: ShippingFixture) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: fixture.fileName,
                withExtension: nil,
                subdirectory: "ShippingMigrations"
            )
        )
    }

    private func authenticatedFixtureData(
        _ fixture: ShippingFixture,
        compressedData suppliedData: Data? = nil
    ) throws -> Data {
        let compressed = try suppliedData ?? Data(contentsOf: fixtureResourceURL(fixture))
        guard sha256(compressed) == fixture.compressedSHA256 else {
            throw FixtureAuthenticationError.compressedDigestMismatch
        }
        let expanded = try gunzip(compressed)
        guard sha256(expanded) == fixture.databaseSHA256 else {
            throw FixtureAuthenticationError.databaseDigestMismatch
        }
        return expanded
    }

    private func gunzip(_ compressed: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(compressed)
        try input.fileHandleForWriting.close()
        let expanded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureAuthenticationError.invalidGzip }
        return expanded
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    private func fixtureSeedVersion(_ db: Database) throws -> String? {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT value_json FROM app_settings WHERE key = 'shippingFixture.seed'"
        ), let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(SeedMarker.self, from: data).seedVersion
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct ShippingFixtureManifest: Decodable {
    let schemaVersion: Int
    let syntheticDataDeclaration: String
    let currentMigration: String
    let supportedVersions: [String]
    let fixtures: [ShippingFixture]
}

private struct ShippingFixture: Decodable {
    let seedVersion: String
    let sourceRef: String
    let sourceCommitSHA: String
    let fileName: String
    let compressedSHA256: String
    let databaseSHA256: String
    let schemaMigrationIdentifiers: [String]
    let syntheticData: Bool
}

private struct SeedMarker: Decodable {
    let seedVersion: String
}

private enum FixtureAuthenticationError: Error, Equatable {
    case compressedDigestMismatch
    case databaseDigestMismatch
    case invalidGzip
}

private enum SyntheticSnapshotFailure: Error { case noSpace }
private enum SyntheticMigrationFailure: Error { case interrupted }
