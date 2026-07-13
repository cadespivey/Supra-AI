import Foundation
import GRDB

/// Typed launch failures that require an explicit recovery decision. The public
/// description intentionally omits database and snapshot paths so it is safe to
/// display or record without disclosing a user's home-directory layout.
public enum SupraDatabaseOpenError: Error, LocalizedError {
    case snapshotFailed(reason: String)
    case migrationFailed(snapshotURL: URL?, reason: String)

    public var errorDescription: String? {
        switch self {
        case .snapshotFailed:
            return "Supra AI could not create a verified pre-upgrade database snapshot. The existing database was not changed."
        case .migrationFailed:
            return "Supra AI could not finish upgrading the database. The pre-upgrade snapshot remains available for recovery."
        }
    }

    public var recoverySnapshotURL: URL? {
        guard case let .migrationFailed(snapshotURL, _) = self else { return nil }
        return snapshotURL
    }
}

public final class SupraDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter, migrator: DatabaseMigrator) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    public convenience init(writer: any DatabaseWriter) throws {
        try self.init(writer: writer, migrator: SupraMigrator.makeMigrator())
    }

    public convenience init(url: URL) throws {
        try self.init(
            url: url,
            migrator: SupraMigrator.makeMigrator(),
            snapshotDirectory: url.deletingLastPathComponent()
                .appendingPathComponent("PreMigrationSnapshots", isDirectory: true),
            snapshotCapture: { databaseURL, migrator, snapshotDirectory in
                try PreMigrationSnapshot.captureIfUpgrading(
                    databaseURL: databaseURL,
                    migrator: migrator,
                    snapshotDirectory: snapshotDirectory
                )
            }
        )
    }

    /// Internal seam used by migration fault tests. Production callers use
    /// `init(url:)`, which supplies the shipping migrator and snapshotter.
    convenience init(
        url: URL,
        migrator: DatabaseMigrator,
        snapshotDirectory: URL,
        snapshotCapture: (
            _ databaseURL: URL,
            _ migrator: DatabaseMigrator,
            _ snapshotDirectory: URL
        ) throws -> URL?
    ) throws {
        let snapshotURL: URL?
        do {
            snapshotURL = try snapshotCapture(url, migrator, snapshotDirectory)
        } catch {
            throw SupraDatabaseOpenError.snapshotFailed(reason: Self.safeFailureReason(error))
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            try self.init(writer: queue, migrator: migrator)
        } catch {
            throw SupraDatabaseOpenError.migrationFailed(
                snapshotURL: snapshotURL,
                reason: Self.safeFailureReason(error)
            )
        }
    }

    /// An in-memory database (migrations applied). Used as the app's absolute
    /// last-resort store so a launch can degrade gracefully instead of crashing
    /// when no on-disk database can be opened.
    public static func inMemory() throws -> SupraDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try SupraDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    public static func openAppSupportDatabase(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) throws -> SupraDatabase {
        let url = try DatabasePath.appSupportDatabaseURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        )
        return try SupraDatabase(url: url)
    }

    #if DEBUG
    public func resetForDebug() throws {
        try writer.write { db in
            try SupraMigrator.deleteAllTables(db)
        }
        try SupraMigrator.makeMigrator().migrate(writer)
    }
    #endif

    private static func safeFailureReason(_ error: Error) -> String {
        String(reflecting: type(of: error))
    }
}
