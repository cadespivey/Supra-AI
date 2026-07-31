import CryptoKit
import Foundation
import GRDB
@testable import SupraStore

struct RestoreTestBlob {
    let relativePath: String
    let bytes: Data

    init(_ relativePath: String, _ contents: String) {
        self.relativePath = relativePath
        self.bytes = Data(contents.utf8)
    }

    var sha256: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct RestoreTestFixture {
    let root: URL
    let backupDirectory: URL
    let liveDatabaseURL: URL
    let liveBlobsDirectory: URL
    let stagingRootDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreTests-\(UUID().uuidString)", isDirectory: true)
        backupDirectory = root.appendingPathComponent("Backup", isDirectory: true)
        liveDatabaseURL = root.appendingPathComponent("Live/SupraAI.sqlite")
        liveBlobsDirectory = root.appendingPathComponent("Live/blobs", isDirectory: true)
        stagingRootDirectory = root.appendingPathComponent("Live/RestoreStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func writeDatabase(
        at url: URL,
        migrations: [String] = ["m1", "m2"],
        blobs: [RestoreTestBlob] = [],
        sentinel: String = "sentinel",
        foreignKeyViolation: Bool = false
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = !foreignKeyViolation
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for migration in migrations {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migration]
                )
            }
            try db.execute(sql: "CREATE TABLE restore_sentinel (value TEXT NOT NULL)")
            try db.execute(
                sql: "INSERT INTO restore_sentinel (value) VALUES (?)", arguments: [sentinel]
            )
            try db.execute(sql: """
                CREATE TABLE document_blobs (
                    id TEXT PRIMARY KEY,
                    sha256 TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    managed_relative_path TEXT NOT NULL
                )
                """)
            for (index, blob) in blobs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO document_blobs
                            (id, sha256, byte_size, managed_relative_path)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: ["blob-\(index)", blob.sha256, blob.bytes.count, "blobs/\(blob.relativePath)"]
                )
            }
            try db.execute(sql: "CREATE TABLE restore_parent (id INTEGER PRIMARY KEY)")
            try db.execute(sql: """
                CREATE TABLE restore_child (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER NOT NULL REFERENCES restore_parent(id)
                )
                """)
            if foreignKeyViolation {
                try db.execute(sql: "INSERT INTO restore_child (id, parent_id) VALUES (1, 999)")
            }
        }
        return url
    }

    @discardableResult
    func writeCompleteSnapshot(
        stem: String = "SupraAI-20260731-120000-000",
        databaseMigrations: [String] = ["m1", "m2"],
        manifestMigrations: [String]? = nil,
        blobs: [RestoreTestBlob] = [],
        writeBlobFiles: Bool = true,
        sentinel: String = "selected",
        foreignKeyViolation: Bool = false,
        corruptDatabase: Bool = false,
        referencedBlobCount: Int? = nil
    ) throws -> (snapshot: URL, manifest: URL) {
        let dbDirectory = backupDirectory.appendingPathComponent("db", isDirectory: true)
        let pool = backupDirectory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let snapshot = dbDirectory.appendingPathComponent("\(stem).sqlite")
        try writeDatabase(
            at: snapshot,
            migrations: databaseMigrations,
            blobs: blobs,
            sentinel: sentinel,
            foreignKeyViolation: foreignKeyViolation
        )
        if corruptDatabase {
            try Data("not a sqlite database".utf8).write(to: snapshot)
        }
        if writeBlobFiles {
            for blob in blobs {
                let target = pool.appendingPathComponent(blob.relativePath)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try blob.bytes.write(to: target)
            }
        }
        let bytes = try XCTUnwrapForRestore(
            snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let manifest = BackupManifest(
            appVersion: "9.8.7",
            appBuild: "654",
            schemaMigrationIdentifiers: manifestMigrations ?? databaseMigrations,
            createdAt: Date(timeIntervalSince1970: 1_785_499_200),
            sourceDbBytes: bytes,
            referencedBlobCount: referencedBlobCount ?? blobs.count
        )
        let manifestURL = dbDirectory.appendingPathComponent("\(stem).json")
        try BackupManifest.encode(manifest).write(to: manifestURL)
        return (snapshot, manifestURL)
    }

    func writeLiveState(
        blobs: [RestoreTestBlob] = [],
        sentinel: String = "current"
    ) throws {
        try writeDatabase(at: liveDatabaseURL, blobs: blobs, sentinel: sentinel)
        for blob in blobs {
            let target = liveBlobsDirectory.appendingPathComponent(blob.relativePath)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try blob.bytes.write(to: target)
        }
    }

    func sentinel(in databaseURL: URL) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM restore_sentinel")
        }
    }

    func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Test-only unwrap that can be used from fixture helpers without introducing a
/// silent optional fallback. A nil fixture fact throws and fails the calling test.
private func XCTUnwrapForRestore<T>(_ value: T?) throws -> T {
    if let value { return value }
    throw CocoaError(.fileReadUnknown)
}
