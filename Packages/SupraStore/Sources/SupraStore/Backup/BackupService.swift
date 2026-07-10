import Foundation
import GRDB

/// One backup snapshot's metadata, stored beside it as JSON. Deliberately minimal:
/// only what restore validation needs. The manifest is written LAST in a backup
/// run, so its presence marks the snapshot as complete.
public struct BackupManifest: Codable, Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    /// The source database's applied migrations, in registration order. Restore
    /// refuses a backup whose identifiers are ahead of the running app's registry.
    public var schemaMigrationIdentifiers: [String]
    public var createdAt: Date
    /// Byte size of the snapshot file (a compacted VACUUM INTO copy).
    public var sourceDbBytes: Int
    /// Number of managed blobs in the source at snapshot time (all guaranteed
    /// present in the destination pool, which is mirrored before the snapshot).
    public var referencedBlobCount: Int

    public init(
        appVersion: String,
        appBuild: String,
        schemaMigrationIdentifiers: [String],
        createdAt: Date,
        sourceDbBytes: Int,
        referencedBlobCount: Int
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.schemaMigrationIdentifiers = schemaMigrationIdentifiers
        self.createdAt = createdAt
        self.sourceDbBytes = sourceDbBytes
        self.referencedBlobCount = referencedBlobCount
    }

    /// Deterministic encoding (sorted keys + ISO8601 dates) — the on-disk format
    /// is a frozen contract (golden-tested); restore must parse old manifests.
    public static func encode(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }
}

/// The outcome of one backup run.
public struct BackupResult: Equatable, Sendable {
    public let snapshotURL: URL
    public let manifestURL: URL
    /// Blobs newly copied into the pool by this run.
    public let copiedBlobCount: Int
    /// Total managed blobs in the source at snapshot time.
    public let referencedBlobCount: Int
}

public enum BackupError: Error, Equatable, LocalizedError {
    /// The timestamped snapshot target already exists. A backup never overwrites
    /// an existing snapshot.
    case snapshotTargetExists(URL)

    public var errorDescription: String? {
        switch self {
        case let .snapshotTargetExists(url):
            return "A backup snapshot already exists at \(url.lastPathComponent)."
        }
    }
}

/// The backup engine (backup plan P1): writes one consistent database snapshot
/// plus an incrementally-mirrored, add-only pool of managed document blobs into a
/// destination folder. Pure over the injected writer and directories — no
/// bookmarks, scheduling, or UI here (that's the P2 controller's job).
///
/// Destination layout:
/// ```
/// <destination>/
///   blobs/<relative path>            add-only shared pool (never rewritten)
///   db/SupraAI-<stamp>.sqlite        one VACUUM INTO snapshot per run
///   db/SupraAI-<stamp>.json          manifest, written LAST (= run complete)
/// ```
/// Run order is blobs → snapshot → manifest, so an interrupted run can leave
/// harmless extra pool blobs but never a manifest for an incomplete backup.
public enum BackupService {
    static let snapshotPrefix = "SupraAI-"
    public static let defaultKeep = 10

    /// Runs one full backup. `blobsDirectory` is the managed blob root (nil or
    /// missing → database-only backup). Prunes `db/` to the newest `keep`
    /// snapshot+manifest pairs afterward.
    @discardableResult
    public static func runBackup(
        writer: any DatabaseWriter,
        blobsDirectory: URL?,
        destination: URL,
        appVersion: String,
        appBuild: String,
        migrator: DatabaseMigrator = SupraMigrator.makeMigrator(),
        keep: Int = BackupService.defaultKeep,
        fileManager: FileManager = .default,
        now: () -> Date = { Date() }
    ) throws -> BackupResult {
        // 1. Mirror blobs first: a snapshot must never reference an uncopied blob.
        let mirrored = try mirrorBlobs(
            from: blobsDirectory,
            toPoolAt: destination.appendingPathComponent("blobs", isDirectory: true),
            fileManager: fileManager
        )

        // 2. Consistent, compacted database snapshot through the live writer.
        let dbDirectory = destination.appendingPathComponent("db", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now())
        let snapshotURL = dbDirectory.appendingPathComponent("\(snapshotPrefix)\(stamp).sqlite")
        guard !fileManager.fileExists(atPath: snapshotURL.path) else {
            throw BackupError.snapshotTargetExists(snapshotURL)
        }
        try writer.vacuum(into: snapshotURL.path)

        // 3. Manifest last — its presence marks the backup complete.
        let identifiers = try writer.read { db in try migrator.appliedMigrations(db) }
        let snapshotBytes = (try? snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let manifest = BackupManifest(
            appVersion: appVersion,
            appBuild: appBuild,
            schemaMigrationIdentifiers: identifiers,
            createdAt: now(),
            sourceDbBytes: snapshotBytes,
            referencedBlobCount: mirrored.total
        )
        let manifestURL = dbDirectory.appendingPathComponent("\(snapshotPrefix)\(stamp).json")
        try BackupManifest.encode(manifest).write(to: manifestURL)

        pruneSnapshots(in: dbDirectory, keep: keep, fileManager: fileManager)

        return BackupResult(
            snapshotURL: snapshotURL,
            manifestURL: manifestURL,
            copiedBlobCount: mirrored.copied,
            referencedBlobCount: mirrored.total
        )
    }

    /// Incrementally mirrors the managed blob tree into the add-only pool: only
    /// files absent from the pool are copied, each atomically (copy to a `.tmp`
    /// sibling, then rename into place). Existing pool files are NEVER rewritten —
    /// blobs are content-addressed, so same relative path means same content.
    static func mirrorBlobs(
        from source: URL?,
        toPoolAt pool: URL,
        fileManager: FileManager
    ) throws -> (copied: Int, total: Int) {
        guard let source, fileManager.fileExists(atPath: source.path) else { return (0, 0) }
        try fileManager.createDirectory(at: pool, withIntermediateDirectories: true)

        var copied = 0
        var total = 0
        guard let enumerator = fileManager.enumerator(atPath: source.path) else { return (0, 0) }
        while let relativePath = enumerator.nextObject() as? String {
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            let fileName = (relativePath as NSString).lastPathComponent
            guard !fileName.hasPrefix(".") else { continue } // .DS_Store and friends
            total += 1

            let target = pool.appendingPathComponent(relativePath)
            guard !fileManager.fileExists(atPath: target.path) else { continue }

            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
            try fileManager.copyItem(at: source.appendingPathComponent(relativePath), to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: target)
                copied += 1
            } catch {
                // The blob appeared concurrently (another backup run) — same
                // content by construction, so drop ours and move on.
                try? fileManager.removeItem(at: temporary)
                guard fileManager.fileExists(atPath: target.path) else { throw error }
            }
        }
        return (copied, total)
    }

    /// Deletes all but the newest `keep` snapshot+manifest pairs. Lexicographic
    /// filename order is chronological (zero-padded UTC stamp). Best-effort: a
    /// pruning failure must never fail the backup that just completed.
    static func pruneSnapshots(in dbDirectory: URL, keep: Int, fileManager: FileManager) {
        guard keep >= 0 else { return }
        let snapshots = ((try? fileManager.contentsOfDirectory(
            at: dbDirectory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(snapshotPrefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard snapshots.count > keep else { return }
        for snapshot in snapshots.prefix(snapshots.count - keep) {
            try? fileManager.removeItem(at: snapshot)
            try? fileManager.removeItem(at: snapshot.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    /// Zero-padded, lexicographically-sortable UTC stamp (millisecond resolution).
    /// The format is a pinned contract — tests and retention sorting rely on it.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
