import Foundation
import GRDB
import XCTest
@testable import SupraStore

final class RestoreSnapshotInspectorTests: XCTestCase {
    private var fixture: RestoreTestFixture!

    override func setUpWithError() throws {
        fixture = try RestoreTestFixture()
    }

    override func tearDownWithError() throws {
        fixture.remove()
        fixture = nil
    }

    // T-RST-01...03 expected RED: RestoreSnapshotInspector and its typed
    // discovery result do not exist on the implementation baseline.
    func testDiscoveryListsOnlyManifestBackedCompletedSnapshots() throws {
        let complete = try fixture.writeCompleteSnapshot()
        let dbDirectory = fixture.backupDirectory.appendingPathComponent("db", isDirectory: true)
        try Data("interrupted".utf8).write(
            to: dbDirectory.appendingPathComponent("SupraAI-20260731-120001-000.sqlite")
        )
        try Data("unrelated".utf8).write(to: dbDirectory.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(
            to: dbDirectory.appendingPathComponent("SupraAI-client-name.json")
        )

        let candidates = try RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        )

        XCTAssertEqual(candidates.map(\.identifier), ["SupraAI-20260731-120000-000"])
        XCTAssertEqual(candidates.first?.snapshotURL, complete.snapshot)
        XCTAssertTrue(try XCTUnwrap(candidates.first).isRestorable)
    }

    // Expected RED: no read-only summary or referenced-blob projection exists.
    func testDiscoveryReportsReadOnlySnapshotSummary() throws {
        let blob = RestoreTestBlob("aa/brief.bin", "SELECTED BLOB")
        _ = try fixture.writeCompleteSnapshot(blobs: [blob])

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)
        let summary = try XCTUnwrap(candidate.summary)

