import Foundation
import GRDB

/// Captures a consistent copy of an on-disk database immediately before a genuine
/// schema upgrade runs, so a destructive or buggy migration is recoverable.
///
/// This is the local, always-on half of the backup safety net (it needs no
/// configured backup destination). It complements the removal of
/// `eraseDatabaseOnSchemaChange`: that stops an accidental wipe, this preserves a
/// rollback point across a legitimate migration.
public enum PreMigrationSnapshot {
    /// Filename prefix for snapshots this type writes and prunes.
    static let prefix = "SupraAI-premigration-"

    /// Writes a snapshot of `databaseURL` into `snapshotDirectory` when `migrator`
    /// represents a **genuine upgrade of an existing database** — i.e. the database
    /// has already-applied migrations AND `migrator` has further pending ones. Does
    /// nothing on a first-create (nothing applied yet) or when the database is
    /// already up to date. Prunes to the newest `keep` snapshots. Returns the
    /// snapshot URL when one was written, else nil.
    ///
    /// The copy is made with GRDB's `vacuum(into:)` — a transactionally consistent,
    /// compacted single-file copy (a raw file copy of a live WAL database is not
    /// safe). Call BEFORE running the migrations.
    @discardableResult
    public static func captureIfUpgrading(
        databaseURL: URL,
        migrator: DatabaseMigrator,
        snapshotDirectory: URL,
        keep: Int = 5,
        now: () -> Date = { Date() }
    ) throws -> URL? {
        // No database file yet → nothing to snapshot.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let queue = try DatabaseQueue(path: databaseURL.path)
        let isUpgrade = try queue.read { db -> Bool in
            // First-create (nothing applied) is not an upgrade; nor is an up-to-date DB.
            let applied = try migrator.appliedIdentifiers(db)
            if applied.isEmpty { return false }
            return try !migrator.hasCompletedMigrations(db)
        }
        guard isUpgrade else { return nil }

        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let destination = snapshotDirectory.appendingPathComponent("\(prefix)\(timestamp(now())).sqlite")
        // vacuum(into:) requires the target not to pre-exist.
        try? FileManager.default.removeItem(at: destination)
        try queue.vacuum(into: destination.path)

        prune(in: snapshotDirectory, keep: keep)
        return destination
    }

    /// Deletes all but the newest `keep` snapshots (lexicographic filename order,
    /// which is chronological because the timestamp is zero-padded). Never throws
    /// out of the caller's path — pruning failure must not fail the app launch.
    static func prune(in directory: URL, keep: Int) {
        guard keep >= 0 else { return }
        let snapshots = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard snapshots.count > keep else { return }
        for url in snapshots.prefix(snapshots.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Zero-padded, lexicographically-sortable UTC stamp (millisecond resolution so
    /// distinct calls never collide on the target filename).
    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