        XCTAssertEqual(summary.appVersion, "9.8.7")
        XCTAssertEqual(summary.appBuild, "654")
        XCTAssertGreaterThan(summary.databaseBytes, 0)
        XCTAssertEqual(summary.referencedBlobCount, 1)
        XCTAssertEqual(candidate.databaseSHA256, try fixture.fingerprint(candidate.snapshotURL))
        XCTAssertEqual(candidate.referencedBlobs.map(\.relativePath), ["aa/brief.bin"])
        XCTAssertNil(candidate.incompatibility)
    }

    // Expected RED: no discovery boundary exists whose source immutability can be proven.
    func testDiscoveryDoesNotMutateSnapshotManifestOrPool() throws {
        let blob = RestoreTestBlob("aa/brief.bin", "IMMUTABLE SOURCE")
        let pair = try fixture.writeCompleteSnapshot(blobs: [blob])
        let poolBlob = fixture.backupDirectory
            .appendingPathComponent("blobs/aa/brief.bin")
        let before = try [pair.snapshot, pair.manifest, poolBlob].map(fixture.fingerprint)

        _ = try RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        )

        XCTAssertEqual(try [pair.snapshot, pair.manifest, poolBlob].map(fixture.fingerprint), before)
    }

    // T-RST-04 expected RED: corrupt manifest JSON has no typed incompatibility.
    func testMalformedManifestIsListedButBlocked() throws {
        let dbDirectory = fixture.backupDirectory.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(
            to: dbDirectory.appendingPathComponent("SupraAI-20260731-120000-000.json")
        )

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)

        XCTAssertEqual(candidate.incompatibility, .malformedManifest)
        XCTAssertFalse(candidate.isRestorable)
    }

    // T-RST-05 expected RED: manifest/database pairing is not inspected.
    func testManifestWithoutSnapshotDatabaseIsBlocked() throws {
        let dbDirectory = fixture.backupDirectory.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let manifest = BackupManifest(
            appVersion: "9.8.7", appBuild: "654",
            schemaMigrationIdentifiers: ["m1", "m2"],
            createdAt: Date(timeIntervalSince1970: 1_785_499_200),
            sourceDbBytes: 4096, referencedBlobCount: 0
        )
        try BackupManifest.encode(manifest).write(
            to: dbDirectory.appendingPathComponent("SupraAI-20260731-120000-000.json")
        )

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)

        XCTAssertEqual(candidate.incompatibility, .missingSnapshotDatabase)
    }

    // T-RST-06 expected RED: SQLite integrity is not checked before restore.
    func testCorruptSQLiteSnapshotIsBlocked() throws {
        _ = try fixture.writeCompleteSnapshot(corruptDatabase: true)

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)

        XCTAssertEqual(candidate.incompatibility, .databaseIntegrityFailed)
    }

    // T-RST-07 expected RED: foreign-key violations are not checked.
    func testForeignKeyViolationIsBlockedIndependentlyOfIntegrityCheck() throws {
        _ = try fixture.writeCompleteSnapshot(foreignKeyViolation: true)

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)

        XCTAssertEqual(candidate.incompatibility, .foreignKeyIntegrityFailed)
    }

    // T-RST-08 expected RED: manifest/database migration mismatch and a future
    // migration have no fail-closed compatibility model.
    func testMigrationMismatchAndFutureSchemaHaveDistinctBlockingReasons() throws {
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120000-000",
            databaseMigrations: ["m1", "m2"],
            manifestMigrations: ["m1"]
        )
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120001-000",
            databaseMigrations: ["m1", "v999_future"]
        )

        let candidates = try RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        )
        let reasons = Dictionary(uniqueKeysWithValues: candidates.map { ($0.identifier, $0.incompatibility) })

        XCTAssertEqual(reasons["SupraAI-20260731-120000-000"]!, .manifestMigrationMismatch)
        XCTAssertEqual(reasons["SupraAI-20260731-120001-000"]!, .unsupportedFutureSchema)
    }

    // Expected RED: a non-prefix known history is not distinguished from a future schema.
    func testKnownMigrationsInWrongOrderAreBlockedAsIncompatibleHistory() throws {
        _ = try fixture.writeCompleteSnapshot(databaseMigrations: ["m2", "m1"])

        let candidate = try XCTUnwrap(RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        ).first)

        XCTAssertEqual(candidate.incompatibility, .incompatibleMigrationHistory)
    }

    // T-RST-09 expected RED: escaping and absent managed blob references are
    // neither enumerated nor blocked.
    func testEscapingAndMissingBlobReferencesHaveTypedBlockingReasons() throws {
        let escaping = RestoreTestBlob("../escape.bin", "ESCAPE")
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120000-000",
            blobs: [escaping],
            writeBlobFiles: false
        )
        let missing = RestoreTestBlob("bb/missing.bin", "MISSING")
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120001-000",
            blobs: [missing],
            writeBlobFiles: false
        )

        let candidates = try RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        )
        let reasons = Dictionary(uniqueKeysWithValues: candidates.map { ($0.identifier, $0.incompatibility) })

        XCTAssertEqual(reasons["SupraAI-20260731-120000-000"]!, .invalidReferencedBlobPath)
        XCTAssertEqual(reasons["SupraAI-20260731-120001-000"]!, .missingReferencedBlob)
    }

    // Expected RED: blob metadata and manifest counts are not independently validated.
    func testBlobDigestAndManifestCountMismatchAreBlocked() throws {
        let tampered = RestoreTestBlob("aa/tampered.bin", "EXPECTED")
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120000-000", blobs: [tampered]
        )
        try Data("DIFFERENT".utf8).write(
            to: fixture.backupDirectory.appendingPathComponent("blobs/aa/tampered.bin")
        )
        _ = try fixture.writeCompleteSnapshot(
            stem: "SupraAI-20260731-120001-000", referencedBlobCount: 1
        )

        let candidates = try RestoreSnapshotInspector.discover(
            in: fixture.backupDirectory,
            knownMigrationIdentifiers: ["m1", "m2"]
        )
        let reasons = Dictionary(uniqueKeysWithValues: candidates.map { ($0.identifier, $0.incompatibility) })

        XCTAssertEqual(reasons["SupraAI-20260731-120000-000"]!, .blobMetadataMismatch)
        XCTAssertEqual(reasons["SupraAI-20260731-120001-000"]!, .referencedBlobCountMismatch)
    }
}
